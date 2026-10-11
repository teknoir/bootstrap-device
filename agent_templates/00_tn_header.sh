#!/bin/sh
set -e
set -o noglob
#set -x
umask 027

# This is the drop in device k3s agent(worker) bootstrap script for the Teknoir platform.
# It should work for most arm32/arm64/amd64 devices running Debian or Ubuntu.

# Environment variables:
#   K3S_URL=https://<IP or mDNS name>:6443 (default: generated at master node creation time)
#   K3S_TOKEN="32 char string" (default: generated at master node creation time)
#   CREATE_USER=false (default: ask, create a user for the device without asking)
#   INSTALL_K3S_VERSION=v1.xx.y+k3sN (default: TN_K3S_VERSION below; "stable" = whatever the k3s installer
#                          picks as stable today, the old behaviour)
#   TN_K3S_UPGRADE=true (default: false; a re-run KEEPS the k3s version that is installed. true lets
#                          TN_K3S_VERSION replace it: never a downgrade, never more than one minor version)
#   TN_K3S_FORCE=true (default: false; allows an upgrade over more than one minor version)
#   TN_K3S_CGROUPV1=true|false (default: detected; on cgroup v1 with k3s >= v1.35 the kubelet gets
#                          fail-cgroupv1=false, see /etc/rancher/k3s/config.yaml.d/99-teknoir-cgroupv1.yaml)

# The k3s release to install: the stable channel when this was written (https://update.k3s.io/v1-release/channels)
# and the release the CA tests in test/k3s-ca prove. A server and its agents must run the same release.
# This is the release for a NEW device: a device that already has k3s keeps its version (TN_K3S_UPGRADE=true
# replaces it; a downgrade is always refused).
TN_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.36.5+k3s1}"

# --- helper functions ---
info() { echo '[INFO] ' "$@"; }
warn() { echo '[WARN] ' "$@" >&2; }
fatal() { echo '[ERROR] ' "$@" >&2; exit 1; }

# Exit if not running as root
[ $(id -u) -eq 0 ] || fatal 'You must run this script as root'

DOWNLOADER=
# --- download ---
download() {
    [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'

    case $DOWNLOADER in
        curl)
            if [ ${OS_BUILD} ] || [ ${INSECURE} ]; then
                info "Running installation without verifying ssl certs on URLs"
                $SUDO curl --insecure -o $1 -sSfL $2
            else
                $SUDO curl -o $1 -sSfL $2
            fi
            ;;
        wget)
            $SUDO wget -qO $1 $2
            ;;
        *)
            fatal "Incorrect executable '$DOWNLOADER'"
            ;;
    esac

    # Abort if download command failed
    [ $? -eq 0 ] || fatal 'Download failed'
}

# --- verify existence of network downloader executable ---
verify_downloader() {
    # Return failure if it doesn't exist or is no executable
    [ -x "$(command -v $1)" ] || return 1

    # Set verified executable as our downloader program and return success
    DOWNLOADER=$1
    return 0
}

verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'
