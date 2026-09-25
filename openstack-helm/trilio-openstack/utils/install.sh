#!/bin/bash -x

# The four generated templates/bin/*.tpl files are not committed (see
# ../../.gitignore). helm cannot render without them, so materialise any that
# are missing from the committed *.tpl.in stubs. Rendered copies are kept.
"$(dirname "$0")/restore_templates.sh" --if-missing
cd ../../


kubectl create namespace trilio-openstack
kubectl config set-context --current --namespace=trilio-openstack


helm upgrade --install trilio-openstack ./trilio-openstack --namespace=trilio-openstack \
--values=./trilio-openstack/values_overrides/image_pull_secrets.yaml \
--values=./trilio-openstack/values_overrides/keystone.yaml \
--values=./trilio-openstack/values_overrides/2023.2.yaml \
--values=./trilio-openstack/values_overrides/admin_creds.yaml \
--values=./trilio-openstack/values_overrides/tls_public_endpoint.yaml \
--values=./trilio-openstack/values_overrides/ceph.yaml \
--values=./trilio-openstack/values_overrides/db_drop.yaml \
--values=./trilio-openstack/values_overrides/ingress.yaml \
--values=./trilio-openstack/values_overrides/triliovault_passwords.yaml

echo -e "Waiting for trilio-openstack pods to get into running state"

./trilio-openstack/utils/wait_for_pods.sh trilio-openstack

kubectl get pods
