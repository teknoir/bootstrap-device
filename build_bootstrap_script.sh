#!/bin/bash
set -e
shopt -s nullglob

build_bootstrap_script() {
  BOOTSTRAP_FILE=$1
  TEMPLATES_PATH=$2
  echo "Writing bootstrap script to ${BOOTSTRAP_FILE} using path ${TEMPLATES_PATH}"

	for i in {0..9}{0..9}; do
	  for file in ${TEMPLATES_PATH}/${i}*.sh; do
	    cat ${file} >> ${BOOTSTRAP_FILE}
	  done
	  for file in ${TEMPLATES_PATH}/${i}*.yaml; do
      cat ${file} >> ${BOOTSTRAP_FILE}
    done
    for file in ${TEMPLATES_PATH}/${i}*.template; do
      eval "echo \"$(cat ${file})\"" >> ${BOOTSTRAP_FILE}
    done
	done
}
