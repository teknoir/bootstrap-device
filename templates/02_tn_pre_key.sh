verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'

SUDO=''
if [ "${EUID}" != 0 ]; then
    info "Please be ready to enter the device´s sudo password:"
    SUDO='sudo -H'
fi

TMP=$(mktemp -d -t bootstrap-device-XXX)
cd $TMP
info "Teknoir bootstrapping...${TMP}"

info "Install Rancher K3s"
download k3s_installer.sh https://get.k3s.io
chmod +x ./k3s_installer.sh

if [ "${OS_BUILD}" = true ]; then
    sed -i "s#-d /run/systemd#true#g" ./k3s_installer.sh
fi

if [ "${INSTALL_CALICO}" = true ]; then
    info "Calico options for K3s"
    export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} --flannel-backend=none --disable-network-policy --disable=traefik"
fi

export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh

info "Install device specific keys"
export CONFIG_PATH=/etc/teknoir
$SUDO mkdir -p ${CONFIG_PATH}
$SUDO mkdir -p /toe_conf && $SUDO rm -rf /toe_conf && $SUDO ln -s ${CONFIG_PATH}/ /toe_conf # For backward compatibility
download ${CONFIG_PATH}/roots.pem https://pki.goog/roots.pem
$SUDO tee ${CONFIG_PATH}/rsa_private.pem > /dev/null << EOL
