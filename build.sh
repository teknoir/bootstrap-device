#!/bin/sh
#set -e

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -p|--project)
    PROJECT="$2"
    shift # past argument
    shift # past value
    ;;
    -n|--namespace)
    NAMESPACE="$2"
    shift # past argument
    shift # past value
    ;;
    -d|--device)
    DEVICE="$2"
    shift # past argument
    shift # past value
    ;;
    -h|--help|*)
    echo "$0 -p(--project) <project> -n(--namespace) <namespace> -d(--device) <device-name>"
    exit 0
    ;;
esac
done

echo "PROJECT  = ${PROJECT}"
echo "NAMESPACE  = ${NAMESPACE}"
echo "DEVICE     = ${DEVICE}"

DEVICE_DIR="files/${DEVICE}"
mkdir -p "${DEVICE_DIR}"
BOOTSTRAP_FILE="${DEVICE_DIR}/bootstrap.sh"

kubectl -n ${NAMESPACE} get device ${DEVICE} -o yaml | yq eval .spec.keys.data.rsa_private - | base64 --decode --input - > "${DEVICE_DIR}/temp-build.secret"
sed "147r ${DEVICE_DIR}/temp-build.secret" bootstrap_template.sh > ${BOOTSTRAP_FILE}
rm "${DEVICE_DIR}/temp-build.secret" || true

pushd ${DEVICE_DIR}
sed -i '' "s/#GCP_PROJECT#/${PROJECT}/" bootstrap.sh
sed -i '' "s/#IOT_REGISTRY#/${NAMESPACE}/" bootstrap.sh
sed -i '' "s/#DEVICE_ID#/${DEVICE}/" bootstrap.sh
popd
