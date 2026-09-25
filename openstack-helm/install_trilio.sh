#!/usr/bin/env bash
#
# install_trilio.sh — interactive installer for Trilio for OpenStack (T4O)
#                     on OpenStack Helm and MOSK.
#
# Covers documented install steps 3 through 10 in one flow: image tags, the
# trilio-openstack namespace, node labels, the internal RabbitMQ, Keystone/DB/
# RabbitMQ credentials, Ceph, the registry pull secret, and the helm install
# itself. It does not build, and it does not install the Horizon plugin
# (documented step 14) or run the upgrade path (see scripts/upgrade-process.md).
#
# The individual scripts under trilio-openstack/utils/ still do the real work —
# this drives them in the right order, with the right per-cloud variant, and
# asks for the handful of values only the operator knows.
#
# USAGE
#   bash ./install_trilio.sh [options]
#
#   Your shell may be fish; always invoke it as `bash ./install_trilio.sh`.
#
# OPTIONS
#   -a, --answers FILE     Read answers from FILE (KEY=value). See
#                          installer-answers.example.env.
#   -y, --yes              Take every default without asking. Fails if a
#                          question has no default. Implies non-interactive.
#   -n, --dry-run          Detect, prompt, generate the run file and render it
#                          with `helm template`. Never touches the cluster.
#       --resume           Skip steps already recorded complete in
#                          .install_state.
#       --from STEP        Start at STEP (see --list-steps).
#       --only STEP        Run exactly one step.
#       --list-steps       Print the step table and exit.
#       --rotate-passwords Regenerate triliovault_passwords.yaml even though it
#                          already exists. Read the warning it prints first.
#       --delete-jobs      Delete completed Trilio Jobs before installing,
#                          without asking. Needed on any re-install: a Job's
#                          pod template is immutable, so `helm upgrade` fails
#                          with "field is immutable" if one is left behind.
#       --extra-values F   Append an extra --values file. Repeatable.
#       --no-color         Disable colour.
#   -h, --help             This text.
#
# EXIT CODES
#   0 success   1 error   2 aborted by the operator
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Paths. Everything is absolute and derived from this script's own location, so
# the wrapper never depends on the caller's working directory.
# ---------------------------------------------------------------------------
OSH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="$OSH_DIR/trilio-openstack"
UTILS_DIR="$CHART_DIR/utils"
VO_DIR="$CHART_DIR/values_overrides"
BIN_DIR="$CHART_DIR/templates/bin"

STATE_FILE="$OSH_DIR/.install_state"
RUN_FILE="$OSH_DIR/.install.generated.sh"
LOG_FILE="$OSH_DIR/install-$(date '+%Y%m%d-%H%M%S').log"

NAMESPACE="trilio-openstack"
OS_NAMESPACE="openstack"
RELEASE="trilio-openstack"

# ---------------------------------------------------------------------------
# Output helpers. Same shape as juju-charms/devops-build-publish.sh.
# ---------------------------------------------------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

no_color() { GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; NC=''; }
[[ -t 1 ]] || no_color

say()  { printf '%b\n' "$*" | tee -a "$LOG_FILE"; }
info() { say "${BLUE}==>${NC} $*"; }
warn() { say "${YELLOW}WARNING:${NC} $*"; }
err()  { say "${RED}ERROR:${NC} $*" >&2; }
die()  { err "$*"; say ""; say "Log: $LOG_FILE"; exit 1; }

banner() {
  say ""
  say "${BOLD}────────────────────────────────────────────────────────────────${NC}"
  say "${BOLD} $*${NC}"
  say "${BOLD}────────────────────────────────────────────────────────────────${NC}"
}

step_ok()   { say "  ${GREEN}OK${NC}       $*"; }

# Shown under any question the operator cannot work out from the cluster.
support_hint() {
  say "  ${YELLOW}If you are unsure, stop and ask Trilio support rather than guessing.${NC}"
}
step_skip() { say "  ${YELLOW}SKIPPED${NC}  $*"; }
step_fail() { say "  ${RED}FAILED${NC}   $*"; }

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------
ANSWERS_FILE=""; ASSUME_YES=0; DRY_RUN=0; RESUME=0
FROM_STEP=""; ONLY_STEP=""; ROTATE_PASSWORDS=0; DELETE_JOBS=0
EXTRA_VALUES=()

usage() { sed -n '2,/^set -uo/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--answers)       ANSWERS_FILE="${2:?--answers needs a file}"; shift 2 ;;
    -y|--yes)           ASSUME_YES=1; shift ;;
    -n|--dry-run)       DRY_RUN=1; shift ;;
    --resume)           RESUME=1; shift ;;
    --from)             FROM_STEP="${2:?--from needs a step}"; shift 2 ;;
    --only)             ONLY_STEP="${2:?--only needs a step}"; shift 2 ;;
    --list-steps)       LIST_STEPS=1; shift ;;
    --rotate-passwords) ROTATE_PASSWORDS=1; shift ;;
    --delete-jobs)      DELETE_JOBS=1; shift ;;
    --extra-values)     EXTRA_VALUES+=("${2:?--extra-values needs a file}"); shift 2 ;;
    --no-color)         no_color; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                  err "unknown option: $1"; echo; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Step table. Order is a dependency order, not a preference:
#   rabbitmq  must precede admin_creds — the latter reads secret/rabbitmq-default-user
#   namespace must precede rabbitmq and pull_secret
#   everything must precede install
# ---------------------------------------------------------------------------
STEPS=(
  namespace    # doc step 4
  labels       # doc step 5
  rabbitmq     # doc step 6 on MOSK, inside step 7 on Helm
  pull_secret  # doc step 9
  image_tags   # doc step 3
  admin_creds  # doc step 7
  ceph         # doc step 8
  passwords    # undocumented, but install.sh requires the output
  dns          # MOSK only, optional
  install      # doc step 10
  verify       # doc step 10.4
)

if [[ -n "${LIST_STEPS:-}" ]]; then
  printf '%s\n' "${STEPS[@]}"
  exit 0
fi

