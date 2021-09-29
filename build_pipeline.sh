#!/bin/bash
set -e

# --- helper functions for logs ---
fatal()
{
    echo '[ERROR] ' "$@" >&2
    exit 1
}

# Check that vars exist
if [ -z ${_GCP_PROJECT+x} ]; then fatal "_GCP_PROJECT is unset"; fi
if [ -z ${_IOT_REGISTRY+x} ]; then fatal "_IOT_REGISTRY is unset"; fi
if [ -z ${_DOMAIN+x} ]; then fatal "_DOMAIN is unset"; fi
if [ -z ${_DEVICE_ID+x} ]; then fatal "_DEVICE_ID is unset"; fi
if [ -z ${_RSA_PRIVATE+x} ]; then fatal "_RSA_PRIVATE is unset"; fi
if [ -z ${_FIRST_USER_NAME+x} ]; then fatal "_FIRST_USER_NAME is unset"; fi
if [ -z ${_FIRST_USER_PASS+x} ]; then fatal "_FIRST_USER_PASS is unset"; fi
if [ -z ${_FIRST_USER_KEY+x} ]; then fatal "_FIRST_USER_KEY is unset"; fi
if [ -z ${_BOOTSTRAP_FILE+x} ]; then fatal "_BOOTSTRAP_FILE is unset"; fi

TEMPLATES_PATH=$(realpath ./templates)
source build_bootstrap_script.sh

build_bootstrap_script ${_BOOTSTRAP_FILE} ${TEMPLATES_PATH}
