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
    -h|--help|*)
    echo "$0 -c(--context) <kubectl-context> -n(--namespace) <namespace> -d(--device) <device-name>"
    exit 0
    ;;
esac
done

export ZONE=us-central1-c
export _GCP_PROJECT=$(if [ "$CONTEXT" == "teknoir-dev" ]; then echo "teknoir-poc"; else echo "teknoir"; fi)
export _DOMAIN=$([ "$_GCP_PROJECT" == 'teknoir' ] && echo "teknoir.cloud" || echo "teknoir.info")
export _IOT_REGISTRY=${NAMESPACE}
export _DEVICE_ID=${DEVICE}

gcloud config set project ${_GCP_PROJECT}
gcloud config set compute/zone ${ZONE}

export DEVICE_MANIFEST="$(kubectl --context $CONTEXT -n $NAMESPACE get device $DEVICE -o yaml)"
export _RSA_PRIVATE="$(echo "$DEVICE_MANIFEST" | yq eval .spec.keys.data.rsa_private - | base64 --decode --input -)"

echo "_GCP_PROJECT   = ${_GCP_PROJECT}"
echo "_DOMAIN        = ${_DOMAIN}"
echo "_IOT_REGISTRY  = ${_IOT_REGISTRY}"
echo "_DEVICE_ID     = ${_DEVICE_ID}"

TEMPLATES_PATH=$(realpath ./templates)
source build_bootstrap_script.sh

TMP=$(mktemp -d -t teknoir-bs-00XXX)
cd $TMP

BOOTSTRAP_FILE="tn.sh"
build_bootstrap_script ${BOOTSTRAP_FILE} ${TEMPLATES_PATH}

BUCKET="${NAMESPACE}.${_DOMAIN}"
gsutil cp ${BOOTSTRAP_FILE} gs://${BUCKET}/downloads/${DEVICE}/${BOOTSTRAP_FILE}
SIGNED_URL=$(gsutil -q -i kubeflow-admin@teknoir.iam.gserviceaccount.com signurl -d 12h -u gs://${BUCKET}/downloads/${DEVICE}/${BOOTSTRAP_FILE})

echo "Drop-in script for device generated and uploaded to secure bucket!"
echo "Run the following command on the device:"
echo "bash <(curl -Ls \"https${SIGNED_URL#*https}\")"

cd ..
rm -rf $TMP




#DEVICE_DIR="files/${DEVICE}"
#mkdir -p "${DEVICE_DIR}"
#BOOTSTRAP_FILE="${DEVICE_DIR}/bootstrap.sh"
#
#kubectl -n ${NAMESPACE} get device ${DEVICE} -o yaml | yq eval .spec.keys.data.rsa_private - | base64 --decode --input - > "${DEVICE_DIR}/temp-build.secret"
#sed "148r ${DEVICE_DIR}/temp-build.secret" bootstrap_template.sh > ${BOOTSTRAP_FILE}
#rm "${DEVICE_DIR}/temp-build.secret" || true
#
#pushd ${DEVICE_DIR}
#sed -i '' "s/#GCP_PROJECT#/${PROJECT}/" bootstrap.sh
#sed -i '' "s/#IOT_REGISTRY#/${NAMESPACE}/" bootstrap.sh
#sed -i '' "s/#DEVICE_ID#/${DEVICE}/" bootstrap.sh
#gsutil cp bootstrap.sh gs://${BUCKET}/downloads/${DEVICE}/bootstrap.sh
#popd
#
#SIGNED_URL=$(gsutil -q -i kubeflow-admin@teknoir.iam.gserviceaccount.com signurl -d 12h -u gs://${BUCKET}/downloads/${DEVICE}/bootstrap.sh)
#
#echo "Drop-in script for device generated and uploaded to secure bucket!"
#echo "Run the following command on the device:"
#echo "bash <(curl -Ls \"https${SIGNED_URL#*https}\")"