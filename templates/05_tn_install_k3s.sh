info "Prepare K3s CA Certs"
export PRODUCT="${PRODUCT:-k3s}"
export DATA_DIR="${DATA_DIR:-/var/lib/rancher/${PRODUCT}}"

# The k3s root CA is the device certificate (rsa_public.pem), re-issued from the
# same device key with CA:TRUE and keyCertSign, which k3s >= v1.34.12 / v1.35.9 /
# v1.36.5 / v1.37.1 requires. The library (04_tn_k3s_ca_lib.sh, vendored from
# teknoir/cli, see test/k3s-ca/VENDORED_FROM) takes CONFIG_PATH, DATA_DIR,
# PRODUCT, _DEVICE_ID and _DOMAIN from the environment.
#   - k3s never started here:  the PKI is created (a valid one is kept)
#   - k3s started, root fine:  nothing is touched, re-running this script is safe
#   - k3s started, old root:   repaired first (k3s certificate rotate-ca), before the
#                              installer below can upgrade k3s and brick the device;
#                              TN_K3S_CA_AUTO_REMEDIATE=false stops with advice instead
tn_k3s_ca_setup

info "Install Rancher K3s"
mkdir -p /etc/rancher/k3s
mkdir -p /opt/k3s
cat >/etc/rancher/k3s/config.yaml <<'EOF'
data-dir: /opt/k3s
disable:
  - traefik
EOF
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
$SUDO tee ${K3S_CONFIG_PATH}/config.yaml > /dev/null << EOL
node-name: teknoir-master
EOL

export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh
