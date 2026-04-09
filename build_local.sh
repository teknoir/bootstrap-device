#!/bin/bash
set -e

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -c|--context)
    export CONTEXT="$2"
    shift # past argument
    shift # past value
    ;;
    -n|--namespace)
    export NAMESPACE="$2"
    shift # past argument
    shift # past value
    ;;
    -d|--device)
    export DEVICE="$2"
    shift # past argument
    shift # past value
    ;;
    -s|--skip-upload)
    export SKIP_UPLOAD=1
    shift # past argument
    ;;
    -h|--help|*)
    echo "$0 -c(--context) <kubectl-context> -n(--namespace) <namespace> -d(--device) <device-name>"
    exit 0
    ;;
esac
done

#export ZONE=us-central1-c
export _GCP_PROJECT="teknoir"
case "${CONTEXT}" in
  *teknoir-dev*|*teknoir-poc*)
    _DOMAIN="teknoir.dev"
    ;;
  *rtx2000-pro-bw-se.teknoir*)
    _DOMAIN="teknoir.online"
    ;;
  *r415*)
    _DOMAIN="teknoir.cloud"
    ;;
esac
export _IOT_REGISTRY=${NAMESPACE}
export _DEVICE_ID=${DEVICE}

#gcloud config set project ${_GCP_PROJECT}
#gcloud config set compute/zone ${ZONE}

export DEVICE_MANIFEST="$(kubectl --context $CONTEXT -n $NAMESPACE get device.teknoir.org $DEVICE -o yaml)"
if [ -z ${DEVICE_MANIFEST+x} ] || [ "${DEVICE_MANIFEST}" = "" ]; then
  echo "DEVICE_MANIFEST not found, trying device.kubeflow.org"
  export DEVICE_MANIFEST="$(kubectl --context $CONTEXT -n $NAMESPACE get device $DEVICE -o yaml)"
  if [ -z ${DEVICE_MANIFEST+x} ] || [ "${DEVICE_MANIFEST}" = "" ]; then
    echo "DEVICE_MANIFEST not found"
    exit 1
  fi
fi
export _RSA_PRIVATE="$(echo "$DEVICE_MANIFEST" | yq eval .spec.keys.data.rsa_private - | base64 -d)"
export _RSA_PUBLIC="$(echo "$DEVICE_MANIFEST" | yq eval .spec.keys.data.rsa_public - | base64 -d)"
export _FIRST_USER_NAME="$(echo "$DEVICE_MANIFEST" | yq eval .spec.keys.data.username - | base64 -d)"
export _FIRST_USER_PASS="$(echo "$DEVICE_MANIFEST" | yq eval .spec.keys.data.userpassword - | base64 -d)"
export _FIRST_USER_KEY="$(echo "$DEVICE_MANIFEST" | yq eval .spec.keys.data.publicsshkey - | base64 -d)"

export AR_SECRET="$(kubectl --context $CONTEXT -n $NAMESPACE get secret artifact-registry-secret -o yaml)"
export _AR_DOCKER_SECRET="$(echo "${AR_SECRET}" | yq eval '.data[".dockerconfigjson"]' -)"

export _BOOTSTRAP_AGENT_FILE="bootstrap_agent_${_DEVICE_ID}.sh"
export _BOOTSTRAP_FILE="bootstrap_${_DEVICE_ID}.sh"
export _K3S_TOKEN=$(openssl rand -hex 32) # Get this from device spec!

echo "_GCP_PROJECT   = ${_GCP_PROJECT}"
echo "_DOMAIN        = ${_DOMAIN}"
echo "_IOT_REGISTRY  = ${_IOT_REGISTRY}"
echo "_DEVICE_ID     = ${_DEVICE_ID}"
echo "_K3S_TOKEN     = ${_K3S_TOKEN}"
echo "_BOOTSTRAP_FILE= ${_BOOTSTRAP_FILE}"

source build_bootstrap_script.sh

build_bootstrap_script ${_BOOTSTRAP_AGENT_FILE} $(realpath ./agent_templates)
build_bootstrap_script ${_BOOTSTRAP_FILE} $(realpath ./templates)

if [ -n "${SKIP_UPLOAD}" ]; then
  echo "Skipping upload of drop-in script to secure bucket"
  exit 0
fi

#BUCKET="${NAMESPACE}.${_DOMAIN}"
#gsutil cp ${_BOOTSTRAP_AGENT_FILE} gs://${BUCKET}/downloads/${DEVICE}/${_BOOTSTRAP_AGENT_FILE}
#gsutil cp ${_BOOTSTRAP_FILE} gs://${BUCKET}/downloads/${DEVICE}/${_BOOTSTRAP_FILE}
#SIGNED_URL=$(gsutil -q -i kubeflow-admin@${_GCP_PROJECT}.iam.gserviceaccount.com signurl -d 12h -u gs://${BUCKET}/downloads/${DEVICE}/${BOOTSTRAP_FILE})

echo "Drop-in script for device generated here: ${_BOOTSTRAP_FILE}"
echo "Drop in agent script to connect a k3s not as a cluster here: ${_BOOTSTRAP_AGENT_FILE}"
#echo "Run the following command on the device:"
#echo "bash <(curl -LsS \"https${SIGNED_URL#*https}\")"
