#!/bin/bash -x

set -e

if [ $# -lt 2 ]; then
   echo "Script takes 2 or 3 arguments"
   echo -e "./create_image_pull_secret.sh <TRILIO_REGISTRY_USERNAME> <TRILIO_REGISTRY_PASSWORD> [REGISTRY_SERVER]"
   echo -e "REGISTRY_SERVER defaults to docker.io. Set it when the Trilio images"
   echo -e "come from a mirror, e.g. harbor.corp:5000 — the secret only applies"
   echo -e "to the server it names."
   exit 1
fi

TRILIO_REGISTRY_USERNAME=$1
TRILIO_REGISTRY_PASSWORD=$2
TRILIO_REGISTRY_SERVER=${3:-docker.io}

# Namespaces to apply the secret in
NAMESPACES=("trilio-openstack" "openstack")

for NS in "${NAMESPACES[@]}"; do
  echo "Creating secret in namespace: $NS"
  kubectl create secret docker-registry triliovault-image-registry \
     --docker-server="${TRILIO_REGISTRY_SERVER}" \
     --docker-username="${TRILIO_REGISTRY_USERNAME}" \
     --docker-password="${TRILIO_REGISTRY_PASSWORD}" \
     -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
done
kubectl describe secret triliovault-image-registry -n trilio-openstack

echo "Trilio image pull secret created in both 'trilio-openstack' and 'openstack' namespaces."
