#!/bin/bash

# Install (or roll back) the Trilio Horizon plugin on OpenStack-Helm by overriding the Horizon
# image in the horizon Helm release. For MOSK use install_horizon_plugin_mosk.sh instead.
#
# Why a pre-pull: the plugin image is private, and the OpenStack-Helm Horizon deployment has no
# pull secret and pulls with IfNotPresent. A pod can only use pull secrets from its own namespace,
# so the image is pulled onto every Horizon node by a short-lived DaemonSet in the namespace that
# holds the triliovault-image-registry secret (created by create_image_pull_secret.sh).
#
# Usage:
#   HORIZON_CHART=<path to the horizon chart> ./install_horizon_plugin.sh <horizon_plugin_image>
#   HORIZON_CHART=<path to the horizon chart> ./install_horizon_plugin.sh --rollback
#
# Example:
#   HORIZON_CHART=/opt/openstack-helm/horizon ./install_horizon_plugin.sh docker.io/trilio/trilio-horizon-plugin-helm:6.2.1-2026.1
#
# HORIZON_CHART must be the same chart version as the installed release (helm upgrade needs a
# chart, and the script refuses to change the chart version). The release keeps all its other
# values (--reuse-values); only images.tags.horizon changes.
#
# Use a new image tag for every rebuild: with IfNotPresent, a rebuilt image under an old tag
# never reaches nodes that already cached it.
#
# Optional environment variables:
#   RELEASE                 horizon Helm release name (default: horizon)
#   NAMESPACE               OpenStack namespace (default: openstack)
#   PULL_SECRET             image pull secret (default: triliovault-image-registry)
#   PULL_SECRET_NAMESPACE   namespace of PULL_SECRET and of the pre-pull DaemonSet (default: trilio-openstack)
#   TIMEOUT                 seconds to wait for each phase (default: 1800)

set -euo pipefail

RELEASE="${RELEASE:-horizon}"
NAMESPACE="${NAMESPACE:-openstack}"
PULL_SECRET="${PULL_SECRET:-triliovault-image-registry}"
PULL_SECRET_NAMESPACE="${PULL_SECRET_NAMESPACE:-trilio-openstack}"
TIMEOUT="${TIMEOUT:-1800}"
PREPULL_DS="trilio-horizon-prepull"
PLUGIN_IMAGE_MATCH="trilio-horizon-plugin"

usage() {
    sed -n '/^# Usage:/,/^# Example:/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^Example:'
    exit 1
}

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

horizon_image() {
    kubectl -n "$NAMESPACE" get deploy horizon -o jsonpath='{.spec.template.spec.containers[?(@.name=="horizon")].image}'
}

release_status() {
    helm -n "$NAMESPACE" status "$RELEASE" -o json 2>/dev/null | grep -o '"status":"[a-z-]*"' | head -1 | cut -d'"' -f4
}

# Chart version of the installed release, from "helm list" (CHART column: <name>-<version>).
release_chart_version() {
    helm -n "$NAMESPACE" list --filter "^${RELEASE}\$" -o json \
        | grep -o '"chart":"[^"]*"' | cut -d'"' -f4 | sed "s/^horizon-//"
}

chart_path_version() {
    { helm show chart "$HORIZON_CHART" 2>/dev/null || true; } | awk '/^version:/ {print $2}'
}

# Horizon container image deployed by a given release revision.
revision_image() {
    helm -n "$NAMESPACE" get manifest "$RELEASE" --revision "$1" 2>/dev/null \
        | awk '/^kind: Deployment/ {d=1} d && /image: / && /horizon/ {gsub(/"/,"",$2); print $2; exit}'
}

wait_for_horizon_rollout() {
    log "Waiting for the Horizon deployment to roll out..."
    if ! kubectl -n "$NAMESPACE" rollout status deploy/horizon --timeout="${TIMEOUT}s"; then
        echo
        echo "Horizon rollout did not complete. New pods:"
        kubectl -n "$NAMESPACE" get pods -o wide | grep '^horizon-' | grep -v -- '-db-' || true
        local bad
        bad=$(kubectl -n "$NAMESPACE" get pods --no-headers | awk '/^horizon-/ && !/-db-/ && $2 != "1/1" {print $1; exit}')
        if [[ -n "$bad" ]]; then
            echo "--- last log lines of $bad:"
            kubectl -n "$NAMESPACE" logs "$bad" -c horizon --tail=25 2>/dev/null \
                || kubectl -n "$NAMESPACE" logs "$bad" -c horizon --previous --tail=25 2>/dev/null || true
        fi
        echo
        echo "The old Horizon pods keep serving until the new ones are Ready."
        echo "To go back to the stock Horizon image: HORIZON_CHART=$HORIZON_CHART $0 --rollback"
        exit 1
    fi
}

set_horizon_image() {
    log "helm upgrade $RELEASE (--reuse-values) with images.tags.horizon=$1 ..."
    helm -n "$NAMESPACE" upgrade "$RELEASE" "$HORIZON_CHART" --reuse-values \
        --set "images.tags.horizon=$1" >/dev/null
    [[ "$(horizon_image)" == "$1" ]] || die "helm upgrade finished but deploy/horizon uses $(horizon_image)."
}

cleanup_prepull() {
    kubectl -n "$PULL_SECRET_NAMESPACE" delete ds "$PREPULL_DS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- arguments / preflight
[[ $# -eq 1 ]] || usage
ACTION="install"; IMG=""
case "$1" in
    -h|--help) usage ;;
    --rollback) ACTION="rollback" ;;
    -*) usage ;;
    *) IMG="$1" ;;
esac

command -v kubectl >/dev/null 2>&1 || die "kubectl is not installed."
command -v helm >/dev/null 2>&1 || die "helm is not installed."
[[ -n "${HORIZON_CHART:-}" ]] || die "set HORIZON_CHART to the horizon chart the release was installed from (e.g. /opt/openstack-helm/horizon)."

[[ -n "$(release_status)" ]] || die "Helm release '$RELEASE' not found in '$NAMESPACE'."
INSTALLED_VERSION="$(release_chart_version)"
CHART_VERSION="$(chart_path_version)"
[[ -n "$CHART_VERSION" ]] || die "HORIZON_CHART='$HORIZON_CHART' is not a readable Helm chart."
[[ "$CHART_VERSION" == "$INSTALLED_VERSION" ]] \
    || die "HORIZON_CHART is version $CHART_VERSION but release '$RELEASE' runs $INSTALLED_VERSION; use the matching chart."
log "Release: $NAMESPACE/$RELEASE (chart $INSTALLED_VERSION), current Horizon image: $(horizon_image)"

# Never upgrade while another Helm operation on the release is in progress.
[[ "$(release_status)" == "deployed" ]] \
    || die "release '$RELEASE' is '$(release_status)'; wait for the running Helm operation to finish."

# ---------------------------------------------------------------- rollback
if [[ "$ACTION" == "rollback" ]]; then
    if [[ "$(horizon_image)" != *"$PLUGIN_IMAGE_MATCH"* ]]; then
        log "Horizon does not run the Trilio plugin image; nothing to roll back."
        exit 0
    fi
    # Newest earlier revision whose Horizon image is not a Trilio plugin image.
    STOCK=""
    for rev in $(helm -n "$NAMESPACE" history "$RELEASE" --max 256 -o json \
                    | grep -o '"revision":[0-9]*' | cut -d: -f2 | sort -rn); do
        img="$(revision_image "$rev")"
        if [[ -n "$img" && "$img" != *"$PLUGIN_IMAGE_MATCH"* ]]; then STOCK="$img"; break; fi
    done
    [[ -n "$STOCK" ]] || die "no earlier revision of '$RELEASE' with a stock Horizon image; set it by hand with helm upgrade."
    set_horizon_image "$STOCK"
    wait_for_horizon_rollout
    log "Rolled back. Horizon image: $(horizon_image)"
    exit 0
fi

# ---------------------------------------------------------------- install
kubectl -n "$PULL_SECRET_NAMESPACE" get secret "$PULL_SECRET" >/dev/null 2>&1 \
    || die "pull secret '$PULL_SECRET' not found in '$PULL_SECRET_NAMESPACE'; run ./create_image_pull_secret.sh first."

if [[ "$(horizon_image)" == "$IMG" ]]; then
    log "Horizon already uses $IMG; nothing to do."
    exit 0
fi

# 1. Pre-pull the image on every node Horizon can run on (same nodeSelector as deploy/horizon).
NODE_SELECTOR="$(kubectl -n "$NAMESPACE" get deploy horizon -o jsonpath='{.spec.template.spec.nodeSelector}')"
[[ -n "$NODE_SELECTOR" ]] || NODE_SELECTOR="{}"
trap cleanup_prepull EXIT
cleanup_prepull
log "Pre-pulling $IMG on the Horizon nodes (nodeSelector $NODE_SELECTOR)..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $PREPULL_DS
  namespace: $PULL_SECRET_NAMESPACE
spec:
  selector:
    matchLabels: {app: $PREPULL_DS}
  template:
    metadata:
      labels: {app: $PREPULL_DS}
    spec:
      nodeSelector: $NODE_SELECTOR
      imagePullSecrets: [{name: $PULL_SECRET}]
      terminationGracePeriodSeconds: 0
      containers:
      - name: prepull
        image: "$IMG"
        command: ["sleep", "3600"]
        resources: {requests: {cpu: 10m, memory: 16Mi}}
EOF
if ! kubectl -n "$PULL_SECRET_NAMESPACE" rollout status ds/"$PREPULL_DS" --timeout="${TIMEOUT}s"; then
    echo "Image pre-pull failed. Pod status:"
    kubectl -n "$PULL_SECRET_NAMESPACE" get pods -l app="$PREPULL_DS" -o wide || true
    kubectl -n "$PULL_SECRET_NAMESPACE" get events --field-selector reason=Failed 2>/dev/null | grep "$PREPULL_DS" | tail -5 || true
    die "could not pull $IMG (check the tag and the '$PULL_SECRET' credentials)."
fi
cleanup_prepull
trap - EXIT
log "Image cached on all Horizon nodes."

# 2. Point Horizon at the plugin image, then wait for the pods to roll.
set_horizon_image "$IMG"
wait_for_horizon_rollout

# 3. Verify the plugin is loaded in a running pod.
POD=$(kubectl -n "$NAMESPACE" get pods --no-headers | awk '/^horizon-/ && !/-db-/ && $2 == "1/1" {print $1; exit}')
ENABLED=$(kubectl -n "$NAMESPACE" exec "$POD" -c horizon -- sh -c \
    'ls /var/lib/openstack/lib/python3*/site-packages/openstack_dashboard/local/enabled/ \
        /var/lib/openstack/lib/python3*/site-packages/openstack_dashboard/enabled/ 2>/dev/null | grep -c "_tvault_"' || true)
log "Horizon pods:"
kubectl -n "$NAMESPACE" get pods -o wide | grep '^horizon-' | grep -v -- '-db-'
if [[ "${ENABLED:-0}" -gt 0 ]]; then
    log "Trilio Horizon plugin installed ($ENABLED panel files enabled in $POD)."
    echo "Log out of Horizon and back in to see the Backups tab."
else
    die "Horizon rolled out, but no Trilio panel files were found in $POD."
fi
