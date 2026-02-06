# To use this script:
# Get the node token from your master node:
# > sudo cat /var/lib/rancher/k3s/server/node-token
# Replace YOUR_K3S_NODE_TOKEN_HERE with the actual token
# Run on the new worker node:
# > chmod +x join_k3s_node.sh
# > sudo ./join_k3s_node.sh

#!/bin/sh
set -e
set -o noglob
umask 027

# --- helper functions ---
info() { echo '[INFO] ' "$@"; }
warn() { echo '[WARN] ' "$@" >&2; }
fatal() { echo '[ERROR] ' "$@" >&2; exit 1; }

# Exit if not running as root
[ $(id -u) -eq 0 ] || fatal 'You must run this script as root'

# --- Configuration ---
K3S_URL="https://rtx2000-pro-bw-se.local:6443"
K3S_TOKEN="5b41346fcd6eeec7f0f38cff0b35476996a686fe6f451e47d2a571329cac560d"

_CA_CERT="-----BEGIN CERTIFICATE-----
MIIDlzCCAn+gAwIBAgIUI3To1jMaN8xHBg1rHV7Ez46QeSgwDQYJKoZIhvcNAQEL
BQAwWzELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMREwDwYDVQQHDAhTSG91
c3RvbjEUMBIGA1UECgwLVGVrbm9pciBMTEMxEzARBgNVBAMMCnRla25vaXIuYWkw
HhcNMjYwMjA2MDkxODE4WhcNMjcwMjA2MDkxODE4WjBbMQswCQYDVQQGEwJVUzEO
MAwGA1UECAwFVGV4YXMxETAPBgNVBAcMCFNIb3VzdG9uMRQwEgYDVQQKDAtUZWtu
b2lyIExMQzETMBEGA1UEAwwKdGVrbm9pci5haTCCASIwDQYJKoZIhvcNAQEBBQAD
ggEPADCCAQoCggEBALgmSJHcV+apJVaA1GWOn5coQSL0+pEIt0ktuGQt02l/yUHB
r9DKMty5ySAPjw4NpJZ2YRQoOcHKg+U7kb6KuJiMg8Lt0wrAgAg+7NnBpCrdor3l
/fBFjgl+P93wiD43lK4c/dyPZu1Xo52RQOy7zzrmAVUmHE2jLyGRoOhAP3Xt2fC9
cg4lWwZ5ykr6gTon9hDuX/hp1U5l+tCxVi0JwP2uzl0o6cmU0aq+ZU0xyJKBYGLg
NjYFgt20xJcUGtbut28f8etBs8RFqKPp19qwq64+XbzfQs/TIakLX/sH84JUJj0H
1beXH1jD/fUqL92Hq1eizt1y9MXt1Wsmwswe79kCAwEAAaNTMFEwHQYDVR0OBBYE
FLOSZCQN3C1KjoJQ3b82odN4iXmtMB8GA1UdIwQYMBaAFLOSZCQN3C1KjoJQ3b82
odN4iXmtMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBABh2v5+Z
WC88jtQ6pO3J0a8S3gPUYRBee4AjrrCaYOcpu2O1ZdTNJjne+IzrnLp6mmbLdM04
FjyYTNspiG01Gt/176bRaW6ryMx8HMYX0xbh9PHW4JGQrpxFViH6ym5PrxCzSXQV
i8ajPNpceqXqS075Q5mtmAeFar4+hR7vPaK9UoBJRaNI87PsXgscFiid/56p0ml4
jbLKxoeklOBQwb/wOn7yI9vimxdLbgzHsKQkCjbcCCzm/XG7IU9MrnsSurB/uO6h
qb+TJHsEyRjJ2u8+J3zQNjPhFwFFWFpGAD5qEY9rCw6nj1naamIWHNXIvPB6G9KS
yKSFaW/7sLXvfXQ=
-----END CERTIFICATE-----"

# --- Install CA certificate ---
info "Installing cluster CA certificate"
mkdir -p /etc/rancher/k3s
echo "${_CA_CERT}" | tee /etc/rancher/k3s/cluster-ca.crt > /dev/null
chmod 644 /etc/rancher/k3s/cluster-ca.crt

# --- Install K3s agent ---
info "Installing K3s agent node"
curl -sfL https://get.k3s.io | \
  K3S_URL="${K3S_URL}" \
  K3S_TOKEN="${K3S_TOKEN}" \
  INSTALL_K3S_EXEC="agent" \
  sh -

info "K3s agent node joined successfully!"
info "Verify with: kubectl get nodes"