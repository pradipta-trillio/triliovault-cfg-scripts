#!/usr/bin/env bash
## TVAULT-7517-class fix: the RabbitMQ CR (rabbitmq-cluster.yaml) used to be templated
## as a Helm post-install/post-upgrade hook with no delete-policy. Helm never stamps
## ownership metadata (app.kubernetes.io/managed-by, meta.helm.sh/release-*) onto hook
## resources, so any RabbitMQ CR created by a pre-fix operator build permanently lacks
## it. The first upgrade to a post-fix operator build (where the CR is a normal
## templated resource) then fails with:
##   "cannot be imported into the current release: invalid ownership metadata"
## because Helm's release-computation step refuses to adopt a pre-existing,
## unowned object - and this happens before any hooks/resources are applied, so
## nothing inside the chart itself can self-correct it.
##
## The Galera CR (galera-cluster.yaml) had the same hook-without-delete-policy pattern
## and is fixed the same way, so it is adopted here proactively too.
##
## This script patches ownership metadata onto both CRs if they exist and are missing
## it. It is idempotent and safe to run unconditionally on every deploy/upgrade:
## it no-ops if a CR doesn't exist (fresh install) or already carries the label
## (already adopted).
set -euo pipefail

NAMESPACE="trilio-openstack"
INPUTS_FILE="${1:-./tvo-operator-inputs.yaml}"

RELEASE_NAME="$(oc get -f "$INPUTS_FILE" -o jsonpath='{.metadata.name}')"

adopt_resource() {
  local resource_type="$1"
  local resource_name="$2"

  if ! oc -n "$NAMESPACE" get "$resource_type" "$resource_name" &>/dev/null; then
    echo "adopt_legacy_hook_resources: $resource_type/$resource_name not found, skipping"
    return 0
  fi

  local managed_by
  managed_by="$(oc -n "$NAMESPACE" get "$resource_type" "$resource_name" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  if [ "$managed_by" = "Helm" ]; then
    echo "adopt_legacy_hook_resources: $resource_type/$resource_name already Helm-managed, skipping"
    return 0
  fi

  echo "adopt_legacy_hook_resources: patching $resource_type/$resource_name with Helm ownership metadata (release: $RELEASE_NAME)"
  oc -n "$NAMESPACE" patch "$resource_type" "$resource_name" \
    --type=merge -p "{
      \"metadata\": {
        \"labels\": {
          \"app.kubernetes.io/managed-by\": \"Helm\"
        },
        \"annotations\": {
          \"meta.helm.sh/release-name\": \"${RELEASE_NAME}\",
          \"meta.helm.sh/release-namespace\": \"${NAMESPACE}\"
        }
      }
    }"
}

# RabbitMQ CRD kind depends on the RHOSO RabbitMQ operator in use (TVAULT-7511):
# community RabbitMQ Cluster Operator (<18.0.21) vs RHOSO's native operator (>=18.0.21).
OPENSTACK_VERSION="$(oc get openstackversion openstack-controlplane -n openstack -o jsonpath='{.status.deployedVersion}')"
BASE_VERSION="$(echo "$OPENSTACK_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
SMALLER="$(printf '%s\n%s\n' "18.0.21" "$BASE_VERSION" | sort -V | head -n1)"
if [ "$SMALLER" = "18.0.21" ]; then
  # OPENSTACK_VERSION >= 18.0.21 (FR6 onwards)
  adopt_resource "rabbitmq.rabbitmq.openstack.org" "trilio-rabbitmq-cluster"
else
  # OPENSTACK_VERSION < 18.0.21 (till FR5)
  adopt_resource "rabbitmqcluster" "trilio-rabbitmq-cluster"
fi

adopt_resource "galera.mariadb.openstack.org" "trilio-galera-cluster"
