info "Install Rancher K3s"
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

if [ "${USE_DOCKER}" = true ]; then
    info "Use docker container-runtime for K3s"
    export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} --docker"
fi

export K3S_CONFIG_PATH=/etc/rancher/k3s
$SUDO mkdir -p ${K3S_CONFIG_PATH}
$SUDO tee ${K3S_CONFIG_PATH}/config.yaml > /dev/null << EOL
write-kubeconfig-mode: 644
node-name: teknoir-master
EOL

export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh
