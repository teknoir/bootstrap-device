info "Install agent specific keys"
export CONFIG_PATH=/etc/teknoir
$SUDO mkdir -p ${CONFIG_PATH}
$SUDO mkdir -p /toe_conf && $SUDO rm -rf /toe_conf && $SUDO ln -s ${CONFIG_PATH}/ /toe_conf # For backward compatibility
download ${CONFIG_PATH}/roots.pem https://pki.goog/roots.pem
$SUDO chmod 440 ${CONFIG_PATH}/roots.pem
$SUDO chown 65532:root ${CONFIG_PATH}/roots.pem
$SUDO tee ${CONFIG_PATH}/rsa_private.pem > /dev/null << EOL
${_RSA_PRIVATE}
EOL
$SUDO chmod 440 ${CONFIG_PATH}/rsa_private.pem
$SUDO chown 65532:root ${CONFIG_PATH}/rsa_private.pem
$SUDO tee ${CONFIG_PATH}/rsa_public.pem > /dev/null << EOL
${_RSA_PUBLIC}
EOL
$SUDO chmod 444 ${CONFIG_PATH}/rsa_public.pem
$SUDO chown 65532:root ${CONFIG_PATH}/rsa_public.pem


$SUDO cp ${CONFIG_PATH}/rsa_public.pem /usr/local/share/ca-certificates/${_DEVICE_ID}-${_DOMAIN}.crt
$SUDO update-ca-certificates