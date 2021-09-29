info "Install Rancher K3s"
download k3s_installer.sh https://get.k3s.io
$SUDO chmod +x k3s_installer.sh

if [ "${OS_BUILD}" = true ] || [ "${INSECURE}" = true ]; then
    info "Running installation without verifying ssl certs on URLs"
    $SUDO sed -i "s#curl -w#curl --insecure -w#g" k3s_installer.sh
    $SUDO sed -i "s#curl -o#curl --insecure -o#g" k3s_installer.sh
fi

if [ "${OS_BUILD}" = true ]; then
    info "OS Build specifics"
    $SUDO sed -i "s#-d /run/systemd#true#g" k3s_installer.sh
fi

if [ "${INSTALL_CALICO}" = true ]; then
    info "Calico options for K3s"
    export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} --flannel-backend=none --disable-network-policy --disable=traefik"
fi

export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh
