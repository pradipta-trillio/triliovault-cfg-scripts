#!/bin/bash
# update_backup_targets.sh
#
# Brings the backup targets of an upgraded RHOSP 17.1 cloud into the T4O 6.3
# model, from the existing_backup_targets.yaml that collect_backup_targets.sh
# wrote before the upgrade:
#
#   action: create          (5.2 source - the target is not in the database yet)
#     NFS: workloadmgr backup-target-create with the exact old export, so the
#          mount path (base64 of the export path) and every existing snapshot
#          stay where they were.
#     S3:  trilio-dms-cli secret payload -> Barbican -> backup-target-create.
#   action: add_secret_ref  (6.x S3 - the record exists, its keys move to Barbican)
#          trilio-dms-cli secret payload -> Barbican -> backup-target-modify.
#   action: none            (6.x NFS - nothing to do)
#
# Re-runnable: targets that already exist, or already carry a secret_ref, are skipped.
# Multi-IP NFS targets are reported and left for manual handling.
#
# Run as root on ONE controller, after the 6.3 overcloud deploy. Never prompts.
#
# Usage:
#   sudo bash update_backup_targets.sh -f existing_backup_targets.yaml
#
# Environment (all optional):
#   BARBICAN_INTERFACE  Keystone interface used to build the secret href that is
#                       stored in the backup target (default: public). Every
#                       controller and compute must be able to reach it; use
#                       'internal' when computes cannot reach the public VIP.
#   WLM_CONTAINER       WLM API container name (default: triliovault_wlm_api)
#   CONTAINER_CLI       podman | docker (default: podman)
#   DRY_RUN=1           Print what would be done; change nothing.
#   OS_INSECURE=1       Do not verify TLS when talking to Keystone/Barbican.

set -e

INVENTORY=""
BARBICAN_INTERFACE="${BARBICAN_INTERFACE:-public}"
WLM_CONTAINER="${WLM_CONTAINER:-triliovault_wlm_api}"
CONTAINER_CLI="${CONTAINER_CLI:-podman}"
DRY_RUN="${DRY_RUN:-0}"
OS_INSECURE="${OS_INSECURE:-0}"
CTR_INVENTORY=/tmp/t4o_existing_backup_targets.yaml

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) INVENTORY="$2"; shift 2 ;;
    *) die "Unknown argument: $1. Usage: $0 -f existing_backup_targets.yaml" ;;
  esac
done

[ -n "$INVENTORY" ] || die "-f <existing_backup_targets.yaml> is required."
[ -f "$INVENTORY" ] || die "File not found: $INVENTORY"
[ "$(id -u)" = "0" ] || die "Run as root (sudo): the WLM container is managed by root's $CONTAINER_CLI."
case "$BARBICAN_INTERFACE" in public|internal|admin) ;; *) die "BARBICAN_INTERFACE must be public, internal or admin." ;; esac
$CONTAINER_CLI container inspect "$WLM_CONTAINER" >/dev/null 2>&1 \
  || die "Container '$WLM_CONTAINER' not found. Run this on a controller after the 6.3 deploy."

cleanup() {
  $CONTAINER_CLI exec -u root "$WLM_CONTAINER" bash -c "rm -f $CTR_INVENTORY /tmp/t4o_bt_*" >/dev/null 2>&1 || true
}
trap cleanup EXIT

$CONTAINER_CLI cp "$INVENTORY" "$WLM_CONTAINER:$CTR_INVENTORY"
log "Barbican interface for secret hrefs: $BARBICAN_INTERFACE   dry run: $DRY_RUN"

# The program runs inside the WLM container, which carries workloadmgr,
# trilio-dms-cli, PyYAML and requests; cloud_admin_rc supplies the OS_* vars.
$CONTAINER_CLI exec -i -u root "$WLM_CONTAINER" bash -c \
  "source /etc/triliovault-wlm/cloud_admin_rc && python3 - '$CTR_INVENTORY' '$BARBICAN_INTERFACE' '$DRY_RUN' '$OS_INSECURE'" <<'PYEOF'
import json, os, re, subprocess, sys, warnings
from urllib.parse import urlparse
import requests, yaml

inv_path, interface, dry_run, insecure = sys.argv[1], sys.argv[2], sys.argv[3] == '1', sys.argv[4] == '1'
warnings.filterwarnings('ignore')
CA_BUNDLE = '/etc/pki/tls/certs/ca-bundle.crt'
VERIFY = False if insecure else (CA_BUNDLE if os.path.isfile(CA_BUNDLE) else True)

def log(msg):
    print(msg, flush=True)

def run(cmd, env_extra=None, mutating=False):
    if mutating and dry_run:
        log('    DRY RUN: ' + ' '.join(cmd))
        return 0, '', ''
    env = dict(os.environ)
    env.update(env_extra or {})
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, env=env)
    return p.returncode, p.stdout, p.stderr

def backup_targets():
    rc, out, err = run(['workloadmgr', 'backup-target-list', '-f', 'json'])
    if rc != 0:
        sys.exit('ERROR: workloadmgr backup-target-list failed: ' + err.strip())
    return json.loads(out or '[]')

