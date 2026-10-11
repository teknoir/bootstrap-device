#!/bin/bash
# Offline smoke test of the vendored k3s CA library (templates/04_tn_k3s_ca_lib.sh) under dash,
# with the shell options of the bootstrap script (set -e, noglob, umask 027):
#   - a device certificate without keyCertSign (what Backstage generated) becomes a proper root
#   - the device files are not modified, every bundle verifies through a root-only trust store
#   - a second run keeps the PKI; on an initialised data dir nothing is touched
#   - the re-issued root has a new serial (OpenSSL 1.1.1 ignores -set_serial in `x509 -signkey`)
#   - a failing openssl step makes the setup fail and leaves no server/tls behind (errexit is
#     ignored in the callers' if/|| context)
#   - an initialised data dir with a foreign CA that k3s refuses stops the setup ("must not be upgraded")
# The docker matrix against real k3s releases is test/k3s-ca/run.sh (see docs/development.md).
# Usage: test/check-setup.sh
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/templates/04_tn_k3s_ca_lib.sh"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/etc" "$W/data"
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok:   $*"; }

openssl req -x509 -nodes -newkey rsa:2048 -keyout "$W/etc/rsa_private.pem" -out "$W/etc/rsa_public.pem" \
  -days 365 -subj "/C=US/CN=teknoir.ai" -sha256 -batch 2>/dev/null
openssl x509 -in "$W/etc/rsa_public.pem" -noout -text | grep -q 'Certificate Sign' && bad "fixture cert unexpectedly has keyCertSign"
pub0=$(sha256sum "$W/etc/rsa_public.pem" | cut -d' ' -f1)

run() {
  dash -c "set -e; set -o noglob; umask 027
    info() { echo '[INFO] ' \"\$@\"; }; warn() { echo '[WARN] ' \"\$@\" >&2; }; fatal() { echo '[ERROR] ' \"\$@\" >&2; exit 1; }
    CONFIG_PATH=$W/etc DATA_DIR=$W/data PRODUCT=k3s _DEVICE_ID=dev1 _DOMAIN=test.local
    export CONFIG_PATH DATA_DIR PRODUCT _DEVICE_ID _DOMAIN
    TN_K3S_CA_NO_MAIN=1
    . '$LIB'
    $1" >"$W/out.log" 2>&1
}

run tn_k3s_ca_setup && ok "setup" || { bad "setup failed"; cat "$W/out.log" >&2; }
T="$W/data/server/tls"
openssl x509 -in "$T/root-ca.pem" -noout -text | grep -q 'Certificate Sign' && ok "root has keyCertSign" || bad "root has no keyCertSign"
openssl x509 -in "$T/root-ca.pem" -noout -text | grep -q 'CA:TRUE' && ok "root is CA:TRUE" || bad "root is not CA:TRUE"
for b in server-ca client-ca request-header-ca etcd/peer-ca etcd/server-ca; do
  if openssl verify -CAfile "$T/root-ca.pem" -untrusted "$T/intermediate-ca.pem" "$T/$b.pem" >/dev/null 2>&1; then ok "$b verifies"; else bad "$b does not verify"; fi
done
[ "$(sha256sum "$W/etc/rsa_public.pem" | cut -d' ' -f1)" = "$pub0" ] && ok "rsa_public.pem untouched" || bad "rsa_public.pem modified"

d1=$(cd "$T" && find . -type f | sort | xargs sha256sum | sha256sum)
run tn_k3s_ca_setup && ok "second setup" || bad "second setup failed"
d2=$(cd "$T" && find . -type f | sort | xargs sha256sum | sha256sum)
[ "$d1" = "$d2" ] && ok "second setup keeps the PKI" || bad "second setup changed the PKI"
echo "K10x::server:y" > "$W/data/server/token"
run tn_k3s_ca_setup && ok "setup on an initialised data dir" || bad "setup on an initialised data dir failed"
d3=$(cd "$T" && find . -type f | sort | xargs sha256sum | sha256sum)
[ "$d1" = "$d3" ] && ok "initialised data dir untouched" || bad "initialised data dir changed"

ser0=$(openssl x509 -in "$W/etc/rsa_public.pem" -noout -serial); ser1=$(openssl x509 -in "$T/root-ca.pem" -noout -serial)
[ "$ser0" != "$ser1" ] && ok "re-issued root has a new serial" || bad "re-issued root keeps the serial of the device certificate ($ser1)"

# a failing `openssl ca` must fail the setup and install nothing
REAL=$(command -v openssl)
mkdir -p "$W/fakebin"
printf '#!/bin/sh\n[ "$1" = ca ] && { echo "wrapper: openssl ca fails" >&2; exit 1; }\nexec %s "$@"\n' "$REAL" > "$W/fakebin/openssl"
chmod 755 "$W/fakebin/openssl"
rm -rf "$W/data"; mkdir -p "$W/data"
if PATH="$W/fakebin:$PATH" run tn_k3s_ca_setup; then bad "setup succeeded although openssl ca failed"; else ok "setup fails when openssl ca fails"; fi
[ ! -e "$W/data/server/tls/server-ca.crt" ] && ok "no partial server/tls installed" || bad "partial server/tls installed"

# a foreign CA (no key for it here) without keyCertSign, k3s already started: stop, do not upgrade
rm -rf "$W/data"; mkdir -p "$W/data/server/tls"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$W/other.key" -out "$W/other.pem" -days 365 -subj "/CN=other" -batch 2>/dev/null
cat "$W/other.pem" "$W/other.pem" > "$W/data/server/tls/server-ca.crt"
echo "K10x::server:y" > "$W/data/server/token"
if run tn_k3s_ca_setup; then bad "setup continued on an unusable foreign CA"; else
  grep -q 'must not be upgraded' "$W/out.log" && ok "setup stops on an unusable foreign CA" || bad "no stop message for the foreign CA"
fi

[ "$fail" = 0 ] && echo "setup smoke test passed" || { echo "setup smoke test FAILED" >&2; exit 1; }
