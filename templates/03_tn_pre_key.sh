info "Install device specific keys"
export CONFIG_PATH=/etc/teknoir
$SUDO mkdir -p ${CONFIG_PATH}
$SUDO mkdir -p /toe_conf && $SUDO rm -rf /toe_conf && $SUDO ln -s ${CONFIG_PATH}/ /toe_conf # For backward compatibility
download ${CONFIG_PATH}/roots.pem https://pki.goog/roots.pem
$SUDO tee ${CONFIG_PATH}/rsa_private.pem > /dev/null << EOL
