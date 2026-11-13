#!/bin/bash
# collect_backup_targets.sh
#
# Reads the backup target configuration of a T4O 5.2.x or 6.0/6.1.x RHOSP 17.1
# deployment from its trilio_env.yaml and saves it to
# existing_backup_targets.yaml BEFORE upgrading to T4O 6.3.
#
# From T4O 6.2 backup targets are no longer Heat parameters: they are records
# in the workloadmgr database, mounted on demand by the Trilio DMS service, and
# S3 credentials live in Barbican. The 6.3 trilio_env.yaml no longer carries
# them, so capture them first. update_backup_targets.sh consumes the output.
#
#   5.2 format  (TrilioBackupTargetType / NfsShares / S3*): one target, which
#               does not exist in the 5.2 database -> action: create
#   6.x format  (TrilioBackupTargets list): every target already exists in the
#               database (created from enabled_backends)
#                 S3  -> action: add_secret_ref  (credentials move to Barbican)
#                 NFS -> action: none            (record is unchanged)
#
# Run on the undercloud. Never prompts.
#
# Usage:
#   bash collect_backup_targets.sh -e <old trilio_env.yaml>
#        [-n <old trilio_nfs_map.yaml>]   5.2 multi-IP NFS map
#        [-c <cert dir>]                  dir holding the old s3-cert*.pem files
#                                         (usually <old checkout>/redhat-director-scripts/rhosp17/puppet/trilio/files)
#        [-o existing_backup_targets.yaml]
#
# The output contains S3 access/secret keys and is written mode 0600.

set -e

ENV_FILE=""
NFS_MAP_FILE=""
CERT_DIR=""
OUTPUT="existing_backup_targets.yaml"

log()      { echo "[$(date '+%H:%M:%S')] $*"; }
log_step() { echo; echo "================================================================"; echo "[$(date '+%H:%M:%S')] $*"; echo "================================================================"; }
die()      { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)       ENV_FILE="$2";     shift 2 ;;
    -n|--nfs-map)   NFS_MAP_FILE="$2"; shift 2 ;;
    -c|--cert-dir)  CERT_DIR="$2";     shift 2 ;;
    -o|--output)    OUTPUT="$2";       shift 2 ;;
    *) die "Unknown argument: $1. Valid options: -e <trilio_env.yaml> [-n <trilio_nfs_map.yaml>] [-c <cert dir>] [-o <output.yaml>]" ;;
  esac
done

[ -n "$ENV_FILE" ] || die "-e <old trilio_env.yaml> is required."
[ -f "$ENV_FILE" ] || die "trilio_env.yaml not found: $ENV_FILE"
[ -z "$NFS_MAP_FILE" ] || [ -f "$NFS_MAP_FILE" ] || die "NFS map file not found: $NFS_MAP_FILE"
[ -z "$CERT_DIR" ] || [ -d "$CERT_DIR" ] || die "Cert directory not found: $CERT_DIR"
python3 -c "import yaml" 2>/dev/null || die "python3 PyYAML not available."

export _ENV_FILE="$ENV_FILE" _NFS_MAP_FILE="$NFS_MAP_FILE" _CERT_DIR="$CERT_DIR" _OUTPUT="$OUTPUT"

log_step "Reading backup target config from $ENV_FILE"

umask 077
python3 - <<'PYEOF'
import os, sys, yaml
from datetime import datetime, timezone

env_path, nfs_map_path = os.environ['_ENV_FILE'], os.environ['_NFS_MAP_FILE']
cert_dir, out_path = os.environ['_CERT_DIR'], os.environ['_OUTPUT']

with open(env_path) as f:
    pd = (yaml.safe_load(f) or {}).get('parameter_defaults', {}) or {}

warnings = []

def as_bool(v):
    return str(v).strip().lower() in ('true', 'yes', '1', 'y')

def cert_pem(name):
    # Embedded as text: update_backup_targets.sh runs on a controller, where
    # the undercloud's cert files are not available.
    if not cert_dir:
        return ''
    p = os.path.join(cert_dir, name)
    if not os.path.isfile(p):
        warnings.append("expected CA cert %s not found" % p)
        return ''
    with open(p) as f:
        return f.read()

targets = []

