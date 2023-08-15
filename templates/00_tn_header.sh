#!/bin/sh
set -e
set -o noglob
#set -x

# This is the drop in device bootstrap script for the Teknoir platform.
# It should work for most arm32/arm64/amd64 devices running Debian or Ubuntu.

# Usage:
#   TBD
#
# Environment variables:
#   OS_BUILD=true (default: false, for OS builds)
#   INSECURE=true (default: false, for OS builds, or if you want to run without ssl cert verification)
#   INSTALL_WATCHDOG=false (default: true, enable or disable the teknoir watchdog service)
#   USE_DOCKER=false (default: true, enable or disable the use of docker as container runtime for k3s)

