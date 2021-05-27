#!/usr/bin/env bash
set -e

SUDO=''
if (( $EUID != 0 )); then
    echo "Please be ready to enter the device´s sudo password:"
    SUDO='sudo -H'
fi

tmp_dir=$(mktemp -d -t bootstrap-device-XXX)
pushd $tmp_dir
echo "Teknoir bootstrapping..."

echo "Install apt dependencies"
$SUDO apt install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common gettext-base
$SUDO apt autoremove --purge -y || true
$SUDO apt clean || true

echo "Install rancher k3s"
$SUDO curl -sfL https://get.k3s.io > k3s_installer.sh
$SUDO install -m 644 k3s_installer.sh /usr/bin/k3s_installer.sh
$SUDO chmod +x /usr/bin/k3s_installer.sh
$SUDO /usr/bin/k3s_installer.sh --kubelet-arg='feature-gates=DevicePlugins=true'

echo "Install Teknoir Orchestration Engine"
$SUDO mkdir -p /var/lib/rancher/k3s/server/manifests
$SUDO tee /var/lib/rancher/k3s/server/manifests/mqtt.yaml > /dev/null << EOL
---
apiVersion: v1
kind: Service
metadata:
  name: mqtt
  namespace: kube-system
spec:
  selector:
    app: mqtt
  ports:
    - protocol: TCP
      port: 1883
      targetPort: 1883
---
apiVersion: v1
kind: Service
metadata:
  name: mqtt-localhost
  namespace: kube-system
spec:
  type: NodePort
  ports:
    - nodePort: 31883
      port: 1883
      protocol: TCP
      targetPort: 1883
  selector:
    app: mqtt
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mqtt
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mqtt
  template:
    metadata:
      labels:
        app: mqtt
    spec:
      containers:
        - name: mqtt
          image: gcr.io/teknoir/hmq:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 1883
EOL

$SUDO tee /var/lib/rancher/k3s/server/manifests/sa.yaml > /dev/null << EOL
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: toe
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: toe
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
  - kind: ServiceAccount
    name: toe
    namespace: kube-system
EOL

$SUDO tee /var/lib/rancher/k3s/server/manifests/toe.yaml > /dev/null << envsubst << EOL
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: toe
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: toe
  template:
    metadata:
      labels:
        app: toe
    spec:
      serviceAccountName: toe
      containers:
        - name: toe
          image: gcr.io/teknoir/toe:latest
          imagePullPolicy: Always
          env:
            - name: TOE_PROJECT
              value: "${GCP_PROJECT}"
            - name: TOE_IOT_REGISTRY
              value: "${IOT_REGISTRY}"
            - name: TOE_DEVICE
              value: "${DEVICE_ID}"
            - name: TOE_CA_CERT
              value: "/toe_conf/roots.pem"
            - name: TOE_PRIVATE_KEY
              value: "/toe_conf/rsa_private.pem"
          volumeMounts:
            - name: toe-volume
              mountPath: /toe_conf
      volumes:
        - name: toe-volume
          hostPath:
            # directory location on host
            path: /toe_conf
EOL

echo "Device bootstrapped successfully!"
popd
rm -rf $tmp_dir