def find_target(bts, bt_type, export=None, bucket=None):
    for bt in bts:
        if str(bt.get('Type', '')).lower() != bt_type:
            continue
        ep = str(bt.get('Backend Endpoint', ''))
        # NFS endpoints are host:/path - never split them on '/' (TVAULT-7419).
        if bt_type == 'nfs' and ep == export:
            return bt
        if bt_type == 's3' and (ep == bucket or ep.split('/')[-1] == bucket):
            return bt
    return None

def secret_ref_of(bt_id):
    rc, out, _ = run(['workloadmgr', 'backup-target-show', bt_id, '-f', 'json'])
    if rc != 0:
        return ''
    data = json.loads(out or '{}')
    if isinstance(data, list):
        return next((str(d.get('Value') or '') for d in data if d.get('Field') == 'secret_ref'), '')
    return str(data.get('secret_ref') or '')

_dms_help = None
def dms_supports(flag):
    global _dms_help
    if _dms_help is None:
        _dms_help = ''.join(run(['trilio-dms-cli', 'secret-payload', 'create', '--help'])[1:])
    return flag in _dms_help

def build_payload(t, fs_export, out_file):
    cmd = ['trilio-dms-cli', 'secret-payload', 'create',
           '--bucket', t['s3_bucket'], '--filesystem-export', fs_export, '-o', out_file]
    if t.get('s3_endpoint_url'):
        cmd += ['--endpoint-url', t['s3_endpoint_url']]
    for flag, key in (('--region', 's3_region'), ('--auth-version', 's3_auth_version'),
                      ('--signature-version', 's3_signature_version')):
        if t.get(key) and dms_supports(flag):
            cmd += [flag, str(t[key])]
    # AWS is HTTPS-only; the old s3_ssl_enabled flag only described other S3 stores.
    cmd += ['--ssl'] if (t.get('s3_ssl_enabled') or t.get('s3_type') == 'amazon_s3') else ['--no-ssl']
    if t.get('s3_ssl_verify'):
        cmd += ['--ssl-verify']
        if t.get('s3_ssl_cert'):
            cert = '/tmp/t4o_bt_%s.pem' % t['name']
            with open(cert, 'w') as f:
                f.write(t['s3_ssl_cert'])
            cmd += ['--ssl-cert', cert]
    else:
        cmd += ['--no-ssl-verify']
    # Keys go through the environment, not argv.
    keys = {'VAULT_S3_ACCESS_KEY_ID': str(t.get('s3_access_key', '')),
            'VAULT_S3_SECRET_ACCESS_KEY': str(t.get('s3_secret_key', ''))}
    if dry_run:
        log('    DRY RUN: ' + ' '.join(cmd))
        return True
    rc, _, err = run(cmd, keys)
    if rc != 0:
        log('    trilio-dms-cli secret-payload create failed: ' + err.strip())
        return False
    rc, _, err = run(['trilio-dms-cli', 'secret-payload', 'validate', out_file])
    if rc != 0:
        log('    trilio-dms-cli secret-payload validate failed: ' + err.strip())
        return False
    return True

def keystone():
    url = os.environ['OS_AUTH_URL'].rstrip('/')
    if not url.endswith('/v3'):
        url += '/v3'
    body = {'auth': {
        'identity': {'methods': ['password'], 'password': {'user': {
            'name': os.environ['OS_USERNAME'],
            'domain': {'name': os.environ['OS_USER_DOMAIN_NAME']},
            'password': os.environ['OS_PASSWORD']}}},
        'scope': {'project': {'name': os.environ['OS_PROJECT_NAME'],
                              'domain': {'name': os.environ['OS_PROJECT_DOMAIN_NAME']}}}}}
    r = requests.post(url + '/auth/tokens', json=body, verify=VERIFY)
    r.raise_for_status()
    return r.headers['X-Subject-Token'], r.json()['token']['catalog']

def barbican_url(catalog, iface):
    for svc in catalog:
        if svc.get('type') == 'key-manager':
            for ep in svc.get('endpoints', []):
                if ep.get('interface') == iface:
                    url = ep['url'].rstrip('/')
                    return url[:-3] if url.endswith('/v1') else url
    return ''

