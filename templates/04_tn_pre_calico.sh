EOL

if [ "${INSTALL_CALICO}" = true ]; then
    info "Install Calico Manifests"
    $SUDO tee /var/lib/rancher/k3s/server/manifests/calico.yaml > /dev/null << EOL
