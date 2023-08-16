INSTALL_WATCHDOG=${INSTALL_WATCHDOG:-true}
if [ "${INSTALL_WATCHDOG}" = true ]; then
    info "Install Teknoir Watchdog"
    $SUDO mkdir -p /usr/local/lib/teknoir
    $SUDO chmod 755 /usr/local/lib/teknoir
    info "Install apt dependencies"
    $SUDO apt install -y python3-pip libsystemd-dev
    $SUDO apt autoremove --purge -y || true
    $SUDO apt clean || true
    $SUDO pip3 install -U pip netifaces kubernetes systemd-watchdog python-statemachine
