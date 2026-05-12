#!/usr/bin/env bash
set -euo pipefail

SRC_KUBECONFIG="${1:-/etc/rancher/k3s/k3s.yaml}"

if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  TARGET_USER="${SUDO_USER}"
  TARGET_HOME="$(eval echo "~${SUDO_USER}")"
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="${HOME}"
fi

TARGET_GROUP="$(id -gn "${TARGET_USER}")"
DEST_DIR="${TARGET_HOME}/.kube"
DEST_CONFIG="${DEST_DIR}/config"
BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"
KUBECONFIG_EXPORT='export KUBECONFIG="$HOME/.kube/config"'

TARGET_SHELL_PATH=""
if command -v getent >/dev/null 2>&1; then
  TARGET_SHELL_PATH="$(getent passwd "${TARGET_USER}" | cut -d: -f7 || true)"
elif command -v dscl >/dev/null 2>&1; then
  TARGET_SHELL_PATH="$(dscl . -read "/Users/${TARGET_USER}" UserShell 2>/dev/null | awk '{print $2}' || true)"
fi

if [[ -z "${TARGET_SHELL_PATH}" ]]; then
  TARGET_SHELL_PATH="${SHELL:-/bin/bash}"
fi

TARGET_SHELL_NAME="$(basename "${TARGET_SHELL_PATH}")"

if ! sudo test -r "${SRC_KUBECONFIG}"; then
  echo "ERROR: Cannot read ${SRC_KUBECONFIG}." >&2
  echo "Check that K3s is installed and running, and that the file exists." >&2
  exit 1
fi

echo "Installing K3s kubeconfig for user '${TARGET_USER}'..."
sudo install -d -m 700 -o "${TARGET_USER}" -g "${TARGET_GROUP}" "${DEST_DIR}"

if [[ -f "${DEST_CONFIG}" ]]; then
  BACKUP_PATH="${DEST_CONFIG}.bak.${BACKUP_SUFFIX}"
  echo "Backing up existing kubeconfig to ${BACKUP_PATH}"
  sudo cp "${DEST_CONFIG}" "${BACKUP_PATH}"
  sudo chown "${TARGET_USER}:${TARGET_GROUP}" "${BACKUP_PATH}"
  sudo chmod 600 "${BACKUP_PATH}"
fi

sudo cp "${SRC_KUBECONFIG}" "${DEST_CONFIG}"
sudo chown "${TARGET_USER}:${TARGET_GROUP}" "${DEST_CONFIG}"
sudo chmod 600 "${DEST_CONFIG}"

case "${TARGET_SHELL_NAME}" in
  zsh)
    PROFILE_FILE="${TARGET_HOME}/.zshrc"
    ;;
  bash)
    PROFILE_FILE="${TARGET_HOME}/.bashrc"
    ;;
  *)
    PROFILE_FILE="${TARGET_HOME}/.profile"
    ;;
esac

sudo touch "${PROFILE_FILE}"
sudo chown "${TARGET_USER}:${TARGET_GROUP}" "${PROFILE_FILE}"
if sudo grep -qsF "${KUBECONFIG_EXPORT}" "${PROFILE_FILE}"; then
  echo "KUBECONFIG already configured in ${PROFILE_FILE}"
else
  echo "Adding KUBECONFIG export to ${PROFILE_FILE} (detected shell: ${TARGET_SHELL_NAME})"
  printf '\n%s\n' "${KUBECONFIG_EXPORT}" | sudo tee -a "${PROFILE_FILE}" >/dev/null
  sudo chown "${TARGET_USER}:${TARGET_GROUP}" "${PROFILE_FILE}"
fi

echo "Done."
echo "Kubeconfig installed at: ${DEST_CONFIG}"
echo "For this shell session, run:"
echo "  export KUBECONFIG=\"\$HOME/.kube/config\""
echo "Then run:"
echo "  kubectl get nodes"
