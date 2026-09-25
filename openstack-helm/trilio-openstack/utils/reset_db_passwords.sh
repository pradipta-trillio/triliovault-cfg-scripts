#!/bin/bash
#
# reset_db_passwords.sh — align the MariaDB users' passwords with the ones in
#                         values_overrides/triliovault_passwords.yaml.
#
# WHY THIS EXISTS
#
# helm-toolkit's db-init job runs:
#
#     CREATE USER IF NOT EXISTS 'dmapi'@'%' IDENTIFIED BY '<password>'
#
# and then, as its last act, opens a connection AS that user to verify it
# works. `IF NOT EXISTS` means an already-existing user is left completely
# alone — its old password is NOT updated. So on a cluster where a previous
# T4O install left the `dmapi` / `workloadmgr` MariaDB users behind (a helm
# delete does not drop them), installing with freshly generated passwords gives
# you a db-init job that cannot connect as its own user:
#
#     CRITICAL OpenStack-Helm DB Init Could not connect to database as user
#
# and the pod goes into CrashLoopBackOff.
#
# This script closes that gap with ALTER USER, which is non-destructive: the
# databases and everything in them are untouched, only the passwords change.
#
# Usage:  ./reset_db_passwords.sh [--dry-run]
#         Run from utils/, like every other script here.
#
set -euo pipefail

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_FILE="$HERE/../values_overrides/triliovault_passwords.yaml"
OS_NS="${OS_NAMESPACE:-openstack}"

[[ -f "$PW_FILE" ]] || { echo "ERROR: $PW_FILE not found — run generate_passwords.sh first" >&2; exit 1; }

# Pull the two DB passwords out of the generated file. They sit under
# endpoints.oslo_db_triliovault_{datamover,wlm}.auth.<user>.password, so take
# the password line that follows each section header.
pw_for() {  # pw_for <section>
  awk -v sect="$1:" '
    $1 == sect { found = 1; next }
    found && $1 == "password:" { print $2; exit }
  ' "$PW_FILE"
}
DM_PW="$(pw_for oslo_db_triliovault_datamover)"
WLM_PW="$(pw_for oslo_db_triliovault_wlm)"

[[ -n "$DM_PW" && -n "$WLM_PW" ]] \
  || { echo "ERROR: could not read both DB passwords from $PW_FILE" >&2; exit 1; }

ADMIN_PW="$(kubectl -n "$OS_NS" get secret mariadb-dbadmin-password \
              --template='{{.data.MYSQL_DBADMIN_PASSWORD}}' | base64 -d)"
[[ -n "$ADMIN_PW" ]] || { echo "ERROR: could not read secret/mariadb-dbadmin-password in ns $OS_NS" >&2; exit 1; }

# Find a mariadb server pod. Label sets differ between vanilla OpenStack Helm
# and MOSK, so try the known ones in order.
POD=""
for sel in "application=mariadb,component=server" \
           "app.kubernetes.io/name=mariadb" \
           "app=mariadb-server"; do
  POD="$(kubectl -n "$OS_NS" get pods -l "$sel" \
           --field-selector=status.phase=Running \
           -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [[ -n "$POD" ]] && break
done
[[ -n "$POD" ]] || { echo "ERROR: no running mariadb pod found in ns $OS_NS" >&2; exit 1; }
echo "Using mariadb pod: $POD"

run_sql() {
  kubectl -n "$OS_NS" exec -i "$POD" -- \
    mysql -u root -p"$ADMIN_PW" -N -B -e "$1"
}

changed=0
for pair in "dmapi:$DM_PW" "workloadmgr:$WLM_PW"; do
  user="${pair%%:*}"; pw="${pair#*:}"
  exists="$(run_sql "SELECT COUNT(*) FROM mysql.user WHERE user='${user}' AND host='%';" 2>/dev/null || echo 0)"
  if [[ "$exists" == "0" ]]; then
    echo "  $user: does not exist yet — db-init will create it. Nothing to do."
    continue
  fi
  if [[ $DRY -eq 1 ]]; then
    echo "  $user: exists — WOULD run ALTER USER (dry run)"
    continue
  fi
  run_sql "ALTER USER '${user}'@'%' IDENTIFIED BY '${pw}'; FLUSH PRIVILEGES;"
  echo "  $user: password reset to match triliovault_passwords.yaml"
  changed=$((changed + 1))
done

echo "Done. $changed user(s) updated."
if (( changed > 0 )); then
  echo
  echo "Now delete the failed db-init jobs so helm recreates them:"
  echo "  kubectl -n trilio-openstack delete job triliovault-datamover-db-init triliovault-wlm-db-init --ignore-not-found"
  echo "then re-run the install."
fi
