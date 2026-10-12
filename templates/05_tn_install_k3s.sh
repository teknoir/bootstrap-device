export PRODUCT="${PRODUCT:-k3s}"

# The k3s release for the installer.
if [ "${TN_K3S_VERSION}" = stable ]; then
    unset INSTALL_K3S_VERSION
else
    export INSTALL_K3S_VERSION="${TN_K3S_VERSION}"
    info "Installing k3s ${INSTALL_K3S_VERSION}"
fi

# Order: (0) the arguments of the k3s installer, (1) the k3s release policy and the cgroup v1 kubelet flag,
# (2) the CA, (3) the k3s installer.
# (0) comes first because (1) reads INSTALL_K3S_EXEC (tn_inst_cgroup_configured_elsewhere): it must see
# what the installer will get. A fail-cgroupv1 that the caller put there is "set by the device itself"
# for the library, which then removes its drop-in; if this script rebuilt the variable afterwards without
# the caller's value, the installer would get no flag at all and a k3s >= v1.35 would not start on a
# cgroup v1 device. A value the caller gave is therefore kept, after ours (as the cli template does).
# (1) comes before the CA step: it refuses before anything on the device is changed, and the kubelet flag
# is in place when the CA step restarts k3s (a k3s that a cgroup v1 device made exit restarts itself in a
# loop, and has to be up for rotate-ca). A re-run keeps the installed k3s (unless TN_K3S_UPGRADE=true) and
# sets fail-cgroupv1=false on cgroup v1 hosts, which Kubernetes >= 1.35 would refuse (library:
# 04_tn_k3s_install_lib.sh, vendored from teknoir/cli). The data dir is looked up first, the way the CA step
# does it: a k3s datastore there decides whether a k3s whose version cannot be read is installed over. A
# data dir that disagrees with config.yaml is refused right there, before (1) changes anything.
# BEGIN install-k3s-exec
export INSTALL_K3S_EXEC="server --disable=traefik --token ${_K3S_TOKEN} --tls-san ${_DEVICE_ID}.${_DOMAIN} --tls-san 10.0.0.10${INSTALL_K3S_EXEC:+ ${INSTALL_K3S_EXEC}}"
if [ "${USE_DOCKER}" = true ]; then
    info "Use docker container-runtime for K3s"
    export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} --docker"
fi
# END install-k3s-exec
tn_ca_resolve_datadir
tn_ca_require_consistent_datadir
tn_inst_prepare server

# The k3s root CA is the device certificate (rsa_public.pem), re-issued from the
# same device key with CA:TRUE and keyCertSign, which k3s >= v1.34.12 / v1.35.9 /
# v1.36.5 / v1.37.1 requires. The library (04_tn_k3s_ca_lib.sh, vendored from
# teknoir/cli, see test/k3s-ca/VENDORED_FROM) takes CONFIG_PATH, PRODUCT, _DEVICE_ID
# and _DOMAIN from the environment, and finds DATA_DIR itself the way k3s does (an
# explicit DATA_DIR wins, then ExecStart of k3s.service, config.yaml.d, config.yaml,
# default /var/lib/rancher/k3s) and exports it; it is used below.
#   - k3s never started here:  the PKI is created (a valid one is kept)
#   - k3s started, root fine:  nothing is touched, re-running this script is safe
#   - k3s started, old root:   repaired first (k3s certificate rotate-ca), before the
#                              installer below can upgrade k3s and brick the device;
#                              TN_K3S_CA_AUTO_REMEDIATE=false stops with advice instead
tn_k3s_ca_setup

info "Install Rancher K3s"
# The data dir stays what k3s uses on devices today: /var/lib/rancher/k3s. (An earlier version of this
# script wrote "data-dir: /opt/k3s" to config.yaml, but the config.yaml written below replaced that file
# before the installer ran, so it never took effect and no device runs k3s from /opt/k3s.) The CA was
# prepared in ${DATA_DIR} above; if that is not the default, keep it in config.yaml, or the unit
# that the installer writes would start k3s on another directory.
mkdir -p /etc/rancher/k3s
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

export K3S_CONFIG_PATH=/etc/rancher/k3s
$SUDO mkdir -p ${K3S_CONFIG_PATH}
# A re-run must not replace a config.yaml that already exists (it may hold keys of the device owner,
# like a kubelet-arg): the Teknoir keys are added when they are missing (tn_inst_config_ensure).
tn_inst_config_ensure ${K3S_CONFIG_PATH}/config.yaml node-name "node-name: teknoir-master"
if [ "${DATA_DIR}" != "/var/lib/rancher/k3s" ]; then
    tn_inst_config_ensure ${K3S_CONFIG_PATH}/config.yaml data-dir "data-dir: ${DATA_DIR}"
fi

# The release (INSTALL_K3S_VERSION) and the kubelet flag were decided by tn_inst_prepare above.
export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh
# The kubelet flag that had to wait for the installer (an installed k3s older than v1.31 that was upgraded)
tn_inst_finish

# Tell the agents which k3s release this server runs: they install exactly that one (a kubelet must not
# be newer than its apiserver), and k3s does not answer /version to an anonymous caller. Served by k3s at
# https://<server>:6443/static/teknoir/k3s-version.
tn_inst_publish_release
