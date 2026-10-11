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

# the k3s install library (release policy + cgroup v1 flag + config.yaml) in both scripts, used before the installer
for f in server agent; do
  grep -q '^tn_inst_prepare()' "$OUT/$f.sh" && ok "$f: embeds the install library" || bad "$f: install library not embedded"
  grep -q "^tn_inst_prepare $f\$" "$OUT/$f.sh" && ok "$f: calls tn_inst_prepare $f" || bad "$f: tn_inst_prepare $f call missing"
  l=$(grep -n '^tn_inst_prepare()' "$OUT/$f.sh" | head -1 | cut -d: -f1)
  c=$(grep -n "^tn_inst_prepare $f\$" "$OUT/$f.sh" | head -1 | cut -d: -f1)
  v=$(grep -n '^    export INSTALL_K3S_VERSION="${TN_K3S_VERSION}"$' "$OUT/$f.sh" | head -1 | cut -d: -f1)
  i=$(grep -n '^\$SUDO ./k3s_installer.sh' "$OUT/$f.sh" | head -1 | cut -d: -f1)
  if [ -n "$l" ] && [ -n "$c" ] && [ -n "$v" ] && [ -n "$i" ] && [ "$l" -lt "$v" ] && [ "$v" -lt "$c" ] && [ "$c" -lt "$i" ]; then
    ok "$f: library < pin < tn_inst_prepare < k3s installer"
  else bad "$f: wrong order (lib=$l pin=$v call=$c installer=$i)"; fi
  if python3 - "$ROOT/$([ $f = server ] && echo templates/04_tn_k3s_install_lib.sh || echo agent_templates/02_tn_k3s_install_lib.sh)" "$OUT/$f.sh" <<'PY'
import sys
lib = open(sys.argv[1], 'rb').read()
out = open(sys.argv[2], 'rb').read()
sys.exit(0 if lib in out else 1)
PY
  then ok "$f: vendored install library embedded byte-for-byte"; else bad "$f: vendored install library not embedded byte-for-byte"; fi
done
# the server no longer replaces an existing config.yaml
if grep -q 'tee \${K3S_CONFIG_PATH}/config.yaml' "$OUT/server.sh"; then bad "server: still overwrites config.yaml"; else ok "server: config.yaml is not overwritten"; fi
grep -q 'tn_inst_config_ensure ${K3S_CONFIG_PATH}/config.yaml node-name' "$OUT/server.sh" && ok "server: node-name through tn_inst_config_ensure" || bad "server: tn_inst_config_ensure missing"

# server order: release policy + cgroup flag, then the CA step, then the installer, then the publication
pl=$(grep -n '^tn_inst_prepare server$' "$OUT/server.sh" | head -1 | cut -d: -f1)
rd=$(grep -n '^tn_ca_resolve_datadir$' "$OUT/server.sh" | head -1 | cut -d: -f1)
gd=$(grep -n '^tn_ca_require_consistent_datadir$' "$OUT/server.sh" | head -1 | cut -d: -f1)
ex=$(grep -n '^export INSTALL_K3S_EXEC="server' "$OUT/server.sh" | head -1 | cut -d: -f1)
ca=$(grep -n '^tn_k3s_ca_setup$' "$OUT/server.sh" | head -1 | cut -d: -f1)
ins=$(grep -n '^\$SUDO ./k3s_installer.sh' "$OUT/server.sh" | head -1 | cut -d: -f1)
pub=$(grep -n '^tn_inst_publish_release$' "$OUT/server.sh" | head -1 | cut -d: -f1)
if [ -n "$rd" ] && [ -n "$pl" ] && [ -n "$ca" ] && [ -n "$ins" ] && [ -n "$pub" ] && [ "$rd" -lt "$pl" ] && [ "$pl" -lt "$ca" ] && [ "$ca" -lt "$ins" ] && [ "$ins" -lt "$pub" ]; then
  ok "server: resolve data dir < tn_inst_prepare < tn_k3s_ca_setup < installer < tn_inst_publish_release"
