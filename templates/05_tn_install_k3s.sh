info "Prepare K3s CA Certs"
export PRODUCT="${PRODUCT:-k3s}"
export DATA_DIR="${DATA_DIR:-/var/lib/rancher/${PRODUCT}}"

if command -v openssl-3 >/dev/null 2>&1; then
  OPENSSL=openssl-3
else
  OPENSSL=openssl
fi

info "Using ${OPENSSL}: $(${OPENSSL} version)"

if ! ${OPENSSL} ecparam -name prime256v1 -genkey -noout -out /dev/null >/dev/null 2>&1; then
  fatal "openssl not found or missing Elliptic Curve (ecparam) support."
fi

${OPENSSL} version | grep -qF 'OpenSSL 3' && OPENSSL_GENRSA_FLAGS=-traditional

mkdir -p "${DATA_DIR}/server/tls/etcd"

cp ${CONFIG_PATH}/rsa_public.pem ${DATA_DIR}/server/tls/root-ca.pem
cp ${CONFIG_PATH}/rsa_private.pem ${DATA_DIR}/server/tls/root-ca.key

cd "${DATA_DIR}/server/tls"

# Set up temporary openssl configuration
mkdir -p ".ca/certs"
trap "rm -rf .ca" EXIT
touch .ca/index
openssl rand -hex 8 > .ca/serial
cat >.ca/config <<'EOF'
[ca]
default_ca = ca_default
[ca_default]
dir = ./.ca
database = $dir/index
serial = $dir/serial
new_certs_dir = $dir/certs
default_md = sha256
policy = policy_anything
[policy_anything]
commonName = supplied
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyEncipherment, keyCertSign
EOF

if [ -e service.key ]; then
  info "Generating additional Kubernetes service account issuer RSA key"
  OLD_SERVICE_KEY="$(cat service.key)"
else
  info "Generating Kubernetes service account issuer RSA key"
fi
${OPENSSL} genrsa ${OPENSSL_GENRSA_FLAGS:-} -out service.key 2048
echo "${OLD_SERVICE_KEY}" >> service.key

cat root-ca.pem > root-ca.crt

if [ ! -e root-ca.key ]; then
  fatal "Cannot generate intermediate certificate without root certificate private key"
fi

info "Generating intermediate certificate authority RSA key and certificate"
${OPENSSL} genrsa ${OPENSSL_GENRSA_FLAGS:-} -out intermediate-ca.key 4096
${OPENSSL} req -new -nodes \
               -subj "/CN=${PRODUCT}-intermediate-ca@${_DEVICE_ID}.${_DOMAIN}" \
               -key intermediate-ca.key |
${OPENSSL} ca  -batch -notext -days 3700 \
               -in /dev/stdin \
               -out intermediate-ca.pem \
               -keyfile root-ca.key \
               -cert root-ca.pem \
               -config .ca/config \
               -extensions v3_ca

cat intermediate-ca.pem root-ca.pem > intermediate-ca.crt

if [ ! -e intermediate-ca.key ]; then
  fatal "Cannot generate leaf certificates without intermediate certificate private key"
fi

# Generate new leaf CAs for all the control-plane and etcd components
for TYPE in client server request-header etcd/peer etcd/server; do
  CERT_NAME="${PRODUCT}-$(echo ${TYPE} | tr / -)-ca"
  info "Generating ${CERT_NAME} leaf certificate authority EC key and certificate"
  ${OPENSSL} ecparam -name prime256v1 -genkey -noout -out ${TYPE}-ca.key
  ${OPENSSL} req -new -nodes \
                 -subj "/CN=${CERT_NAME}@${_DEVICE_ID}.${_DOMAIN}" \
                 -key ${TYPE}-ca.key |
  ${OPENSSL} ca  -batch -notext -days 3700 \
                 -in /dev/stdin \
                 -out ${TYPE}-ca.pem \
                 -keyfile intermediate-ca.key \
                 -cert intermediate-ca.pem \
                 -config .ca/config \
                 -extensions v3_ca
  cat ${TYPE}-ca.pem \
      intermediate-ca.pem \
      root-ca.pem > ${TYPE}-ca.crt
done

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

export INSTALL_K3S_EXEC="server --token ${_K3S_TOKEN} --tls-san ${_DEVICE_ID}.${_DOMAIN} --tls-san 10.0.0.10"
if [ "${USE_DOCKER}" = true ]; then
    info "Use docker container-runtime for K3s"
    export INSTALL_K3S_EXEC="${INSTALL_K3S_EXEC} --docker"
fi

export K3S_CONFIG_PATH=/etc/rancher/k3s
$SUDO mkdir -p ${K3S_CONFIG_PATH}
$SUDO tee ${K3S_CONFIG_PATH}/config.yaml > /dev/null << EOL
node-name: teknoir-master
EOL

export INSTALL_K3S_SYMLINK=force
$SUDO ./k3s_installer.sh
