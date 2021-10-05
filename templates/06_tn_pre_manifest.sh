info "Install Teknoir Manifests"
$SUDO mkdir -p /var/lib/rancher/k3s/server/manifests
$SUDO tee /var/lib/rancher/k3s/server/manifests/teknoir.yaml > /dev/null << EOL
