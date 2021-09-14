#!/bin/bash
set -e

# --- verify existence of network downloader executable ---
build_bootstrap_script() {
  BOOTSTRAP_FILE=$1
  TEMPLATES_PATH=$2
  echo "Writing bootstrap script to ${BOOTSTRAP_FILE} using path ${TEMPLATES_PATH}"
  cat ${TEMPLATES_PATH}/00_tn_header.sh > ${BOOTSTRAP_FILE}
  cat ${TEMPLATES_PATH}/01_tn_fn.sh >> ${BOOTSTRAP_FILE}
  cat ${TEMPLATES_PATH}/02_tn_pre_key.sh >> ${BOOTSTRAP_FILE}
  echo "${_RSA_PRIVATE}" >> ${BOOTSTRAP_FILE}
  cat ${TEMPLATES_PATH}/03_tn_pre_manifest.sh >> ${BOOTSTRAP_FILE}
  cat ${TEMPLATES_PATH}/teknoir_mqtt_manifests.yaml >> ${BOOTSTRAP_FILE}
  eval "echo \"$(cat ${TEMPLATES_PATH}/teknoir_manifests.yaml)\"" >> ${BOOTSTRAP_FILE}
  cat ${TEMPLATES_PATH}/04_tn_pre_calico.sh >> ${BOOTSTRAP_FILE}
  cat ${TEMPLATES_PATH}/calico_manifests.yaml >> ${BOOTSTRAP_FILE}
  cat ${TEMPLATES_PATH}/05_tn_cleanup.sh >> ${BOOTSTRAP_FILE}
}
