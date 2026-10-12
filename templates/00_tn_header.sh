#!/bin/sh
set -e
set -o noglob
#set -x
umask 027

# This is the drop in device bootstrap script for the Teknoir platform.
# It should work for most arm32/arm64/amd64 devices running Debian or Ubuntu.

# Usage:
#   TBD
#
# Environment variables:
#   OS_BUILD=true (default: false, for OS builds)
#   INSECURE=true (default: false, for OS builds, or if you want to run without ssl cert verification)
#   INSTALL_WATCHDOG=true (default: false, enable or disable the teknoir watchdog service)
#   USE_DOCKER=true (default: false, enable the use of docker as container runtime for k3sm inly works for k3s < 1.24)
#   CREATE_USER=false (default: ask, create a user for the device without asking)
#   INSTALL_K3S_VERSION=v1.xx.y+k3sN (default: TN_K3S_VERSION below; "stable" = whatever the k3s installer
#                          picks as stable today, the old behaviour)
#   TN_K3S_UPGRADE=true (default: false; a re-run KEEPS the k3s version that is installed. true lets
#                          TN_K3S_VERSION replace it: never a downgrade, never more than one minor version)
#   TN_K3S_FORCE=true (default: false; allows an upgrade over more than one minor version, and an
#                          install over a k3s whose version cannot be read)
#   TN_K3S_CGROUPV1=true|false (default: detected; on cgroup v1 with k3s >= v1.31 the kubelet gets
#                          fail-cgroupv1=false, see /etc/rancher/k3s/config.yaml.d/99-teknoir-cgroupv1.yaml)
#   TN_K3S_CA_AUTO_REMEDIATE=false (default: true; a re-run on a device bootstrapped with the old
#                          root CA repairs it before k3s is touched. false stops with advice instead)
#   DATA_DIR=/path (default: the data dir k3s uses on the device, found like k3s finds it: ExecStart of
#                          k3s.service, /etc/rancher/k3s/config.yaml.d/*.yaml, config.yaml, else /var/lib/rancher/k3s)

# The k3s release to install: the stable channel when this was written (https://update.k3s.io/v1-release/channels)
# and the release the CA tests in test/k3s-ca prove. A server and its agents must run the same release.
# This is the release for a NEW device: a device that already has k3s keeps its version (TN_K3S_UPGRADE=true
# replaces it; a downgrade is always refused).
# Who chose the k3s release: the person who runs this script (INSTALL_K3S_VERSION in the environment) or
# the default below. An agent installs the release of its server unless one was asked for.
if [ -n "${INSTALL_K3S_VERSION:-}" ]; then TN_K3S_PIN_SOURCE=env; else TN_K3S_PIN_SOURCE=default; fi
export TN_K3S_PIN_SOURCE
TN_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.36.5+k3s1}"