if pd.get('TrilioBackupTargets'):
    fmt = '6.x'
    for t in pd['TrilioBackupTargets']:
        name, bt_type = t.get('backup_target_name', ''), str(t.get('backup_target_type', '')).lower()
        entry = {'name': name, 'type': bt_type, 'is_default': as_bool(t.get('is_default', False))}
        if bt_type == 's3':
            entry.update({
                'action': 'add_secret_ref',
                's3_type': t.get('s3_type', ''),
                's3_access_key': t.get('s3_access_key', ''),
                's3_secret_key': t.get('s3_secret_key', ''),
                's3_bucket': t.get('s3_bucket', ''),
                's3_region': t.get('s3_region_name', ''),
                's3_endpoint_url': t.get('s3_endpoint_url', ''),
                's3_signature_version': t.get('s3_signature_version', 'default'),
                's3_auth_version': t.get('s3_auth_version', 'DEFAULT'),
                's3_ssl_enabled': as_bool(t.get('s3_ssl_enabled', False)),
                's3_ssl_verify': as_bool(t.get('s3_ssl_verify', True)),
                's3_object_lock': as_bool(t.get('s3_bucket_object_lock_enabled', False)),
                's3_ssl_cert': cert_pem('s3-cert-%s.pem' % name)
                    if as_bool(t.get('s3_self_signed_cert', t.get('s3_self_signed_certs', False))) else '',
            })
        elif bt_type == 'nfs':
            entry.update({
                'action': 'none',
                'nfs_export': t.get('nfs_shares', ''),
                'nfs_options': t.get('nfs_options', ''),
                'multi_ip_nfs': as_bool(t.get('is_multi_ip_nfs', False)),
            })
            if entry['multi_ip_nfs']:
                entry['multi_ip_nfs_map'] = t.get('multi_ip_nfs_map', {})
        else:
            warnings.append("target '%s': unknown backup_target_type '%s', skipped" % (name, bt_type))
            continue
        targets.append(entry)

elif pd.get('TrilioBackupTargetType'):
    fmt = '5.2'
    bt_type = str(pd['TrilioBackupTargetType']).lower()
    if bt_type == 'nfs':
        entry = {
            'name': 'nfs-backup-target-1', 'type': 'nfs', 'action': 'create', 'is_default': True,
            'nfs_export': pd.get('NfsShares', ''),
            'nfs_options': pd.get('NfsOptions', ''),
            'multi_ip_nfs': as_bool(pd.get('MultiIPNfsEnabled', False)),
        }
        if entry['multi_ip_nfs']:
            nfs_map = {}
            if nfs_map_path:
                with open(nfs_map_path) as f:
                    nfs_map = ((yaml.safe_load(f) or {}).get('parameter_defaults', {}) or {}).get('TriliovaultMultiIPNfsMap', {})
            else:
                warnings.append("MultiIPNfsEnabled is True but no -n <trilio_nfs_map.yaml> was given")
            entry['multi_ip_nfs_map'] = nfs_map
    elif bt_type == 's3':
        s3_type = pd.get('S3Type', '')
        ssl = as_bool(pd.get('S3SslEnabled', False))
        entry = {
            'name': 's3-backup-target-1', 'type': 's3', 'action': 'create', 'is_default': True,
            's3_type': s3_type,
            's3_access_key': pd.get('S3AccessKey', ''),
            's3_secret_key': pd.get('S3SecretKey', ''),
            's3_bucket': pd.get('S3Bucket', ''),
            's3_region': pd.get('S3RegionName', ''),
            's3_endpoint_url': pd.get('S3EndpointUrl', ''),
            's3_signature_version': pd.get('S3SignatureVersion', 'default'),
            's3_auth_version': pd.get('S3AuthVersion', 'DEFAULT'),
            's3_ssl_enabled': ssl,
            's3_ssl_verify': as_bool(pd.get('S3SslVerify', True)),
            's3_object_lock': False,
            # 5.2 shipped a single puppet/trilio/files/s3-cert.pem for non-AWS S3 over SSL
            's3_ssl_cert': cert_pem('s3-cert.pem') if ssl and s3_type != 'amazon_s3' else '',
        }
    else:
        sys.exit("ERROR: unknown TrilioBackupTargetType '%s' in %s" % (bt_type, env_path))
    targets.append(entry)

else:
    sys.exit("ERROR: neither TrilioBackupTargets (6.x) nor TrilioBackupTargetType (5.2) found in " + env_path)

for t in targets:
    if t.get('multi_ip_nfs'):
        warnings.append("target '%s' is multi-IP NFS: confirm T4O 6.3 support before migrating it; "
                        "update_backup_targets.sh leaves it for manual handling" % t['name'])

print("  Source format      : " + fmt)
for t in targets:
    where = t.get('nfs_export') or t.get('s3_bucket', '')
    print("  %-20s %-4s %-15s %s" % (t['name'], t['type'], t['action'], where))
for w in warnings:
    print("  WARNING: " + w)

output = {
    '_collected_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    '_source_env': os.path.abspath(env_path),
    '_source_format': fmt,
    'backup_targets': targets,
}
with open(out_path, 'w') as f:
    f.write("# T4O backup targets collected before upgrading RHOSP 17.1 to T4O 6.3.\n")
    f.write("# Contains S3 credentials - keep it private and delete it after the migration.\n")
    yaml.safe_dump(output, f, default_flow_style=False, sort_keys=False)
os.chmod(out_path, 0o600)
print("  Written: " + out_path)
PYEOF

log ""
log "Done. Review $OUTPUT before upgrading. It holds S3 credentials (mode 0600)."
log ""
log "Next steps:"
log "  1. Stop T4O services and run cleanup_backup_targets.yml from the undercloud"
log "  2. Upgrade (overcloud deploy with the 6.3 templates, TrilioDms added to roles_data)"
log "  3. Copy $OUTPUT to a controller and run update_backup_targets.sh there"
