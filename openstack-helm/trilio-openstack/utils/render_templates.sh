#!/bin/bash -x

# The four generated templates/bin/*.tpl files are not committed (see
# ../../.gitignore). helm cannot render without them, so materialise any that
# are missing from the committed *.tpl.in stubs. Rendered copies are kept.
"$(dirname "$0")/restore_templates.sh" --if-missing
cd ../..
helm template -f trilio-openstack/values_overrides/admin_creds.yaml \
-f trilio-openstack/values_overrides/image_pull_secrets.yaml \
-f trilio-openstack/values_overrides/keystone.yaml \
-f trilio-openstack/values_overrides/ceph.yaml \
-f trilio-openstack/values_overrides/tls_public_endpoint.yaml \
-f trilio-openstack/values_overrides/ingress.yaml \
-f trilio-openstack/values_overrides/victoria-ubuntu_focal.yaml \
-f trilio-openstack/values_overrides/triliovault_passwords.yaml \
-f trilio-openstack/values_overrides/db_drop.yaml \
-f trilio-openstack/values_overrides/admin_creds.yaml \
--debug trilio-openstack > /tmp/trilio-manifest.yaml