def store_secret(name, payload_file):
    """Stores the payload in Barbican, returns the href on the chosen interface."""
    if dry_run:
        log('    DRY RUN: store %s in Barbican' % name)
        return 'https://barbican.dry-run/v1/secrets/00000000-0000-0000-0000-000000000000'
    token, catalog = keystone()
    base = barbican_url(catalog, interface)
    if not base:
        log('    no %s key-manager endpoint in the Keystone catalog - is Barbican deployed?' % interface)
        return ''
    with open(payload_file) as f:
        payload = f.read().strip()
    r = requests.post(base + '/v1/secrets', verify=VERIFY,
                      headers={'X-Auth-Token': token, 'Content-Type': 'application/json'},
                      json={'name': name, 'payload': payload,
                            'payload_content_type': 'text/plain',  # not application/json
                            'secret_type': 'opaque'})
    if r.status_code >= 300:
        log('    Barbican returned %s: %s' % (r.status_code, r.text.strip()))
        return ''
    # Barbican builds the returned href from its own host_href; keep only the
    # UUID and rebuild it on the interface every DMS node can reach.
    m = re.search(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', r.json().get('secret_ref', ''))
    return '%s/v1/secrets/%s' % (base, m.group(0)) if m else ''

def s3_filesystem_export(t):
    # Same derivation as WLM's own mount path: endpoint netloc/bucket, or the bucket for AWS.
    if t.get('s3_endpoint_url') and t.get('s3_type') != 'amazon_s3':
        return '%s/%s' % (urlparse(t['s3_endpoint_url']).netloc, t['s3_bucket'])
    return t['s3_bucket']

def handle(t, bts):
    name, bt_type, action = t.get('name'), t.get('type'), t.get('action')
    log('')
    log('--- %s  type=%s  action=%s' % (name, bt_type, action))
    if action == 'none':
        log('    NFS record is unchanged in 6.3. Nothing to do.')
        return 'skip'
    if t.get('multi_ip_nfs'):
        log('    Multi-IP NFS target: not migrated automatically. Handle it manually.')
        return 'manual'

    if bt_type == 'nfs' and action == 'create':
        existing = find_target(bts, 'nfs', export=t['nfs_export'])
        if existing:
            log('    Already exists (id=%s). Skipping.' % existing.get('ID'))
            return 'skip'
        cmd = ['workloadmgr', 'backup-target-create', '--btt-name', name, '--type', 'nfs',
               '--filesystem-export', t['nfs_export'],
               '--nfs-mount-opts', t.get('nfs_options') or 'nolock,soft,timeo=180,intr,lookupcache=none']
        if t.get('is_default'):
            cmd.append('--default')
        rc, out, err = run(cmd, mutating=True)
        if rc != 0:
            log('    backup-target-create failed: ' + (err or out).strip())
            return 'fail'
        log('    Created.')
        return 'ok'

    if bt_type != 's3' or action not in ('create', 'add_secret_ref'):
        log('    Unsupported type/action. Skipping.')
        return 'fail'
    if not t.get('s3_bucket') or not t.get('s3_access_key') or not t.get('s3_secret_key'):
        log('    Bucket or S3 credentials missing in the inventory. Re-run collect_backup_targets.sh.')
        return 'fail'

    existing = find_target(bts, 's3', bucket=t['s3_bucket'])
    if action == 'create' and existing:
        log('    Already exists (id=%s). Skipping.' % existing.get('ID'))
        return 'skip'
    if action == 'add_secret_ref':
        if not existing:
            log("    No S3 backup target with bucket '%s' in workloadmgr. Skipping." % t['s3_bucket'])
            return 'fail'
        if secret_ref_of(existing['ID']):
            log('    Already has a secret_ref (id=%s). Skipping.' % existing['ID'])
            return 'skip'
        fs_export = str(existing.get('Backend Endpoint'))
    else:
        fs_export = s3_filesystem_export(t)

    payload_file = '/tmp/t4o_bt_%s.json' % name
    if not build_payload(t, fs_export, payload_file):
        return 'fail'
    href = store_secret('secret-key-%s' % name, payload_file)
    if not href:
        return 'fail'
    log('    Barbican secret: ' + href)

    if action == 'create':
        cmd = ['workloadmgr', 'backup-target-create', '--btt-name', name, '--type', 's3',
               '--s3-bucket', t['s3_bucket'], '--secret-ref', href]
        if t.get('s3_endpoint_url'):
            cmd += ['--s3-endpoint-url', t['s3_endpoint_url']]
        if t.get('is_default'):
            cmd.append('--default')
    else:
        cmd = ['workloadmgr', 'backup-target-modify', '--secret-ref', href, existing['ID']]
    rc, out, err = run(cmd, mutating=True)
    if rc != 0:
        log('    %s failed: %s' % (cmd[1], (err or out).strip()))
        return 'fail'
    log('    Done.')
    return 'ok'

inv = yaml.safe_load(open(inv_path)) or {}
targets = inv.get('backup_targets', [])
log('Inventory: %d target(s), collected %s from a %s deployment'
    % (len(targets), inv.get('_collected_at', '?'), inv.get('_source_format', '?')))
bts = backup_targets()
log('workloadmgr currently reports %d backup target(s).' % len(bts))

results = {}
for t in targets:
    r = handle(t, bts)
    results[r] = results.get(r, 0) + 1
    if r == 'ok' and not dry_run:
        bts = backup_targets()

log('')
log('Summary: ' + ', '.join('%s=%d' % kv for kv in sorted(results.items())))
rc, out, _ = run(['workloadmgr', 'backup-target-list'])
log(out)
sys.exit(1 if results.get('fail') else 0)
PYEOF

log "Next: if no cloud admin trust exists yet, create it now that a target exists:"
log "  podman exec triliovault_wlm_api /opt/triliovault/create_wlm_cloud_trust.sh"
log "Then delete $INVENTORY - it holds S3 credentials."
