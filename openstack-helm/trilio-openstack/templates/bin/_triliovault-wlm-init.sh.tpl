#!/bin/bash

{{/*
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

set -ex

# Service boilerplate description
OS_SERVICE_DESC="${OS_REGION_NAME}: ${OS_SERVICE_NAME} (${OS_SERVICE_TYPE}) service"

# Get Service ID if it exists
unset OS_SERVICE_ID

# If OS_SERVICE_ID is blank then wait a few seconds to give it
# additional time and try again

## INPUT:
# CLOUD_ADMIN_USER_NAME
# CLOUD_ADMIN_PROJECT_NAME
# CLOUD_ADMIN_DOMAIN_NAME


CLOUD_ADMIN_USER_NAME="{{- .Values.conf.triliovault.cloud_admin_user_name -}}"
CLOUD_ADMIN_PROJECT_NAME="{{- .Values.conf.triliovault.cloud_admin_project_name -}}"
CLOUD_ADMIN_DOMAIN_NAME="{{- .Values.conf.triliovault.cloud_admin_domain_name -}}"
WLM_USER_NAME="{{- .Values.endpoints.identity.auth.triliovault_wlm.username -}}"

WLM_PROJECT_DOMAIN_NAME="{{- .Values.endpoints.identity.auth.triliovault_wlm.project_domain_name -}}"

WLM_PROJECT_NAME="{{- .Values.endpoints.identity.auth.triliovault_wlm.project_name -}}"

CLOUD_ADMIN_USER_ID=$(openstack user show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id \
                "${CLOUD_ADMIN_USER_NAME}")

CLOUD_ADMIN_DOMAIN_ID=$(openstack domain show -f value -c id \
                "${CLOUD_ADMIN_DOMAIN_NAME}")

CLOUD_ADMIN_PROJECT_ID=$(openstack project show --domain "${CLOUD_ADMIN_DOMAIN_NAME}" -f value -c id \
                "${CLOUD_ADMIN_PROJECT_NAME}")

WLM_PROJECT_DOMAIN_ID=$(openstack project show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c domain_id \
                "${WLM_PROJECT_NAME}")

WLM_USER_ID=$(openstack user show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c id \
                "${WLM_USER_NAME}")

WLM_USER_DOMAIN_ID=$(openstack user show --domain "${WLM_PROJECT_DOMAIN_NAME}" -f value -c domain_id \
                "${WLM_USER_NAME}")


host_interface=$(ip -4 route list 0/0 | awk -F 'dev' '{ print $2; exit }' | awk '{ print $1 }') || exit 1

POD_IP=$(ip a s $host_interface | grep 'inet ' | awk '{print $2}' | awk -F "/" '{print $1}' | head -1)

# Resolve the node FQDN so WLM host and DMS client node_id match the DMS server's
# queue name (dms.<FQDN>). WLM is not on hostNetwork so hostname -f gives pod hostname.
# Strategy 1: reverse-DNS on HOST_IP (injected via status.hostIP Downward API)
WLM_NODE_FQDN=$(getent hosts "${HOST_IP}" 2>/dev/null | awk '{print $2; exit}')

# Strategy 2: k8s API — query node Hostname/InternalDNS address via service account
if [ -z "${WLM_NODE_FQDN}" ]; then
  K8S_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null)
  K8S_CACERT="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
  if [ -n "${K8S_TOKEN}" ]; then
    WLM_NODE_FQDN=$(curl -s --cacert "${K8S_CACERT}" \
      -H "Authorization: Bearer ${K8S_TOKEN}" \
      "https://kubernetes.default.svc/api/v1/nodes/${NODE_NAME}" 2>/dev/null | \
      python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for a in data.get('status', {}).get('addresses', []):
        if a.get('type') in ('InternalDNS', 'Hostname'):
            print(a['address'])
            break
except Exception:
    pass
" 2>/dev/null)
  fi
fi

# Strategy 3: fall back to short node name (routing will fail if DMS uses FQDN)
if [ -z "${WLM_NODE_FQDN}" ]; then
  echo "[WLM init] WARNING: Could not resolve FQDN for ${NODE_NAME}, falling back to short name"
  WLM_NODE_FQDN="${NODE_NAME}"
fi
echo "[WLM init] Resolved node FQDN: ${WLM_NODE_FQDN} (k8s nodeName was: ${NODE_NAME})"

tee > /tmp/pod-shared-${POD_NAME}/triliovault-wlm-ids.conf << EOF
[DEFAULT]
host = ${WLM_NODE_FQDN}
triliovault_hostnames = ${POD_IP}
cloud_admin_user_id = $CLOUD_ADMIN_USER_ID
cloud_admin_domain = $CLOUD_ADMIN_DOMAIN_ID
cloud_admin_project_id = $CLOUD_ADMIN_PROJECT_ID
cloud_unique_id = $WLM_USER_ID
triliovault_user_domain_id = $WLM_USER_DOMAIN_ID
domain_name = $WLM_PROJECT_DOMAIN_ID

[keystone_authtoken]
project_domain_id = $WLM_PROJECT_DOMAIN_ID
user_domain_id = $WLM_USER_DOMAIN_ID

[dms_client]
node_id = ${WLM_NODE_FQDN}

EOF

chown nova:nova /tmp/pod-shared-${POD_NAME}/triliovault-wlm-ids.conf
mkdir -p /var/log/triliovault/wlm-api /var/log/triliovault/wlm-workloads /var/log/triliovault/wlm-scheduler
chown -R nova:nova /var/log/triliovault/
