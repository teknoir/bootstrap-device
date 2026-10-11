export PRODUCT="${PRODUCT:-k3s}"

# The k3s root CA is the device certificate (rsa_public.pem), re-issued from the
# same device key with CA:TRUE and keyCertSign, which k3s >= v1.34.12 / v1.35.9 /
# v1.36.5 / v1.37.1 requires. The library (04_tn_k3s_ca_lib.sh, vendored from
# teknoir/cli, see test/k3s-ca/VENDORED_FROM) takes CONFIG_PATH, PRODUCT, _DEVICE_ID
# and _DOMAIN from the environment, and finds DATA_DIR itself the way k3s does (an
# explicit DATA_DIR wins, then ExecStart of k3s.service, config.yaml.d, config.yaml,
# default /var/lib/rancher/k3s) and exports it; it is used below.
#   - k3s never started here:  the PKI is created (a valid one is kept)
#   - k3s started, root fine:  nothing is touched, re-running this script is safe
#   - k3s started, old root:   repaired first (k3s certificate rotate-ca), before the
#                              installer below can upgrade k3s and brick the device;
#                              TN_K3S_CA_AUTO_REMEDIATE=false stops with advice instead
tn_k3s_ca_setup

info "Install Rancher K3s"
# The data dir stays what k3s uses on devices today: /var/lib/rancher/k3s. (An earlier version of this
# script wrote "data-dir: /opt/k3s" to config.yaml, but the config.yaml written below replaced that file
# before the installer ran, so it never took effect and no device runs k3s from /opt/k3s.) The CA was
# prepared in ${DATA_DIR} above; if that is not the default, keep it in config.yaml, or the unit
# that the installer writes would start k3s on another directory.
mkdir -p /etc/rancher/k3s
cat >/etc/sysctl.d/teknoir.inotify.conf <<'EOF'
fs.inotify.max_user_instances=1024
EOF
sysctl --system

download k3s_installer.sh https://get.k3s.io
$SUDO chmod +x k3s_installer.sh

if [ ${OS_BUILD} ] || [ ${INSECURE} ]; then
    info "Running installation without verifying ssl certs on URLs"
    $SUDO sed -i "s#curl -w#curl --insecure -w#g" k3s_installer.sh
    $SUDO sed -i "s#curl -o#curl --insecure -o#g" k3s_installer.sh
fi

if [ ${OS_BUILD} ]; then
    info "OS Build specifics"
    export INSTALL_K3S_SKIP_START=true
    $SUDO sed -i "s#-d /run/systemd#true#g" k3s_installer.sh
fi

export INSTALL_K3S_EXEC="server --disable=traefik --token ${_K3S_TOKEN} --tls-san ${_DEVICE_ID}.${_DOMAIN} --tls-san 10.0.0.10"
if [ "${USE_DOCKER}" = true ]; then
    info "Use docker container-runtime for K3s"
    export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} --docker"
fi

export K3S_CONFIG_PATH=/etc/rancher/k3s
$SUDO mkdir -p ${K3S_CONFIG_PATH}
# A re-run must not replace a config.yaml that already exists (it may hold keys of the device owner,
# like a kubelet-arg): the Teknoir keys are added when they are missing (tn_inst_config_ensure).
tn_inst_config_ensure ${K3S_CONFIG_PATH}/config.yaml node-name "node-name: teknoir-master"
if [ "${DATA_DIR}" != "/var/lib/rancher/k3s" ]; then
    tn_inst_config_ensure ${K3S_CONFIG_PATH}/config.yaml data-dir "data-dir: ${DATA_DIR}"
fi

if [ "${TN_K3S_VERSION}" = stable ]; then
    unset INSTALL_K3S_VERSION
else
    export INSTALL_K3S_VERSION="${TN_K3S_VERSION}"
    info "Installing k3s ${INSTALL_K3S_VERSION}"
fi

# A re-run keeps the installed k3s (unless TN_K3S_UPGRADE=true) and sets fail-cgroupv1=false on cgroup v1
# hosts, which Kubernetes >= 1.35 would refuse (library: 04_tn_k3s_install_lib.sh, vendored from teknoir/cli).
tn_inst_prepare server
export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh
