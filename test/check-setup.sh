#!/bin/bash
# Offline smoke test of the vendored k3s CA library (templates/04_tn_k3s_ca_lib.sh) under dash,
# with the shell options of the bootstrap script (set -e, noglob, umask 027):
#   - a device certificate without keyCertSign (what Backstage generated) becomes a proper root
#   - the device files are not modified, every bundle verifies through a root-only trust store
#   - a second run keeps the PKI; on an initialised data dir nothing is touched
#   - the re-issued root has a new serial (OpenSSL 1.1.1 ignores -set_serial in `x509 -signkey`)
#   - a failing openssl step makes the setup fail and leaves no server/tls behind (errexit is
#     ignored in the callers' if/|| context)
#   - the data dir is found like k3s finds it (config.yaml, config.yaml.d, ExecStart of the unit)
#   - an initialised data dir with a foreign CA that k3s refuses stops the setup ("must not be upgraded")
#   - an activating unit is stopped before a regeneration; a ready k3s with an uninitialised data dir stops
#     the setup; a lost write in the bundle rebuild stops before rotate-ca; a hanging restart is bounded;
#     leftover .tn-tls-* work dirs are removed
#   - the install library (templates/04_tn_k3s_install_lib.sh): the installed k3s is kept, upgrade over
#     two minors and any downgrade are refused, the cgroup v1 kubelet flag, config.yaml merge
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

# the data dir is resolved like k3s does when DATA_DIR is not given: config.yaml, then a conf.d file,
# then --data-dir of the unit; setup creates the PKI there
for src in config conf-d unit; do
  rm -rf "$W/data" "$W/rancher" "$W/resolved"; mkdir -p "$W/data" "$W/rancher/config.yaml.d"
  case $src in
    config) echo "data-dir: $W/resolved" > "$W/rancher/config.yaml" ;;
    conf-d) echo "data-dir: $W/never" > "$W/rancher/config.yaml"; echo "data-dir: $W/resolved" > "$W/rancher/config.yaml.d/10-data.yaml" ;;
    unit) echo "data-dir: $W/never" > "$W/rancher/config.yaml"
          printf '[Service]\nExecStart=/usr/local/bin/k3s \\\n    server \\\n\t%s \\\n\t%s\n' "'--data-dir'" "'$W/resolved'" > "$W/k3s.service" ;;
  esac
  : > "$W/k3s.service.none"
  if dash -c "set -e; set -o noglob; umask 027
    info() { echo '[INFO] ' \"\$@\"; }; warn() { echo '[WARN] ' \"\$@\" >&2; }; fatal() { echo '[ERROR] ' \"\$@\" >&2; exit 1; }
    CONFIG_PATH=$W/etc PRODUCT=k3s _DEVICE_ID=dev1 _DOMAIN=test.local TN_K3S_CONFIG_DIR=$W/rancher
    TN_K3S_UNIT_FILE=$W/k3s.service
    export CONFIG_PATH PRODUCT _DEVICE_ID _DOMAIN TN_K3S_CONFIG_DIR TN_K3S_UNIT_FILE
    [ -f \"\$TN_K3S_UNIT_FILE\" ] || TN_K3S_UNIT_FILE=$W/no-unit
    TN_K3S_CA_NO_MAIN=1
    . '$LIB'
    tn_k3s_ca_setup" >"$W/out.log" 2>&1 && [ -s "$W/resolved/server/tls/server-ca.crt" ] && [ ! -e "$W/never" ]; then
    ok "data dir resolved from the $src source"
  else bad "data dir not resolved from the $src source"; cat "$W/out.log" >&2; fi
done
rm -rf "$W/data" "$W/rancher" "$W/resolved" "$W/k3s.service"; mkdir -p "$W/data"

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

# ---------------------------------------------------------------- final-review cases (all under dash)
# drun ENV... -- SCRIPT: the CA library and the install library sourced under the bootstrap script options
INSTLIB="$ROOT/templates/04_tn_k3s_install_lib.sh"
drun() {
  _env=""; while [ "$1" != -- ]; do _env="$_env $1"; shift; done; shift
  env $_env dash -c "set -e; set -o noglob; umask 027
    info() { echo '[INFO] ' \"\$@\"; }; warn() { echo '[WARN] ' \"\$@\" >&2; }; fatal() { echo '[ERROR] ' \"\$@\" >&2; exit 1; }
    TN_K3S_CA_NO_MAIN=1
    . '$LIB'; . '$INSTLIB'
    $1" >"$W/out.log" 2>&1
}
fresh_legacy() { # a legacy (old root) PKI; INIT=1 adds the token
  rm -rf "$W/data"; rm -f "$W/fake/log"; mkdir -p "$W/data/server/tls" "$W/fake"
  dash -c ". '$ROOT/test/k3s-ca/shim.sh'; . '$ROOT/test/k3s-ca/legacy-ca.sh'; PRODUCT=k3s; export PRODUCT; tn_legacy_ca '$W/data/server/tls' '$W/etc/rsa_public.pem' '$W/etc/rsa_private.pem' dev1.test.local" >/dev/null 2>&1
  [ "${1:-0}" != 1 ] || echo "K10x::server:y" > "$W/data/server/token"
}
mkfake_systemctl() { # STATE RESTART_SLEEP
  printf '#!/bin/sh\necho "$*" >> "%s/fake/log"\ncase "$1" in\n is-active) echo %s; [ %s = active ] ;;\n stop|start) ;;\n restart) sleep %s ;;\n cat) exit 0 ;;\nesac\n' "$W" "$1" "$1" "${2:-0}" > "$W/fake/systemctl"
  chmod 755 "$W/fake/systemctl"
  printf '[Service]\nExecStart=/usr/local/bin/k3s server\n' > "$W/fake/k3s.service"
}
UNITENV="TN_K3S_UNIT_FILE=$W/fake/k3s.service TN_K3S_CONFIG_DIR=$W/rancher CONFIG_PATH=$W/etc DATA_DIR=$W/data PRODUCT=k3s _DEVICE_ID=dev1 _DOMAIN=test.local"

# an activating unit is stopped (and started again) when the PKI of a hung first start is replaced
fresh_legacy 0; mkfake_systemctl activating
if drun $UNITENV "PATH=$W/fake:$PATH" -- tn_k3s_ca_setup && grep -q '^stop k3s.service' "$W/fake/log" && grep -q '^start k3s.service' "$W/fake/log"; then
  ok "an activating unit is stopped before the regeneration and started again"
else bad "activating unit not stopped"; cat "$W/out.log" >&2; fi

# k3s up and READY, but the resolved data dir was never initialised: k3s uses another one
fresh_legacy 0; mkfake_systemctl active
before=$(sha256sum "$W/data/server/tls/root-ca.pem")
if drun $UNITENV "PATH=$W/fake:$PATH" -- tn_k3s_ca_setup; then bad "setup went on with a ready k3s on an uninitialised data dir"
else
  grep -q 'another data dir' "$W/out.log" && [ "$before" = "$(sha256sum "$W/data/server/tls/root-ca.pem")" ] && ok "a ready k3s with an uninitialised data dir stops the setup, nothing changed" || bad "wrong stop"
fi

# the rebuilt bundles are checked: a silently lost write stops before rotate-ca
printf '#!/bin/sh\necho "$*" >> "%s/fake/k3s.calls"\nif [ "$1" = --version ]; then echo "k3s version v1.34.11+k3s1 (x)"; fi\nexit 0\n' "$W" > "$W/fake/k3s"; chmod 755 "$W/fake/k3s"
printf '#!/bin/sh\ncase "$*" in *newroot.pem*) n=$(/bin/cat %s/fake/n 2>/dev/null || echo 0); n=$((n+1)); echo $n > %s/fake/n; [ $n = 3 ] && exit 0 ;; esac\nexec /bin/cat "$@"\n' "$W" "$W" > "$W/fake/cat"; chmod 755 "$W/fake/cat"
fresh_legacy 1; mkfake_systemctl inactive
rm -f "$W/fake/k3s.calls"
if drun $UNITENV "PATH=$W/fake:$PATH" K3S_BIN="$W/fake/k3s" -- 'tn_ca_remediate prepare'; then bad "prepare went on after a lost write"
else
  grep -q 'certificates, the original 3' "$W/out.log" && ! grep -q rotate-ca "$W/fake/k3s.calls" 2>/dev/null && ! ls "$W"/data/server/.tn-ca-rotate-* >/dev/null 2>&1 && ok "a lost write in the bundle rebuild stops before rotate-ca, no staging left" || { bad "bundle rebuild not verified"; cat "$W/out.log" >&2; }
fi
rm -f "$W/fake/cat" "$W/fake/n"

# a restart that hangs is bounded and reported as "CA changed, k3s not restarted"
fresh_legacy 1; mkfake_systemctl active 20
t0=$(date +%s)
if drun $UNITENV "PATH=$W/fake:$PATH" K3S_BIN="$W/fake/k3s" TN_K3S_SERVICE_TIMEOUT=1 -- 'tn_ca_remediate all'; then bad "hanging restart reported as success"
else
  t1=$(date +%s)
  grep -q 'did not finish within 1s' "$W/out.log" && grep -q 'could not be restarted' "$W/out.log" && [ $((t1 - t0)) -lt 15 ] && ok "a hanging restart is bounded and reported" || { bad "restart not bounded"; cat "$W/out.log" >&2; }
fi

# leftover work dirs of an interrupted regeneration (they hold keys) go once the CA is ok
fresh_legacy 0
drun $UNITENV -- tn_k3s_ca_setup >/dev/null 2>&1 || true
echo "K10x::server:y" > "$W/data/server/token"
mkdir -p "$W/data/server/.tn-tls-old.20200101T000000.1" "$W/data/server/.tn-tls-new.AbCdEf"
echo x > "$W/data/server/.tn-tls-old.20200101T000000.1/root-ca.key"; echo x > "$W/data/server/.tn-tls-new.AbCdEf/root-ca.key"
if drun $UNITENV -- tn_k3s_ca_setup && [ ! -e "$W/data/server/.tn-tls-old.20200101T000000.1" ] && [ ! -e "$W/data/server/.tn-tls-new.AbCdEf" ]; then
  ok "leftover .tn-tls-old.* and .tn-tls-new.* dirs are removed when the CA is ok"
else bad "leftover regeneration dirs kept"; cat "$W/out.log" >&2; fi
rm -rf "$W/fake" "$W/data"; mkdir -p "$W/data"

# ---- the install library: release policy, cgroup v1 flag, config.yaml
mkdir -p "$W/fake"
ik3s() { printf '#!/bin/sh\necho "k3s version %s (0123abcd)"\n' "$1" > "$W/fake/k3s"; chmod 755 "$W/fake/k3s"; }
IENV="K3S_BIN=$W/fake/k3s TN_K3S_CONFIG_DIR=$W/icfg TN_CGROUP_FSTYPE=cgroup2fs"
ip() { # PIN [ENV...] -- prints "version=.. action=.." or fails
  _pin=$1; shift
  drun $IENV INSTALL_K3S_VERSION="$_pin" "$@" -- 'tn_inst_plan; echo "RESULT $INSTALL_K3S_VERSION $TN_INST_ACTION"'
}
ik3s v1.34.11+k3s1
ip v1.36.5+k3s1 && grep -q 'RESULT v1.34.11+k3s1 keep' "$W/out.log" && ok "installed k3s is kept, the pin is not applied" || { bad "installed k3s not kept"; cat "$W/out.log" >&2; }
ip v1.36.5+k3s1 TN_K3S_UPGRADE=true && bad "upgrade over two minors allowed" || { grep -q 'more than one minor version' "$W/out.log" && ok "an upgrade over two minors is refused" || bad "no refusal text"; }
ip v1.36.5+k3s1 TN_K3S_UPGRADE=true TN_K3S_FORCE=true && grep -q 'RESULT v1.36.5+k3s1 upgrade' "$W/out.log" && ok "TN_K3S_FORCE=true allows it with a warning" || bad "force did not allow the jump"
ip v1.35.9+k3s1 TN_K3S_UPGRADE=true && grep -q 'RESULT v1.35.9+k3s1 upgrade' "$W/out.log" && ok "an upgrade of one minor is allowed" || bad "one-minor upgrade refused"
ik3s v1.37.1+k3s1
ip v1.36.5+k3s1 TN_K3S_UPGRADE=true TN_K3S_FORCE=true && bad "downgrade allowed" || { grep -q 'refusing to downgrade' "$W/out.log" && ok "a downgrade is refused, also with force" || bad "no downgrade text"; }
rm -f "$W/fake/k3s"
ip v1.36.5+k3s1 && grep -q 'RESULT v1.36.5+k3s1 install' "$W/out.log" && ok "a device without k3s gets the pin" || bad "fresh device"

# cgroup v1: the kubelet flag in a drop-in that keeps the owner's kubelet-arg, idempotent, gone on v2
rm -rf "$W/icfg"; mkdir -p "$W/icfg"; printf 'kubelet-arg:\n  - max-pods=77\n' > "$W/icfg/config.yaml"
CG="K3S_BIN=$W/fake/none TN_K3S_CONFIG_DIR=$W/icfg INSTALL_K3S_VERSION=v1.36.5+k3s1"
D="$W/icfg/config.yaml.d/99-teknoir-cgroupv1.yaml"
drun $CG TN_CGROUP_FSTYPE=tmpfs -- tn_inst_prepare server && grep -q '^kubelet-arg+:' "$D" && grep -q '"fail-cgroupv1=false"' "$D" && grep -q 'cgroup v1 is deprecated' "$W/out.log" && ok "cgroup v1 + k3s 1.36: drop-in written, deprecation warned" || { bad "no cgroup v1 drop-in"; cat "$W/out.log" >&2; }
sum1=$(sha256sum "$D"); drun $CG TN_CGROUP_FSTYPE=tmpfs -- tn_inst_prepare server; [ "$sum1" = "$(sha256sum "$D")" ] && grep -q 'already in place' "$W/out.log" && ok "cgroup drop-in is idempotent" || bad "cgroup drop-in not idempotent"
[ "$(cat "$W/icfg/config.yaml")" = "kubelet-arg:
  - max-pods=77" ] && ok "the owner's config.yaml (kubelet-arg) is untouched" || bad "config.yaml changed"
drun $CG TN_CGROUP_FSTYPE=cgroup2fs -- tn_inst_prepare server && [ ! -e "$D" ] && ok "cgroup v2: drop-in removed" || bad "drop-in kept on cgroup v2"
rm -f "$D"; drun K3S_BIN="$W/fake/none" TN_K3S_CONFIG_DIR="$W/icfg" INSTALL_K3S_VERSION=v1.34.11+k3s1 TN_CGROUP_FSTYPE=tmpfs -- tn_inst_prepare agent && [ ! -e "$D" ] && ok "cgroup v1 + k3s 1.34: no flag (not needed)" || bad "flag written for k3s 1.34"
drun $CG OS_BUILD=true TN_CGROUP_FSTYPE=cgroup2fs -- tn_inst_prepare server && [ -s "$D" ] && ok "OS build (cgroup cannot be told): flag set" || bad "OS build"

# config.yaml is merged, not replaced
printf 'node-name: mine\n# kept' > "$W/icfg/config.yaml"
drun TN_K3S_CONFIG_DIR="$W/icfg" -- 'tn_inst_config_ensure "$TN_K3S_CONFIG_DIR/config.yaml" node-name "node-name: x"; tn_inst_config_ensure "$TN_K3S_CONFIG_DIR/config.yaml" data-dir "data-dir: /opt/k3s"; tn_inst_config_ensure "$TN_K3S_CONFIG_DIR/config.yaml" data-dir "data-dir: /opt/k3s"'
[ "$(cat "$W/icfg/config.yaml")" = "node-name: mine
# kept
data-dir: /opt/k3s" ] && ok "config.yaml: existing keys kept, missing key added once" || { bad "config.yaml merge"; cat "$W/icfg/config.yaml" >&2; }

[ "$fail" = 0 ] && echo "setup smoke test passed" || { echo "setup smoke test FAILED" >&2; exit 1; }
