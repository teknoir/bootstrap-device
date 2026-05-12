info "Install Rancher K3s Agent"
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

if [ -z "${K3S_URL}" ]; then
    DEFAULT_K3S_URL="https://${_DEVICE_ID}.local:6443"
    read -p "Is ${DEFAULT_K3S_URL} the correct URL to the server/master node? [Y/n] " confirm
    confirm=${confirm:-"Y"}
    if echo "${confirm}" | grep -iq "^y$"; then
        export K3S_URL=${DEFAULT_K3S_URL}
    else
        read -p "Please enter the K3S_URL: " K3S_URL
        export K3S_URL=${K3S_URL}
    fi
fi
export K3S_URL=${K3S_URL}
export K3S_TOKEN="${K3S_TOKEN:-"${_K3S_TOKEN}"}"

export INSTALL_K3S_EXEC="agent"
if [ "${USE_DOCKER}" = true ]; then
    info "Use docker container-runtime for K3s"
    export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} --docker"
fi

export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh

info "K3s agent node joined successfully!"