else bad "server: wrong order (datadir=$rd prepare=$pl ca=$ca installer=$ins publish=$pub)"; fi
if [ "$(grep -c '^tn_inst_prepare server$' "$OUT/server.sh")" = 1 ]; then ok "server: tn_inst_prepare is called once"; else bad "server: tn_inst_prepare is called more than once"; fi
# INSTALL_K3S_EXEC is final before tn_inst_prepare reads it (a fail-cgroupv1 of the caller must reach the installer),
# built once, keeps the caller's value, and the data dir guard runs before tn_inst_prepare changes anything
if [ -n "$ex" ] && [ -n "$rd" ] && [ -n "$gd" ] && [ -n "$pl" ] && [ "$ex" -lt "$rd" ] && [ "$rd" -lt "$gd" ] && [ "$gd" -lt "$pl" ]; then
  ok "server: INSTALL_K3S_EXEC < resolve data dir < data dir guard < tn_inst_prepare"
else bad "server: wrong order (exec=$ex datadir=$rd guard=$gd prepare=$pl)"; fi
[ "$(grep -c '^ *export INSTALL_K3S_EXEC="server' "$OUT/server.sh")" = 1 ] && ok "server: INSTALL_K3S_EXEC is built once" || bad "server: INSTALL_K3S_EXEC is built more than once"
grep -q '^export INSTALL_K3S_EXEC="server .*10\.0\.0\.10${INSTALL_K3S_EXEC:+ ${INSTALL_K3S_EXEC}}"$' "$OUT/server.sh" && ok "server: the caller's INSTALL_K3S_EXEC is kept" || bad "server: INSTALL_K3S_EXEC of the caller is dropped"
grep -q '^tn_ca_require_consistent_datadir()' "$OUT/server.sh" && ok "server: embeds the data dir guard" || bad "server: data dir guard not embedded"
grep -q '^tn_inst_publish_release$' "$OUT/agent.sh" && bad "agent: publishes a release" || ok "agent: does not publish a release"
# who chose the k3s release (an agent follows its server unless a release was asked for)
for f in server agent; do
  hdr=$([ $f = server ] && echo templates/00_tn_header.sh || echo agent_templates/00_tn_header.sh)
  grep -q '^export TN_K3S_PIN_SOURCE$' "$OUT/$f.sh" && ok "$f: records TN_K3S_PIN_SOURCE" || bad "$f: TN_K3S_PIN_SOURCE missing"
  for want in "|default" "INSTALL_K3S_VERSION=v1.34.11+k3s1|env"; do
    envs=${want%%|*}; exp=${want#*|}
    # (only the pin lines: the agent header insists on root)
    sed -n '/^if \[ -n "${INSTALL_K3S_VERSION:-}" \]; then TN_K3S_PIN_SOURCE/,/^export TN_K3S_PIN_SOURCE/p' "$ROOT/$hdr" > "$OUT/pin.sh"
    got=$(env -u INSTALL_K3S_VERSION $envs sh -c '. "$1"; echo "$TN_K3S_PIN_SOURCE"' sh "$OUT/pin.sh" 2>/dev/null | tail -1)
    [ "$got" = "$exp" ] && ok "$f: pin source ${envs:-default} -> $got" || bad "$f: pin source ${envs:-default} gave '$got', want '$exp'"
  done
done
# the agent has K3S_URL before it asks the server
k=$(grep -n '^export K3S_URL=${K3S_URL}$' "$OUT/agent.sh" | head -1 | cut -d: -f1)
pa=$(grep -n '^tn_inst_prepare agent$' "$OUT/agent.sh" | head -1 | cut -d: -f1)
if [ -n "$k" ] && [ -n "$pa" ] && [ "$k" -lt "$pa" ]; then ok "agent: K3S_URL is set before tn_inst_prepare agent"; else bad "agent: K3S_URL (line ${k:-none}) not before tn_inst_prepare agent (line ${pa:-none})"; fi

# The assembled library must be the vendored file, unmodified (.sh files are cat'ed raw, no eval).
if python3 - "$ROOT/templates/04_tn_k3s_ca_lib.sh" "$OUT/server.sh" <<'PY'
import sys
lib = open(sys.argv[1], 'rb').read()
out = open(sys.argv[2], 'rb').read()
sys.exit(0 if lib in out else 1)
PY
then ok "server: vendored library embedded byte-for-byte"; else bad "server: vendored library not embedded byte-for-byte"; fi

[ "$fail" = 0 ] && echo "assembly checks passed" || { echo "assembly checks FAILED" >&2; exit 1; }
