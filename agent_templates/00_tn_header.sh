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
#   INSTALL_K3S_VERSION=v1.xx.y+k3sN (default: the k3s release of the SERVER, read from
#                          https://<K3S_URL>/static/teknoir/k3s-version, which the server script publishes; an
#                          agent never installs a k3s newer than its server. A release you ask for here is
#                          installed if it is not newer than the server's, and refused if it is. If the
#                          release of the server cannot be read the script stops, unless you ask for one or
#                          set TN_K3S_FORCE=true)
#   TN_K3S_UPGRADE=true (default: false; a re-run KEEPS the k3s version that is installed. true lets
#                          TN_K3S_VERSION replace it: never a downgrade, never more than one minor version)
#   TN_K3S_FORCE=true (default: false; allows an upgrade over more than one minor version, an agent that
#                          is newer than its server, and an install when the release of the server is unknown)
#   TN_K3S_CGROUPV1=true|false (default: detected; on cgroup v1 with k3s >= v1.31 the kubelet gets
#                          fail-cgroupv1=false, see /etc/rancher/k3s/config.yaml.d/99-teknoir-cgroupv1.yaml)

# The k3s release to install: the stable channel when this was written (https://update.k3s.io/v1-release/channels)
# and the release the CA tests in test/k3s-ca prove. (An agent installs the release of its server instead.)
# This is the release for a NEW server: a device that already has k3s keeps its version (TN_K3S_UPGRADE=true
# replaces it; a downgrade is always refused).
# Who chose the k3s release: the person who runs this script (INSTALL_K3S_VERSION in the environment) or
# the default below. An agent installs the release of its server unless one was asked for.
if [ -n "${INSTALL_K3S_VERSION:-}" ]; then TN_K3S_PIN_SOURCE=env; else TN_K3S_PIN_SOURCE=default; fi
export TN_K3S_PIN_SOURCE
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
