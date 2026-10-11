#!/bin/bash
# Assemble the device bootstrap scripts from templates/ and agent_templates/ with
# a throwaway environment (placeholders only, no real keys) and check that:
#   - both scripts pass `sh -n` and `dash -n`
#   - the server script uses tn_k3s_ca_setup and embeds the CA library
#   - the old verbatim "cp rsa_public.pem -> root-ca.pem" is gone
#   - server and agent install the same pinned k3s release (INSTALL_K3S_VERSION, default v1.36.5+k3s1,
#     "stable" restores the installer's own choice); no dead data-dir line; one "Prepare K3s CA Certs"
#   - the agent script is free of CA preparation (agents take the bundle from /cacerts); it only
#     adds the device certificate to the OS trust store
# Usage: test/check-assembly.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

export _GCP_PROJECT=throwaway _IOT_REGISTRY=throwaway-ns _DOMAIN=example.invalid \
  _DEVICE_ID=throwaway-dev _RSA_PRIVATE=throwaway-private-placeholder \
  _RSA_PUBLIC=throwaway-public-placeholder _FIRST_USER_NAME=u _FIRST_USER_PASS=p \
  _FIRST_USER_KEY=k _BOOTSTRAP_FILE=x.sh _AR_DOCKER_SECRET=e30= _K3S_TOKEN=throwaway-token \
  _CA_CERT=throwaway-ca

# shellcheck disable=SC1091
. "$ROOT/build_bootstrap_script.sh"
build_bootstrap_script "$OUT/server.sh" "$ROOT/templates" >/dev/null
build_bootstrap_script "$OUT/agent.sh" "$ROOT/agent_templates" >/dev/null

fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok:   $*"; }

for f in server agent; do
  if sh -n "$OUT/$f.sh"; then ok "$f: sh -n"; else bad "$f: sh -n"; fi
  if dash -n "$OUT/$f.sh"; then ok "$f: dash -n"; else bad "$f: dash -n"; fi
done

grep -q '^tn_k3s_ca_setup$' "$OUT/server.sh" && ok "server: calls tn_k3s_ca_setup" || bad "server: tn_k3s_ca_setup call missing"
grep -q '^tn_k3s_ca_setup()' "$OUT/server.sh" && ok "server: embeds the CA library" || bad "server: library not embedded"
grep -q '^TN_K3S_CA_NO_MAIN=1' "$OUT/server.sh" && ok "server: library program mode is off (TN_K3S_CA_NO_MAIN=1)" || bad "server: TN_K3S_CA_NO_MAIN=1 missing"
# order: guard, library, call, installer
g=$(grep -n '^TN_K3S_CA_NO_MAIN=1' "$OUT/server.sh" | head -1 | cut -d: -f1)
l=$(grep -n '^tn_k3s_ca_setup()' "$OUT/server.sh" | head -1 | cut -d: -f1)
c=$(grep -n '^tn_k3s_ca_setup$' "$OUT/server.sh" | head -1 | cut -d: -f1)
i=$(grep -n 'k3s_installer.sh' "$OUT/server.sh" | head -1 | cut -d: -f1)
if [ -n "$g" ] && [ -n "$l" ] && [ -n "$c" ] && [ -n "$i" ] && [ "$g" -lt "$l" ] && [ "$l" -lt "$c" ] && [ "$c" -lt "$i" ]; then
  ok "server: guard < library < tn_k3s_ca_setup < k3s installer"
else bad "server: wrong order (guard=$g lib=$l call=$c installer=$i)"; fi
if grep -qF 'cp ${CONFIG_PATH}/rsa_public.pem ${DATA_DIR}/server/tls/root-ca.pem' "$OUT/server.sh"; then
  bad "server: still copies rsa_public.pem verbatim to root-ca.pem"
else ok "server: no verbatim rsa_public.pem -> root-ca.pem copy"; fi
# the agent trusts the device certificate in the OS store (update-ca-certificates) but creates no CA
if grep -q 'server/tls\|root-ca' "$OUT/agent.sh"; then bad "agent: prepares a server CA"; else ok "agent: no server CA preparation"; fi

# the k3s pin: the same default in both scripts, set before the installer runs, overridable, "stable" unsets it
for f in server agent; do
  grep -q '^TN_K3S_VERSION="${INSTALL_K3S_VERSION:-v1.36.5+k3s1}"$' "$OUT/$f.sh" && ok "$f: k3s pinned to v1.36.5+k3s1 by default, INSTALL_K3S_VERSION overrides" || bad "$f: default k3s pin missing"
  v=$(grep -n '^    export INSTALL_K3S_VERSION="${TN_K3S_VERSION}"$' "$OUT/$f.sh" | head -1 | cut -d: -f1)
  i=$(grep -n '^\$SUDO ./k3s_installer.sh' "$OUT/$f.sh" | head -1 | cut -d: -f1)
  if [ -n "$v" ] && [ -n "$i" ] && [ "$v" -lt "$i" ]; then ok "$f: the pin is exported before the installer runs"; else bad "$f: pin (line ${v:-none}) not before the installer (line ${i:-none})"; fi
  grep -q 'TN_K3S_VERSION}" = stable' "$OUT/$f.sh" && ok "$f: 'stable' unsets the pin" || bad "$f: no way back to the stable channel"
done
# a real run of the pin logic with a fake installer environment: default, override, stable
for want in "|v1.36.5+k3s1" "INSTALL_K3S_VERSION=v1.34.11+k3s1|v1.34.11+k3s1" "INSTALL_K3S_VERSION=stable|"; do
  envs=${want%%|*}; exp=${want#*|}
  got=$(env $envs sh -c '. "$1"; info() { :; }
    if [ "${TN_K3S_VERSION}" = stable ]; then unset INSTALL_K3S_VERSION; else export INSTALL_K3S_VERSION="${TN_K3S_VERSION}"; fi
    echo "${INSTALL_K3S_VERSION:-}"' sh "$ROOT/templates/00_tn_header.sh" 2>/dev/null | tail -1)
  [ "$got" = "$exp" ] && ok "pin logic: ${envs:-default} -> '${got}'" || bad "pin logic: ${envs:-default} gave '$got', want '$exp'"
done
# the dead "data-dir: /opt/k3s" line (and `mkdir -p /opt/k3s`) is gone, and the CA step is announced once
if grep -Eq '^(data-dir: /opt/k3s|mkdir -p /opt/k3s)' "$OUT/server.sh"; then bad "server: still writes data-dir /opt/k3s or creates /opt/k3s"; else ok "server: no dead /opt/k3s data-dir line"; fi
n=$(grep -c 'info "Prepare K3s CA Certs"' "$OUT/server.sh" || true)
[ "$n" = 1 ] && ok "server: 'Prepare K3s CA Certs' appears once" || bad "server: 'Prepare K3s CA Certs' appears $n times"
grep -q '\${DATA_DIR}/server/manifests' "$OUT/server.sh" && ok "server: manifests go to the resolved DATA_DIR" || bad "server: manifests path is not DATA_DIR"

# The assembled library must be the vendored file, unmodified (.sh files are cat'ed raw, no eval).
if python3 - "$ROOT/templates/04_tn_k3s_ca_lib.sh" "$OUT/server.sh" <<'PY'
import sys
lib = open(sys.argv[1], 'rb').read()
out = open(sys.argv[2], 'rb').read()
sys.exit(0 if lib in out else 1)
PY
then ok "server: vendored library embedded byte-for-byte"; else bad "server: vendored library not embedded byte-for-byte"; fi

[ "$fail" = 0 ] && echo "assembly checks passed" || { echo "assembly checks FAILED" >&2; exit 1; }