# Validate step names up front. Without this a typo silently matches nothing and
# the run ends with a cheerful "Done".
valid_step() { local s; for s in "${STEPS[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }
for _s in "$FROM_STEP" "$ONLY_STEP"; do
  [[ -z "$_s" ]] && continue
  valid_step "$_s" || { echo "unknown step: $_s" >&2
                        echo "known steps: ${STEPS[*]}" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Answers: CLI flag > environment > answers file > detection > default.
# The answers file is sourced through a whitelist so a stray file cannot run
# anything. Only T4OI_* keys with safe-looking values are accepted.
# ---------------------------------------------------------------------------
load_answers() {
  [[ -z "$ANSWERS_FILE" ]] && return 0
  [[ -r "$ANSWERS_FILE" ]] || die "cannot read answers file: $ANSWERS_FILE"
  local line key val
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^(T4OI_[A-Z0-9_]+)=(.*)$ ]] || { warn "ignoring unparseable answers line: $line"; continue; }
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    if [[ "$val" =~ [\`\$\;\&\|\<\>] ]]; then
      warn "ignoring $key: value contains shell metacharacters"
      continue
    fi
    # Environment wins over the file.
    [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$val"
    export "${key?}"
  done < "$ANSWERS_FILE"
  info "answers loaded from $ANSWERS_FILE"
}

# ask VAR "prompt" "default"        — free text
# ask_secret VAR "prompt"           — no echo, never defaulted, never logged
# ask_yesno VAR "prompt" yes|no     — sets VAR to yes/no
# ask_menu VAR "prompt" default -- item...
#
# Each honours an already-set environment variable of the same name, and each
# falls back to the default under --yes or when stdin is not a terminal. That
# TTY guard is the pattern from test/01_check_backup_targets.sh:284 — prompt
# only when someone is there to answer.
interactive() { [[ $ASSUME_YES -eq 0 && -t 0 ]]; }

ask() {
  local var="$1" prompt="$2" def="${3-}" reply
  if [[ -n "${!var:-}" ]]; then say "  $prompt ${BOLD}${!var}${NC} (preset)"; log_answer "$var"; return 0; fi
  if ! interactive; then
    [[ -n "$def" ]] || die "no value and no default for $var (non-interactive)"
    printf -v "$var" '%s' "$def"; say "  $prompt ${BOLD}$def${NC} (default)"
    log_answer "$var"; return 0
  fi
  read -r -p "  $prompt${def:+ [$def]}: " reply
  printf -v "$var" '%s' "${reply:-$def}"
  [[ -n "${!var}" ]] || die "$var cannot be empty"
  log_answer "$var"
}

ask_secret() {
  local var="$1" prompt="$2" reply
  if [[ -n "${!var:-}" ]]; then say "  $prompt ${BOLD}(from environment)${NC}"; return 0; fi
  interactive || die "$var must be set in the environment when non-interactive"
  read -r -s -p "  $prompt: " reply; echo
  printf -v "$var" '%s' "$reply"
  [[ -n "${!var}" ]] || die "$var cannot be empty"
}

ask_yesno() {
  local var="$1" prompt="$2" def="$3" reply
  if [[ -n "${!var:-}" ]]; then say "  $prompt ${BOLD}${!var}${NC} (preset)"; return 0; fi
  if ! interactive; then
    printf -v "$var" '%s' "$def"; say "  $prompt ${BOLD}$def${NC} (default)"
    log_answer "$var"; return 0
  fi
  while true; do
    read -r -p "  $prompt [$( [[ $def == yes ]] && echo 'Y/n' || echo 'y/N' )]: " reply
    reply="${reply:-$def}"
    case "${reply,,}" in
      y|yes) printf -v "$var" '%s' yes; break ;;
      n|no)  printf -v "$var" '%s' no;  break ;;
      *)     echo "    please answer y or n" ;;
    esac
  done
  log_answer "$var"
}

# Menu items are "label|note", or the literal "--separator--|<heading>" for a
# non-selectable divider. The prompt asks for a NUMBER and shows the default as
# a number, so nobody is invited to retype a long filename — but a typed label
# is accepted too rather than bounced.
ask_menu() {
  local var="$1" prompt="$2" def="$3"; shift 3; [[ "$1" == "--" ]] && shift
  local items=("$@") i reply label note def_idx="" n=0
  declare -a choices=()

  if [[ -n "${!var:-}" ]]; then say "  $prompt ${BOLD}${!var}${NC} (preset)"; log_answer "$var"; return 0; fi
  if ! interactive; then
    printf -v "$var" '%s' "$def"; say "  $prompt ${BOLD}$def${NC} (default)"
    log_answer "$var"; return 0
  fi

  say "  $prompt"
  for i in "${!items[@]}"; do
    label="${items[$i]%%|*}"; note="${items[$i]#*|}"
    [[ "$note" == "${items[$i]}" ]] && note=""
    if [[ "$label" == "--separator--" ]]; then
      printf '        %b%s%b\n' "$YELLOW" "$note" "$NC"
      continue
    fi
    n=$((n + 1)); choices+=("$label")
    [[ "$label" == "$def" ]] && def_idx="$n"
    printf '    %2d) %-28s %s%s\n' "$n" "$label" "$note" \
      "$( [[ "$label" == "$def" ]] && printf '  %b<- default%b' "$GREEN" "$NC" )"
  done

  while true; do
    read -r -p "  Enter 1-${n}${def_idx:+ [$def_idx]}: " reply
    if [[ -z "$reply" && -n "$def_idx" ]]; then printf -v "$var" '%s' "$def"; break; fi
    if [[ "$reply" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= n )); then
      printf -v "$var" '%s' "${choices[$((reply-1))]}"; break
    fi
    # Be forgiving: someone who types the label instead of the number meant it.
    local c found=""
    for c in "${choices[@]}"; do [[ "$c" == "$reply" ]] && { found="$c"; break; }; done
    if [[ -n "$found" ]]; then printf -v "$var" '%s' "$found"; break; fi
    say "    ${YELLOW}Enter a number from 1 to ${n}${def_idx:+, or press Enter for $def_idx}.${NC}"
  done
  say "    selected: ${BOLD}${!var}${NC}"
  log_answer "$var"
}

ANSWERS_OUT="$OSH_DIR/.install_state.answers"
log_answer() {
  # Record every answer as it is given, so aborting at question 9 does not lose
  # the first eight. Credentials are never written here.
  local var="$1"
  case "$var" in *PASSWORD*|*SECRET*) return 0 ;; esac
  touch "$ANSWERS_OUT"; chmod 600 "$ANSWERS_OUT"
  sed -i "/^${var}=/d" "$ANSWERS_OUT" 2>/dev/null || true
  printf '%s=%s\n' "$var" "${!var}" >> "$ANSWERS_OUT"
}

confirm() {
  local prompt="$1" reply
  interactive || return 0
  read -r -p "  $prompt [y/N]: " reply
  [[ "${reply,,}" =~ ^y ]]
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
state_done() { grep -qx "$1=done" "$STATE_FILE" 2>/dev/null; }
state_set()  { touch "$STATE_FILE"; sed -i "/^$1=/d" "$STATE_FILE" 2>/dev/null || true
               printf '%s=done\n' "$1" >> "$STATE_FILE"; }

# ---------------------------------------------------------------------------
# run_util — the only way this script calls anything under utils/.
#
# Two things matter here:
#   * the subshell. Every utils script does `cd ../` or `cd ../../` and uses
#     relative paths, so it only works with CWD == utils/. The subshell gives it
#     that without moving this script, and without leaving us in utils/ if it
#     dies.
#   * `bash ./x.sh` rather than `./x.sh`. Four of those scripts are
#     `#!/bin/bash -x`, and running them through the shebang echoes the
#     dockerhub password, the MariaDB root password and the Ceph keyring to the
#     terminal and into the tee'd log. Invoking via bash ignores the shebang.
# ---------------------------------------------------------------------------
run_util() {
  local script="$1"; shift
  [[ -f "$UTILS_DIR/$script" ]] || die "missing utils script: $script"
  ( cd "$UTILS_DIR" && bash "./$script" "$@" ) 2>&1 | redact | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

# Belt and braces on top of dropping xtrace: scrub anything that looks like a
# credential out of whatever the utils scripts print.
redact() {
  sed -E \
    -e 's/(keyring:[[:space:]]*).*/\1<redacted>/' \
    -e 's/(password[[:space:]]*[:=][[:space:]]*).*/\1<redacted>/I' \
    -e 's/(--docker-password=).*/\1<redacted>/'
}

kexists() { kubectl get "$@" >/dev/null 2>&1; }

# The datamover templates must be INJECTED, not pristine, before helm ships
# them. Two distinct failures to catch:
#
#   * a leftover <INJECT_*> marker — the literal string would land in the
#     configmap and the datamover's entrypoint is then a bash syntax error;
#   * sync_nova_compute.sh finding zero config files, which drops the marker
#     and injects nothing. That is invisible to a marker check, so we also
#     require the injected --config-file lines to be there. Two are hardcoded
#     in the pristine template; a real injection adds more.
assert_datamover_injected() {
  local init="$BIN_DIR/_triliovault-datamover-init.sh.tpl"
  local main="$BIN_DIR/_triliovault-datamover.sh.tpl"
  local t
  for t in "$init" "$main"; do
    if grep -q '<INJECT_' "$t"; then
      err "$(basename "$t") still holds an <INJECT_*> marker."
      err "sync_nova_compute.sh has not run against it. Shipping this would give"
      err "the datamover an entrypoint that is not valid bash."
      err "Re-run:  bash ./install_trilio.sh --only admin_creds"
      return 1
    fi
  done
  local n; n="$(grep -c -- '--config-file=' "$main" 2>/dev/null || echo 0)"
  if (( n <= 2 )); then
    err "$(basename "$main") has only $n --config-file entries — the two baked-in"
    err "ones and nothing injected. sync_nova_compute.sh found no config files in"
    err "configmap/nova-bin, so the datamover would start without the cloud's nova"
    err "configuration."
    err "Check:  kubectl -n $OS_NAMESPACE get cm nova-bin -o jsonpath='{.data.nova-compute-init\\.sh}'"
    return 1
  fi
  step_ok "datamover templates injected ($n --config-file entries)"
}

# ===========================================================================
# Preflight
# ===========================================================================
preflight() {
  banner "Preflight"

  (( BASH_VERSINFO[0] >= 4 )) || die "bash 4+ required (associative arrays); found $BASH_VERSION"

  local missing=()
  for c in kubectl helm jq sed awk base64 diff; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    err "missing required commands: ${missing[*]}"
    # jq is the sharp edge: wait_for_pods.sh is pure jq and fails AFTER a
    # successful helm install, which reads like an install failure.
    die "install them first, e.g.  sudo apt update && sudo apt install -y make jq"
  fi
  step_ok "tooling"

  local hv; hv="$(helm version --short 2>/dev/null)"
  [[ "$hv" =~ ^v3 ]] || die "helm 3 required; found '${hv:-none}'"
  step_ok "helm $hv"

  timeout 15 kubectl cluster-info >/dev/null 2>&1 \
    || die "cannot reach the cluster. Check KUBECONFIG and your current context."
  step_ok "cluster reachable"

  kexists namespace "$OS_NAMESPACE" \
    || die "namespace '$OS_NAMESPACE' not found — every credential script reads from it"
  step_ok "namespace $OS_NAMESPACE"

  # Materialise any MISSING generated template. --if-missing is load-bearing:
  # a rendered datamover template has had its <INJECT_*> markers replaced with
  # this cloud's nova config, and re-stubbing it would ship a configmap holding
  # the literal string "<INJECT_CONFIG_FILES>" — a bash syntax error that
  # crash-loops the datamover. Only sync_nova_compute.sh restores by force, and
  # it re-injects immediately afterwards.
  run_util restore_templates.sh --if-missing >/dev/null \
    || die "could not materialise templates/bin/*.tpl"
  step_ok "templates present"

  if ! ls "$CHART_DIR"/charts/helm-toolkit-*.tgz >/dev/null 2>&1; then
    info "resolving chart dependencies"
    # The dependency is file://../charts/helm-toolkit, so this only resolves
    # from openstack-helm/.
    ( cd "$OSH_DIR" && helm dep up ./trilio-openstack ) >>"$LOG_FILE" 2>&1 \
      || die "helm dep up failed; see $LOG_FILE"
  fi
  step_ok "chart dependencies"

  for d in "$UTILS_DIR" "$VO_DIR" "$BIN_DIR" "$OSH_DIR"; do
    [[ -w "$d" ]] || die "not writable: $d"
  done
  step_ok "writable paths"
}

# ===========================================================================
# Detection + questions
# ===========================================================================
detect_and_ask() {
  banner "Cloud"

  # MOSK ships the OpenStackDeployment CRD; vanilla OpenStack Helm does not.
  local flavour_def="helm"
  kexists crd openstackdeployments.lcm.mirantis.com && flavour_def="mosk"
  ask_menu T4OI_FLAVOUR "Select your cloud type:" "$flavour_def" -- \
    "helm|vanilla OpenStack Helm" \
    "mosk|Mirantis OpenStack for Kubernetes"
  FLAVOUR="$T4OI_FLAVOUR"

  local ctx; ctx="$(kubectl config current-context 2>/dev/null)"
  say ""
  say "  kube context : ${BOLD}${ctx}${NC}"
  say "  api server   : $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  if interactive && ! confirm "Install T4O into this cluster?"; then
    say "aborted"; exit 2
  fi

  # --- version file ------------------------------------------------------
  banner "Version"
  select_version_file

  # --- image tags --------------------------------------------------------
  banner "Image tags"
  ask_image_tags || die "image tag/registry not accepted"

  # --- everything else ---------------------------------------------------
  banner "Cloud details"

  # Ceph: decided by which keyring secret the cloud actually has.
  local ceph_def=no
  if [[ "$FLAVOUR" == mosk ]]; then
    kexists -n "$OS_NAMESPACE" secret nova-rbd-keyring && ceph_def=yes
  else
    kexists -n "$OS_NAMESPACE" secret cinder-volume-rbd-keyring && ceph_def=yes
  fi
  ask_yesno T4OI_USE_CEPH "Do nova/cinder use Ceph as their backend?" "$ceph_def"

  local tls_def=no
  kexists -n "$OS_NAMESPACE" secret keystone-tls-public && tls_def=yes
  ask_yesno T4OI_TLS_PUBLIC "Are the public OpenStack endpoints TLS (https/443)?" "$tls_def"

  # Domain names. The public one is derivable from the keystone ingress host.
  local pub_def="" int_def="cluster.local"
  pub_def="$(kubectl -n "$OS_NAMESPACE" get ingress keystone \
              -o jsonpath='{.spec.rules[0].host}' 2>/dev/null | sed 's/^keystone\.//')"
  say ""
  say "  Domain names, as used by your OpenStack endpoints. Check them with"
  say "  'openstack endpoint list', or grep domain_name in your deployment yaml."
  support_hint
  ask T4OI_INTERNAL_DOMAIN "Kubernetes internal domain name" "$int_def"
  ask T4OI_PUBLIC_DOMAIN   "Public domain name of the cloud" "$pub_def"

  # Registry pull secret — skipped entirely if it already exists in both
  # namespaces, which is the common case on a re-run.
  NEED_PULL_SECRET=yes
  if kexists -n "$NAMESPACE" secret triliovault-image-registry \
     && kexists -n "$OS_NAMESPACE" secret triliovault-image-registry; then
    NEED_PULL_SECRET=no
  fi
  if [[ "$NEED_PULL_SECRET" == yes ]]; then
    say ""
    say "  Credentials for the private Trilio image registry."
    say "  ${YELLOW}Trilio Sales/Support issue these — they are not your dockerhub login.${NC}"
    ask        T4OI_REGISTRY_USERNAME "Trilio registry (dockerhub) username" ""
    ask_secret T4OI_REGISTRY_PASSWORD "Trilio registry (dockerhub) password"
  fi

  # CoreDNS host entry — MOSK only, and off by default. It rewrites a
  # cluster-wide configmap, so it is never something to do silently.
  if [[ "$FLAVOUR" != mosk ]]; then
    # Not offered on vanilla OpenStack Helm.
    T4OI_ADD_DNS_ENTRY="${T4OI_ADD_DNS_ENTRY:-no}"
  else
    say ""
    say "  A CoreDNS host entry is only needed when the backup-target (S3)"
    say "  endpoint FQDN does not already resolve inside the cluster."
    ask_yesno T4OI_ADD_DNS_ENTRY "Add a CoreDNS host entry for the S3 endpoint?" no
    if [[ "$T4OI_ADD_DNS_ENTRY" == yes ]]; then
      ask T4OI_DNS_IP       "S3 endpoint IP address" ""
      ask T4OI_DNS_HOSTNAME "S3 endpoint hostname" ""
    fi
  fi
}

# --- version file selection -------------------------------------------------
# Version files are content-detected, not name-matched: a version file is
# defined by the thing it exists to carry. Filename rules (mosk*, 20*, a
# denylist) break the moment someone adds epoxy.yaml or 2026.1.yaml.
# triliovault_wlm_api is present in every version file, including the pre-DMS
# ones, and in none of the functional overrides.
select_version_file() {
  local all=() f
  mapfile -t all < <(cd "$VO_DIR" && grep -lE '^[[:space:]]+triliovault_wlm_api:[[:space:]]*\S' -- *.yaml 2>/dev/null | sort -V)

  if (( ${#all[@]} == 0 )); then
    err "no version files found in $VO_DIR"
    err "expected at least one yaml containing an 'images.tags.triliovault_wlm_api' key."
    ls -1 "$VO_DIR" | sed 's/^/    /' >&2
    die "chart layout has changed; pass one explicitly with T4OI_VERSION_FILE"
  fi

  # Filter to the chosen flavour, but never hide anything: the other flavour's
  # files are appended after a separator.
  local mine=() other=()
  for f in "${all[@]}"; do
    if [[ "$f" == mosk* ]]; then
      [[ "$FLAVOUR" == mosk ]] && mine+=("$f") || other+=("$f")
    else
      [[ "$FLAVOUR" == mosk ]] && other+=("$f") || mine+=("$f")
    fi
  done

  # The default is whatever the tracked install script currently points at —
  # that is already the team's "recommended version", and it stays correct for
  # free when someone bumps it.
  local src="install.sh"; [[ "$FLAVOUR" == mosk ]] && src="install_mosk.sh"
  local def=""
  if [[ -f "$UTILS_DIR/$src" ]]; then
    while read -r cand; do
      for f in "${all[@]}"; do [[ "$f" == "$cand" ]] && { def="$cand"; break 2; }; done
    done < <(sed -nE 's#.*values_overrides/([^/[:space:]]+\.yaml).*#\1#p' "$UTILS_DIR/$src")
  fi
  [[ -n "$def" ]] || def="${mine[-1]:-${all[-1]}}"

  # Show each option with the tag it currently carries, so the choice is
  # informative rather than a guess from the filename.
  local menu=()
  for f in "${mine[@]}"; do menu+=("$f|$(current_tag_of "$VO_DIR/$f")"); done
  if (( ${#other[@]} )); then
    # Never hide the other flavour's files, but make it obvious they are not
    # for this cloud — picking one is almost always a mistake.
    local othername="MOSK"; [[ "$FLAVOUR" == mosk ]] && othername="OpenStack Helm"
    menu+=("--separator--|--- $othername files (not for this cloud) ---")
    for f in "${other[@]}"; do menu+=("$f|$(current_tag_of "$VO_DIR/$f")"); done
  fi

  say "  This is your cloud's OpenStack/MOSK release. It decides which image"
  say "  tags and base images are used."
  support_hint
  ask_menu T4OI_VERSION_FILE "Select your cloud version:" "$def" -- "${menu[@]}"
  VERSION_FILE="$T4OI_VERSION_FILE"
  [[ -f "$VO_DIR/$VERSION_FILE" ]] || die "no such version file: $VO_DIR/$VERSION_FILE"
}

current_tag_of() {
  sed -nE 's#^[[:space:]]*triliovault_wlm_api:[[:space:]]*\S+:(\S+)[[:space:]]*$#\1#p' "$1" | head -1
}
current_registry_of() {
  sed -nE 's#^[[:space:]]*triliovault_wlm_api:[[:space:]]*(\S+)/[^/]+:\S+[[:space:]]*$#\1#p' "$1" | head -1
}

# --- image tags -------------------------------------------------------------
# Every key in every version file shares one tag, so one question covers the
# realistic case. Defaults are parsed out of the chosen file, which handles a
# mirrored registry (harbor.corp/trilio-mirror) with no extra logic.
declare -A TRILIO_IMAGE=(
  [triliovault_wlm_cloud_trust]=trilio-wlm-helm
  [triliovault_wlm_api]=trilio-wlm-helm
  [triliovault_wlm_cron]=trilio-wlm-helm
  [triliovault_wlm_scheduler]=trilio-wlm-helm
  [triliovault_wlm_workloads]=trilio-wlm-helm
  [triliovault_wlm_db_sync]=trilio-wlm-helm
  [triliovault_datamover]=trilio-datamover-helm
  [triliovault_datamover_api]=trilio-datamover-api-helm
  [triliovault_datamover_db_sync]=trilio-datamover-api-helm
  [triliovault_dms]=trilio-dms-helm
  [triliovault_dms_init]=trilio-dms-helm
)

ask_image_tags() {
  local f="$VO_DIR/$VERSION_FILE"
  local cur_tag cur_reg
  cur_tag="$(current_tag_of "$f")"; cur_reg="$(current_registry_of "$f")"

  say "  $VERSION_FILE currently ships:"
  say "    registry : ${BOLD}${cur_reg:-<unset>}${NC}"
  say "    tag      : ${BOLD}${cur_tag:-<unset>}${NC}"
  say ""
  say "  The tag identifies the T4O build to install, e.g. ${BOLD}${cur_tag:-6.2.0-stable-1}${NC}."
  support_hint
  say ""

  # Tag first. The registry is asked second and behind a yes/no, because it
  # almost never changes and putting it first invites typing the tag into it —
  # which installs cleanly and then fails as ImagePullBackOff minutes later.
  ask T4OI_IMAGE_TAG "Trilio image tag" "${cur_tag}"

  [[ "$T4OI_IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] \
    || die "'$T4OI_IMAGE_TAG' is not a valid container image tag"

  if [[ -n "${T4OI_IMAGE_REGISTRY:-}" ]]; then
    say "  Registry: ${BOLD}${T4OI_IMAGE_REGISTRY}${NC} (preset)"
  else
    local use_mirror=""
    say ""
    say "  Images are pulled from ${BOLD}${cur_reg:-docker.io/trilio}${NC}."
    ask_yesno use_mirror "Pull them from a local mirror instead?" no
    if [[ "$use_mirror" == yes ]]; then
      ask T4OI_IMAGE_REGISTRY "Mirror registry prefix (host[:port]/path)" "${cur_reg:-docker.io/trilio}"
    else
      T4OI_IMAGE_REGISTRY="${cur_reg:-docker.io/trilio}"
    fi
  fi

  # A registry prefix is a host, optionally with a port and a path. Catch the
  # classic slip of a tag pasted in here before it reaches the cluster.
  if [[ "$T4OI_IMAGE_REGISTRY" != *[./:]* ]]; then
    err "'$T4OI_IMAGE_REGISTRY' does not look like a registry — no '.', ':' or '/' in it."
    err "A registry prefix looks like 'docker.io/trilio' or 'harbor.corp:5000/trilio'."
    err "Did you mean to type that as the image ${BOLD}tag${NC}?"
    return 1
  fi

  # A tag that does not carry the version-file suffix is usually a slip, but it
  # is legitimate for a one-off hotfix build. Offer, do not impose.
  local suffix="${VERSION_FILE%.yaml}"
  if [[ "$T4OI_IMAGE_TAG" != *"$suffix" ]] && interactive; then
    if confirm "Tag does not end in '-$suffix'. Use '${T4OI_IMAGE_TAG}-${suffix}' instead?"; then
      T4OI_IMAGE_TAG="${T4OI_IMAGE_TAG}-${suffix}"
    fi
  fi
}

# ===========================================================================
# Steps
# ===========================================================================

step_namespace() {
  if kexists namespace "$NAMESPACE"; then step_skip "namespace $NAMESPACE exists"; return 0; fi
  [[ $DRY_RUN -eq 1 ]] && { step_skip "namespace (dry run)"; return 0; }
  kubectl create namespace "$NAMESPACE" >>"$LOG_FILE" 2>&1 || return 1
  step_ok "namespace $NAMESPACE created"
}

step_labels() {
  local cp; cp="$(kubectl get nodes -l openstack-control-plane=enabled \
                    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  [[ -n "$cp" ]] || { warn "no nodes carry openstack-control-plane=enabled"; }

  local already; already="$(kubectl get nodes -l triliovault-control-plane=enabled \
                              -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  if [[ -n "$already" ]]; then
    step_skip "triliovault-control-plane already on: $already"
  else
    say "  openstack control plane nodes: ${BOLD}${cp:-none}${NC}"
    say "  Three nodes are recommended for the T4O control plane."
    ask T4OI_CONTROL_PLANE_NODES "Nodes to label (comma separated, or 'all')" "all"
    local targets="$T4OI_CONTROL_PLANE_NODES"
    [[ "$targets" == all ]] && targets="${cp// /,}"
    [[ -n "$targets" ]] || die "no nodes to label"
    [[ $DRY_RUN -eq 1 ]] && { step_skip "labels (dry run): $targets"; return 0; }
    local n
    for n in ${targets//,/ }; do
      kubectl label node "$n" triliovault-control-plane=enabled --overwrite >>"$LOG_FILE" 2>&1 || return 1
    done
    step_ok "labelled: $targets"
  fi

  # The datamover DaemonSet and the DMS compute DaemonSet both select on
  # openstack-compute-node=enabled (values.yaml labels.datamover and
  # labels.dms_compute). The install docs never mention this label, and without
  # it both DaemonSets schedule zero pods and nothing reports an error.
  local comp; comp="$(kubectl get nodes -l openstack-compute-node=enabled \
                        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
  if [[ -z "$comp" ]]; then
    warn "no nodes carry openstack-compute-node=enabled — the datamover and DMS"
    warn "DaemonSets select on it and will schedule zero pods. Label your compute"
    warn "nodes before creating any backup."
  else
    step_ok "compute nodes: $comp"
  fi
}

step_rabbitmq() {
  if kexists -n "$NAMESPACE" secret rabbitmq-default-user; then
    step_skip "RabbitMQ already present in $NAMESPACE"; return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { step_skip "rabbitmq (dry run)"; return 0; }

  # create_rabbitmq.sh pulls the cluster operator from the GitHub 'latest'
  # release — unpinned, needs egress to github.com, and installs a
  # cluster-scoped operator. Worth an explicit nod before it happens.
  if ! kexists crd rabbitmqclusters.rabbitmq.com; then
    warn "the RabbitMQ Cluster Operator is not installed."
    warn "create_rabbitmq.sh will fetch it from github.com (releases/latest,"
    warn "unpinned) and install it cluster-wide."
    interactive && { confirm "Proceed?" || { say "aborted"; exit 2; }; }
  fi

  # It pins requiredDuringScheduling affinity to openstack-control-plane=enabled
  # and asks for a 10Gi RWO volume. Both failures look like a bare 300s timeout.
  kubectl get nodes -l openstack-control-plane=enabled -o name 2>/dev/null | grep -q . \
    || warn "no openstack-control-plane=enabled node — the RabbitMQ pod will stay Pending"
  kubectl get storageclass -o jsonpath='{.items[*].metadata.annotations}' 2>/dev/null \
    | grep -q 'is-default-class":"true' \
    || warn "no default StorageClass — the RabbitMQ 10Gi PVC will stay Pending"

  run_util create_rabbitmq.sh || return 1
  step_ok "RabbitMQ ready"
}

step_pull_secret() {
  if [[ "${NEED_PULL_SECRET:-yes}" == no ]]; then
    step_skip "triliovault-image-registry exists in both namespaces"; return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { step_skip "pull secret (dry run)"; return 0; }
  # The secret must name the registry the images actually come from. Derive the
  # host from the registry prefix: docker.io/trilio -> docker.io,
  # harbor.corp:5000/trilio-mirror -> harbor.corp:5000.
  local server="${T4OI_IMAGE_REGISTRY%%/*}"
  run_util create_image_pull_secret.sh "$T4OI_REGISTRY_USERNAME" "$T4OI_REGISTRY_PASSWORD" "$server" || return 1
  step_ok "image pull secret for $server created in $NAMESPACE and $OS_NAMESPACE"
}

# Rewrite only the Trilio image keys in the chosen version file.
#
# No YAML library: yq is not a documented prerequisite anywhere in this repo.
# Each pattern is anchored with ^[[:space:]]*<key>: so triliovault_datamover:
# cannot match triliovault_datamover_api:, and triliovault_dms: cannot match
# triliovault_dms_init:. The heat/rabbit/dep_check tags in the same map are
# never named, so they are safe by construction.
step_image_tags() {
  local f="$VO_DIR/$VERSION_FILE"
  local reg="$T4OI_IMAGE_REGISTRY" tag="$T4OI_IMAGE_TAG"
  local before; before="$(mktemp)"; cp "$f" "$before"

  local k changed=0 appended=()
  for k in "${!TRILIO_IMAGE[@]}"; do
    local want="${reg}/${TRILIO_IMAGE[$k]}:${tag}"
    if grep -qE "^[[:space:]]*${k}:" "$f"; then
      sed -i -E "s#^([[:space:]]*)${k}:[[:space:]]*.*\$#\1${k}: ${want}#" "$f"
    else
      # Nine of the eleven version files predate DMS and omit the two dms keys.
      # Skipping them leaves DMS on the stale shruti-6.1.0-bobcat-2 default in
      # values.yaml, which is the silent version-skew trap. Insert instead.
      #
      # Insert AFTER the last existing triliovault_ key, never append: several
      # files end with a `...` YAML document-end marker, and anything after that
      # is not part of the document.
      local indent last
      indent="$(sed -nE 's#^([[:space:]]*)triliovault_wlm_api:.*#\1#p' "$f" | head -1)"
      last="$(grep -nE '^[[:space:]]*triliovault_[a-z_]+:' "$f" | tail -1 | cut -d: -f1)"
      if [[ -n "$last" ]]; then
        sed -i "${last}a\\${indent:-    }${k}: ${want}" "$f"
      else
        printf '%s%s: %s\n' "${indent:-    }" "$k" "$want" >> "$f"
      fi
      appended+=("$k")
    fi
    changed=$((changed + 1))
  done

  if diff -q "$before" "$f" >/dev/null; then
    step_skip "image tags already ${reg}/*:${tag}"
    rm -f "$before"; return 0
  fi

  say ""
  diff -u "$before" "$f" | sed 's/^/    /' | tee -a "$LOG_FILE"
  say ""
  (( ${#appended[@]} )) && warn "added missing keys: ${appended[*]} (they were falling back to the stale default in values.yaml)"

  if interactive && ! confirm "Apply this change to $VERSION_FILE?"; then
    cp "$before" "$f"; rm -f "$before"; say "reverted"; exit 2
  fi
  rm -f "$before"
  step_ok "$changed image tags set to ${reg}/*:${tag}"
  warn "$VERSION_FILE is tracked in git — do not commit a lab-specific tag."
}

step_admin_creds() {
  [[ $DRY_RUN -eq 1 ]] && { step_skip "admin creds (dry run)"; return 0; }

  local script="get_admin_creds.sh"
  [[ "$FLAVOUR" == mosk ]] && script="get_admin_creds_mosk.sh"

  # Precheck every secret it reads. It writes _triliovault-nova-compute.conf.tpl
  # BEFORE it touches the TLS secrets, so a missing secret leaves the tree half
  # modified and the error 30 lines up the scrollback.
  local need=(secret/nova-keystone-admin secret/mariadb-dbadmin-password
              secret/nova-etc secret/keystone-tls-public configmap/nova-bin)
  # trilio-ca-cert is not a stock OpenStack Helm secret; it is hand-created, and
  # only the non-MOSK variant reads it.
  [[ "$FLAVOUR" == helm ]] && need+=(secret/trilio-ca-cert)
  local o miss=()
  for o in "${need[@]}"; do kexists -n "$OS_NAMESPACE" "$o" || miss+=("$o"); done
  if (( ${#miss[@]} )); then
    err "missing in namespace $OS_NAMESPACE: ${miss[*]}"
    [[ " ${miss[*]} " == *" secret/trilio-ca-cert "* ]] && \
      err "trilio-ca-cert is created by hand; see the install guide, or point" && \
      err "$script at your own CA secret name."
    return 1
  fi

  run_util "$script" "$T4OI_INTERNAL_DOMAIN" "$T4OI_PUBLIC_DOMAIN" || return 1

  # Validate the output rather than trusting it. kubectl -o template on a
  # missing key emits nothing, so this script can produce a structurally valid
  # file with empty passwords that installs fine and fails auth ten minutes
  # later.
  local out="$VO_DIR/admin_creds.yaml"
  [[ -s "$out" ]] || { err "$out is empty"; return 1; }
  grep -q '<no value>' "$out" && { err "$out contains '<no value>' — a source secret key is missing"; return 1; }
  grep -qE '^[[:space:]]*(password|username):[[:space:]]*$' "$out" \
    && { err "$out has an empty credential field"; return 1; }
  step_ok "admin_creds.yaml written ($(wc -l <"$out") lines)"

  # sync_nova_compute.sh runs inside the script above and injects at the
  # <INJECT_*> markers. Assert it actually did: it restores from *.tpl.in first,
  # so the markers must be gone afterwards. If they are still there the
  # injection silently no-opped and the datamover would run with no config.
  assert_datamover_injected || return 1
}

step_ceph() {
  if [[ "$T4OI_USE_CEPH" != yes ]]; then
    step_skip "no Ceph backend — using no_ceph.yaml"; return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { step_skip "ceph (dry run)"; return 0; }
  local script="get_ceph.sh"
  [[ "$FLAVOUR" == mosk ]] && script="get_ceph_mosk.sh"
  run_util "$script" || return 1
  grep -qE '^[[:space:]]*keyring:[[:space:]]*\S' "$VO_DIR/ceph.yaml" \
    || { err "ceph.yaml has no keyring"; return 1; }
  step_ok "ceph.yaml and _triliovault-ceph.conf.tpl written"
}

step_passwords() {
  local f="$VO_DIR/triliovault_passwords.yaml"
  local release_exists=no
  helm status "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 && release_exists=yes

  if [[ -f "$f" && $ROTATE_PASSWORDS -eq 0 ]]; then
    step_skip "triliovault_passwords.yaml exists — keeping it"
    return 0
  fi
  if [[ ! -f "$f" && "$release_exists" == yes ]]; then
    err "release '$RELEASE' exists but triliovault_passwords.yaml is gone."
    err "The Keystone users, both MariaDB users and the RabbitMQ user still hold"
    err "the old passwords. Generating new ones here would lock the running"
    err "services out. Recover the file, or uninstall and reinstall."
    return 1
  fi
  if [[ -f "$f" && $ROTATE_PASSWORDS -eq 1 ]]; then
    warn "rotating passwords changes the Keystone passwords for triliovault_wlm"
    warn "and triliovault_datamover, both MariaDB user passwords, the RabbitMQ"
    warn "WLM password and the memcache secret key. Every T4O service must be"
    warn "restarted and the ks-user / db-init jobs must re-run."
    interactive && { confirm "Rotate anyway?" || { say "aborted"; exit 2; }; }
    cp "$f" "$f.bak-$(date '+%Y%m%d-%H%M%S')"
  fi

  [[ $DRY_RUN -eq 1 ]] && { step_skip "passwords (dry run)"; return 0; }
  run_util generate_passwords.sh || return 1
  chmod 600 "$f"
  step_ok "triliovault_passwords.yaml generated"
}

step_dns() {
  if [[ "${T4OI_ADD_DNS_ENTRY:-no}" != yes ]]; then
    step_skip "no CoreDNS entry requested"; return 0
  fi
  # add_dns_entry.sh injects after a `hosts {` line. With no such block in the
  # Corefile it inserts nothing, applies the configmap unchanged and reports
  # success.
  if ! kubectl -n kube-system get configmap coredns -o yaml 2>/dev/null | grep -q 'hosts[[:space:]]*{'; then
    warn "the CoreDNS Corefile has no 'hosts {' block, so add_dns_entry.sh would"
    warn "silently do nothing. Add the block by hand, then re-run with --only dns."
    return 0
  fi
  [[ $DRY_RUN -eq 1 ]] && { step_skip "dns (dry run)"; return 0; }
  kubectl -n kube-system get configmap coredns -o yaml > "$OSH_DIR/.coredns-backup-$(date '+%Y%m%d-%H%M%S').yaml"
  run_util add_dns_entry.sh "$T4OI_DNS_IP" "$T4OI_DNS_HOSTNAME" || return 1
  step_ok "CoreDNS entry $T4OI_DNS_IP $T4OI_DNS_HOSTNAME"
}

# --- the generated run file -------------------------------------------------
values_list() {
  local v=()
  v+=(image_pull_secrets.yaml)
  v+=(keystone.yaml)
  v+=("$VERSION_FILE")
  v+=(admin_creds.yaml)
  [[ "$T4OI_TLS_PUBLIC" == yes ]] && v+=(tls_public_endpoint.yaml)
  if [[ "$T4OI_USE_CEPH" == yes ]]; then v+=(ceph.yaml); else v+=(no_ceph.yaml); fi
  v+=(db_drop.yaml)
  if [[ "$FLAVOUR" == mosk ]]; then v+=(ingress_mosk.yaml); else v+=(ingress.yaml); fi
  v+=(triliovault_passwords.yaml)
  printf '%s\n' "${v[@]}"
}

generate_run_file() {
  local f
  {
    printf '#!/usr/bin/env bash\n'
    printf '# GENERATED by install_trilio.sh on %s — DO NOT EDIT BY HAND.\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '#   flavour=%s version=%s tag=%s\n' "$FLAVOUR" "$VERSION_FILE" "$T4OI_IMAGE_TAG"
    printf '#   ceph=%s tls_public=%s context=%s\n' "$T4OI_USE_CEPH" "$T4OI_TLS_PUBLIC" "$(kubectl config current-context 2>/dev/null)"
    printf '# Regenerate: bash ./install_trilio.sh --answers .install_state.answers --yes\n'
    printf 'set -euo pipefail\n'
    printf '# Same effective directory that utils/install.sh reaches via `cd ../../`,\n'
    printf '# so every ./trilio-openstack/... path below matches the tracked script.\n'
    printf 'cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"\n\n'
    printf 'kubectl get namespace %s >/dev/null 2>&1 || kubectl create namespace %s\n' "$NAMESPACE" "$NAMESPACE"
    printf 'kubectl config set-context --current --namespace=%s\n\n' "$NAMESPACE"
    printf 'helm upgrade --install %s ./trilio-openstack --namespace=%s \\\n' "$RELEASE" "$NAMESPACE"
    while read -r f; do
      printf '  --values=./trilio-openstack/values_overrides/%s \\\n' "$f"
    done < <(values_list)
    local e
    for e in "${EXTRA_VALUES[@]}"; do printf '  --values=%s \\\n' "$e"; done
    printf '  --timeout 20m\n\n'
    printf 'echo "Waiting for %s pods to reach Running/Completed"\n' "$NAMESPACE"
    printf './trilio-openstack/utils/wait_for_pods.sh %s 1200\n\n' "$NAMESPACE"
    printf 'kubectl get pods -n %s\n' "$NAMESPACE"
    printf 'kubectl get jobs -n %s\n' "$NAMESPACE"
  } > "$RUN_FILE"
  chmod +x "$RUN_FILE"
}

# A Job's pod template is immutable. Any Job left over from an earlier attempt
# makes `helm upgrade` fail with "field is immutable" — the single most common
# reason "just run it again" does not work today. uninstall.sh already knows the
# canonical list.
clear_stale_jobs() {
  local jobs; jobs="$(kubectl get jobs -n "$NAMESPACE" -o name 2>/dev/null | grep -E 'triliovault-' || true)"
  [[ -z "$jobs" ]] && return 0
  say ""
  say "  Existing Trilio Jobs in $NAMESPACE:"
  printf '%s\n' "$jobs" | sed 's/^/    /' | tee -a "$LOG_FILE"
  say "  A Job's pod template is immutable, so helm upgrade fails on any of these"
  say "  whose spec has changed."
  if [[ $DELETE_JOBS -eq 1 ]] || confirm "Delete them before installing?"; then
    # shellcheck disable=SC2086
    kubectl delete -n "$NAMESPACE" $jobs >>"$LOG_FILE" 2>&1 || true
    step_ok "stale jobs deleted"
  else
    warn "keeping them — helm upgrade may fail with 'field is immutable'"
  fi
}

step_install() {
  # --resume / --only install / --from install all reach here without running
  # step_admin_creds, so the templates must be re-checked at the point of use.
  assert_datamover_injected || return 1

  generate_run_file
  step_ok "generated $RUN_FILE"

  # Render offline first. Two seconds, no cluster contact, and it catches a
  # missing values file, a bad tag or a template error before anything ships.
  #
  # admin_creds.yaml, ceph.yaml and triliovault_passwords.yaml are generated,
  # so under --dry-run (which skips the steps that create them) they may not
  # exist yet. Substitute the committed .example for the render only — it has
  # the right shape with placeholder values, which is all helm template needs.
  local render="$OSH_DIR/.install-render.yaml"
  local args=(); local f substituted=()
  while read -r f; do
    if [[ -f "$VO_DIR/$f" ]]; then
      args+=(--values="$VO_DIR/$f")
    elif [[ -f "$VO_DIR/$f.example" ]]; then
      args+=(--values="$VO_DIR/$f.example"); substituted+=("$f")
    else
      err "missing values file and no .example to stand in for it: $VO_DIR/$f"
      return 1
    fi
  done < <(values_list)
  (( ${#substituted[@]} )) && warn "rendering with .example placeholders for: ${substituted[*]}"
  if ! ( cd "$OSH_DIR" && helm template "$RELEASE" ./trilio-openstack \
           --namespace "$NAMESPACE" "${args[@]}" ) > "$render" 2>>"$LOG_FILE"; then
    err "helm template failed — see $LOG_FILE"
    return 1
  fi
  step_ok "helm template renders ($(wc -l <"$render") lines)"

  # Confirm the tags that will actually deploy, not the ones we think we set.
  local bad; bad="$(grep -oE 'image: "?[^" ]*trilio-[a-z-]+-helm:[^" ]*' "$render" \
                      | grep -v ":${T4OI_IMAGE_TAG}\$" | sort -u || true)"
  # Trilio image tags come from the version file, which is never substituted,
  # so this check stays meaningful even on a placeholder render.
  if [[ -n "$bad" ]]; then
    err "rendered manifests carry unexpected Trilio image tags:"
    printf '%s\n' "$bad" | sed 's/^/    /' >&2
    return 1
  fi
  step_ok "all Trilio images render as :$T4OI_IMAGE_TAG"

  say ""
  say "${BOLD}Install command:${NC}"
  sed 's/^/    /' "$RUN_FILE" | tee -a "$LOG_FILE"
  say ""
  for f in $(values_list); do
    [[ -s "$VO_DIR/$f" ]] && printf '    %-32s %s bytes\n' "$f" "$(wc -c <"$VO_DIR/$f")" \
                          || printf '    %-32s %bMISSING OR EMPTY%b\n' "$f" "$RED" "$NC"
  done | tee -a "$LOG_FILE"
  say ""

  if [[ $DRY_RUN -eq 1 ]]; then
    step_skip "not installing (dry run). Rendered manifests: $render"
    return 0
  fi

  interactive && { confirm "Run it?" || { say "aborted — $RUN_FILE is still there"; exit 2; }; }

  clear_stale_jobs
  bash "$RUN_FILE" 2>&1 | redact | tee -a "$LOG_FILE"
  return "${PIPESTATUS[0]}"
}

step_verify() {
  [[ $DRY_RUN -eq 1 ]] && { step_skip "verify (dry run)"; return 0; }
  say ""
  helm status "$RELEASE" -n "$NAMESPACE" 2>&1 | head -8 | tee -a "$LOG_FILE"
  kubectl get pods -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE"
  kubectl get jobs -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE"
  kubectl get pvc  -n "$NAMESPACE" 2>&1 | tee -a "$LOG_FILE"

  local bad; bad="$(kubectl get pods -n "$NAMESPACE" \
                      --field-selector=status.phase!=Running,status.phase!=Succeeded \
                      -o name 2>/dev/null || true)"
  if [[ -n "$bad" ]]; then
    warn "not all pods are Running/Succeeded:"
    printf '%s\n' "$bad" | sed 's/^/    /' | tee -a "$LOG_FILE"
    return 1
  fi
  step_ok "all pods Running or Completed"
}

# ===========================================================================
# Driver
# ===========================================================================
main() {
  : > "$LOG_FILE"
  banner "Trilio for OpenStack — OpenStack Helm / MOSK installer"
  say "  repo : $OSH_DIR"
  say "  log  : $LOG_FILE"
  [[ $DRY_RUN -eq 1 ]] && say "  ${YELLOW}dry run — the cluster will not be modified${NC}"

  load_answers
  preflight
  detect_and_ask

  banner "Install"
  local s ran=0
  for s in "${STEPS[@]}"; do
    [[ -n "$ONLY_STEP" && "$s" != "$ONLY_STEP" ]] && continue
    if [[ -n "$FROM_STEP" && $ran -eq 0 ]]; then
      [[ "$s" == "$FROM_STEP" ]] && ran=1 || continue
    fi
    if [[ $RESUME -eq 1 ]] && state_done "$s"; then step_skip "$s (already done)"; continue; fi

    say ""
    say "${BOLD}[$s]${NC}"
    if "step_$s"; then
      [[ $DRY_RUN -eq 1 ]] || state_set "$s"
    else
      step_fail "$s"
      say ""
      err "step '$s' failed."
      say "Fix the cause, then resume with:"
      say "    bash ./install_trilio.sh --answers $ANSWERS_OUT --resume"
      say "or re-run just this step with:"
      say "    bash ./install_trilio.sh --answers $ANSWERS_OUT --only $s"
      say ""
      say "Log: $LOG_FILE"
      exit 1
    fi
  done

  banner "Done"
  say "  T4O is installed into namespace ${BOLD}$NAMESPACE${NC}."
  say ""
  say "  Next:"
  say "    1. Add a backup target — see the admin guide."
  say "    2. Fetch the T4O FQDNs: kubectl -n $NAMESPACE get ingress"
  say "    3. Install the Horizon plugin (documented step 14; not automated here)."
  say ""
  say "  Your working tree now has generated, gitignored artefacts under"
  say "  trilio-openstack/. ${BOLD}$VERSION_FILE is tracked${NC} — check before committing."
  say ""
  say "  Log: $LOG_FILE"
}

main "$@"
