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
#     two minors and any downgrade are refused, the cgroup v1 kubelet flag (from k3s v1.31, atomic),
#     config.yaml merge
#   - an agent follows the k3s release of its server (published by the server script, read with curl), is
#     refused when it would be newer, and stops when the server is unknown; a k3s whose version cannot be
#     read is not installed over; the kubelet flag is in place before the CA step restarts k3s; a slow
#     restart gets its grace; rotate-ca is tried again while the unit starts; a data dir that disagrees
#     with config.yaml stops the setup; a refusal says what this run changed
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
    unit) echo "node-name: mine" > "$W/rancher/config.yaml"
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
  _env=(); while [ "$1" != -- ]; do _env+=("$1"); shift; done; shift
  env "${_env[@]}" dash -c "set -e; set -o noglob; umask 027
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
fresh_legacy 1; mkfake_systemctl activating 20
t0=$(date +%s)
if drun $UNITENV "PATH=$W/fake:$PATH" K3S_BIN="$W/fake/k3s" TN_K3S_SERVICE_TIMEOUT=1 TN_K3S_READY_GRACE=1 TN_K3S_READY_POLL=1 -- 'tn_ca_remediate all'; then bad "hanging restart reported as success"
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
IENV="K3S_BIN=$W/fake/k3s TN_K3S_CONFIG_DIR=$W/icfg TN_CGROUP_FSTYPE=cgroup2fs DATA_DIR=$W/idata"
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
CG="K3S_BIN=$W/fake/none TN_K3S_CONFIG_DIR=$W/icfg INSTALL_K3S_VERSION=v1.36.5+k3s1 DATA_DIR=$W/idata"
D="$W/icfg/config.yaml.d/99-teknoir-cgroupv1.yaml"
drun $CG TN_CGROUP_FSTYPE=tmpfs -- tn_inst_prepare server && grep -q '^kubelet-arg+:' "$D" && grep -q '"fail-cgroupv1=false"' "$D" && grep -q 'cgroup v1 is deprecated' "$W/out.log" && ok "cgroup v1 + k3s 1.36: drop-in written, deprecation warned" || { bad "no cgroup v1 drop-in"; cat "$W/out.log" >&2; }
sum1=$(sha256sum "$D"); drun $CG TN_CGROUP_FSTYPE=tmpfs -- tn_inst_prepare server; [ "$sum1" = "$(sha256sum "$D")" ] && grep -q 'already in place' "$W/out.log" && ok "cgroup drop-in is idempotent" || bad "cgroup drop-in not idempotent"
[ "$(cat "$W/icfg/config.yaml")" = "kubelet-arg:
  - max-pods=77" ] && ok "the owner's config.yaml (kubelet-arg) is untouched" || bad "config.yaml changed"
drun $CG TN_CGROUP_FSTYPE=cgroup2fs -- tn_inst_prepare server && [ ! -e "$D" ] && ok "cgroup v2: drop-in removed" || bad "drop-in kept on cgroup v2"
rm -f "$D"; drun K3S_BIN="$W/fake/none" TN_K3S_CONFIG_DIR="$W/icfg" DATA_DIR="$W/idata" INSTALL_K3S_VERSION=v1.34.11+k3s1 TN_K3S_PIN_SOURCE=env TN_CGROUP_FSTYPE=tmpfs -- tn_inst_prepare agent && [ -s "$D" ] && ok "cgroup v1 + k3s 1.34: flag set for a later upgrade (k3s >= v1.31)" || bad "no flag for k3s 1.34"
rm -f "$D"; drun K3S_BIN="$W/fake/none" TN_K3S_CONFIG_DIR="$W/icfg" DATA_DIR="$W/idata" INSTALL_K3S_VERSION=v1.30.14+k3s1 TN_K3S_PIN_SOURCE=env TN_CGROUP_FSTYPE=tmpfs -- tn_inst_prepare agent && [ ! -e "$D" ] && ok "cgroup v1 + k3s 1.30: no flag (its kubelet does not know it)" || bad "flag written for k3s 1.30"
drun $CG OS_BUILD=true TN_CGROUP_FSTYPE=cgroup2fs -- tn_inst_prepare server && [ -s "$D" ] && ok "OS build (cgroup cannot be told): flag set" || bad "OS build"

# config.yaml is merged, not replaced
printf 'node-name: mine\n# kept' > "$W/icfg/config.yaml"
drun TN_K3S_CONFIG_DIR="$W/icfg" -- 'tn_inst_config_ensure "$TN_K3S_CONFIG_DIR/config.yaml" node-name "node-name: x"; tn_inst_config_ensure "$TN_K3S_CONFIG_DIR/config.yaml" data-dir "data-dir: /opt/k3s"; tn_inst_config_ensure "$TN_K3S_CONFIG_DIR/config.yaml" data-dir "data-dir: /opt/k3s"'
[ "$(cat "$W/icfg/config.yaml")" = "node-name: mine
# kept
data-dir: /opt/k3s" ] && ok "config.yaml: existing keys kept, missing key added once" || { bad "config.yaml merge"; cat "$W/icfg/config.yaml" >&2; }


# ---------------------------------------------------------------- follow-up review: agent, order, slow k3s, refusals
NOSVC="K3S_BIN=$W/fake/none TN_K3S_CONFIG_DIR=$W/fcfg DATA_DIR=$W/fdata TN_CGROUP_FSTYPE=cgroup2fs TN_K3S_SERVER_VERSION_WAIT=0"
mkdir -p "$W/fcfg" "$W/fake"
# a curl that answers like the supervisor of k3s: the published release (TN_TEST_PUBLISHED) at
# /static/teknoir/k3s-version, 404 (exit 22) for everything else, TN_TEST_DOWN: nothing answers
printf '#!/bin/sh\necho "$*" >> "%s/fake/curl.log"\nfor a in "$@"; do url=$a; done\n[ -z "$TN_TEST_DOWN" ] || exit 7\ncase "$url" in */static/teknoir/k3s-version) [ -z "$TN_TEST_PUBLISHED" ] || { echo "$TN_TEST_PUBLISHED"; exit 0; } ;; esac\nexit 22\n' "$W" > "$W/fake/curl"
chmod 755 "$W/fake/curl"
follow() { # PIN SOURCE PUBLISHED [ENV...]: tn_inst_prepare agent, output in out.log, RESULT line
  _p=$1 _s=$2 _pub=$3; shift 3
  rm -f "$W/fake/curl.log"
  drun $NOSVC "PATH=$W/fake:$PATH" K3S_URL=https://srv:6443 INSTALL_K3S_VERSION="$_p" TN_K3S_PIN_SOURCE="$_s" TN_TEST_PUBLISHED="$_pub" "$@" -- 'tn_inst_prepare agent; echo "RESULT $INSTALL_K3S_VERSION $TN_INST_ACTION"'
}
follow v1.36.5+k3s1 default v1.34.11+k3s1 && grep -q 'RESULT v1.34.11+k3s1 install' "$W/out.log" && grep -q 'https://srv:6443/static/teknoir/k3s-version' "$W/fake/curl.log" && ok "agent: the default pin v1.36.5 is replaced by the release of the server (v1.34.11)" || { bad "agent does not follow the server"; cat "$W/out.log" >&2; }
follow v1.34.11+k3s1 default v1.36.5+k3s1 && grep -q 'RESULT v1.36.5+k3s1 install' "$W/out.log" && ok "agent: an older default pin is replaced by the release of the server (v1.36.5)" || bad "agent does not follow a newer server"
follow v1.36.5+k3s1 env v1.34.11+k3s1 && bad "agent: a release asked for that is newer than the server was installed" || { grep -q 'refusing to install k3s v1.36.5+k3s1 on this agent' "$W/out.log" && grep -q 'Nothing was changed' "$W/out.log" && ok "agent: a requested release newer than the server is refused" || bad "agent: no refusal text"; }
follow v1.36.5+k3s1 env v1.34.11+k3s1 TN_K3S_FORCE=true && grep -q 'RESULT v1.36.5+k3s1 install' "$W/out.log" && ok "agent: TN_K3S_FORCE=true installs the newer release with a warning" || bad "agent: force"
follow v1.33.4+k3s1 env v1.34.11+k3s1 && grep -q 'RESULT v1.33.4+k3s1 install' "$W/out.log" && ok "agent: a requested release older than the server is installed (warned)" || bad "agent: older request"
follow v1.36.5+k3s1 default "" && bad "agent: installed although the server publishes nothing" || { grep -q 'does not publish its release' "$W/out.log" && grep -q 'INSTALL_K3S_VERSION=v1.xx.y+k3sN' "$W/out.log" && ok "agent: a server that publishes nothing stops the script, with the way out" || bad "agent: wrong stop text"; }
follow v1.36.5+k3s1 default "" TN_TEST_DOWN=1 TN_K3S_SERVER_VERSION_TRIES=2 && bad "agent: installed although the server is down" || { grep -q 'Is the server up' "$W/out.log" && [ "$(wc -l < "$W/fake/curl.log")" = 2 ] && ok "agent: an unreachable server stops the script (2 tries)" || bad "agent: wrong text/tries for a down server"; }
follow v1.34.11+k3s1 env "" TN_TEST_DOWN=1 TN_K3S_SERVER_VERSION_TRIES=1 && grep -q 'RESULT v1.34.11+k3s1 install' "$W/out.log" && grep -q 'installed as asked' "$W/out.log" && ok "agent: an unknown server and a requested release: installed as asked" || bad "agent: requested release with unknown server"
follow v1.36.5+k3s1 default "" TN_TEST_DOWN=1 TN_K3S_SERVER_VERSION_TRIES=1 TN_K3S_FORCE=true && grep -q 'RESULT v1.36.5+k3s1 install' "$W/out.log" && ok "agent: TN_K3S_FORCE=true installs with an unknown server" || bad "agent: force with unknown server"
ik3s v1.34.11+k3s1
follow v1.36.5+k3s1 default v1.35.9+k3s1 K3S_BIN="$W/fake/k3s" && grep -q 'RESULT v1.34.11+k3s1 keep' "$W/out.log" && [ ! -e "$W/fake/curl.log" ] && ok "agent: an installed k3s is kept, the server is not asked" || bad "agent: installed k3s"
follow v1.36.5+k3s1 default v1.35.9+k3s1 K3S_BIN="$W/fake/k3s" TN_K3S_UPGRADE=true && grep -q 'RESULT v1.35.9+k3s1 upgrade' "$W/out.log" && ok "agent: an upgrade goes to the release of the server" || bad "agent: upgrade target"
rm -f "$W/fake/k3s"
# the cgroup flag follows the release that is installed (here the server's), not the pin
rm -rf "$W/fcfg"; mkdir -p "$W/fcfg"
follow v1.36.5+k3s1 default v1.30.14+k3s1 TN_CGROUP_FSTYPE=tmpfs && [ ! -e "$W/fcfg/config.yaml.d/99-teknoir-cgroupv1.yaml" ] && ok "agent: cgroup v1 and a v1.30 server: no flag although the default pin is v1.36" || bad "agent: flag for a v1.30 agent"
follow v1.30.14+k3s1 default v1.36.5+k3s1 TN_CGROUP_FSTYPE=tmpfs && [ -s "$W/fcfg/config.yaml.d/99-teknoir-cgroupv1.yaml" ] && ok "agent: cgroup v1 and a v1.36 server: flag set although the default pin is v1.30" || bad "agent: no flag for a v1.36 agent"
# the server publishes what it runs, the agent reads it back
ik3s v1.34.11+k3s1
drun $NOSVC K3S_BIN="$W/fake/k3s" DATA_DIR="$W/fdata" -- tn_inst_publish_release && [ "$(cat "$W/fdata/server/static/teknoir/k3s-version")" = v1.34.11+k3s1 ] && ok "server: publishes its release for the agents" || { bad "server: publish"; cat "$W/out.log" >&2; }
drun $NOSVC K3S_BIN="$W/fake/k3s" DATA_DIR="$W/fdata" -- tn_inst_publish_release && grep -q 'already published' "$W/out.log" && ok "server: publishing again changes nothing" || bad "server: publish is not idempotent"
rm -f "$W/fake/k3s"

# a k3s whose version cannot be read is not installed over
printf '#!/bin/sh\necho nonsense\n' > "$W/fake/k3s"; chmod 755 "$W/fake/k3s"
drun $NOSVC K3S_BIN="$W/fake/k3s" INSTALL_K3S_VERSION=v1.36.5+k3s1 -- 'tn_inst_prepare server' && bad "an unreadable k3s was installed over" || { grep -q 'version cannot be read' "$W/out.log" && grep -q 'TN_K3S_FORCE=true' "$W/out.log" && ok "a k3s binary whose version cannot be read: refused" || bad "unreadable k3s: wrong text"; }
drun $NOSVC K3S_BIN="$W/fake/k3s" INSTALL_K3S_VERSION=v1.36.5+k3s1 TN_K3S_FORCE=true -- 'tn_inst_prepare server' && ok "... and TN_K3S_FORCE=true goes on" || bad "unreadable k3s with force"
rm -f "$W/fake/k3s"; mkdir -p "$W/fdata/server/db"
drun $NOSVC INSTALL_K3S_VERSION=v1.36.5+k3s1 -- 'tn_inst_prepare server' && bad "a datastore without k3s was installed over" || { grep -q 'server/db' "$W/out.log" && ok "a datastore without a k3s binary: refused" || bad "datastore: wrong text"; }
rm -rf "$W/fdata"

# the refusal says what this run changed
ik3s v1.37.1+k3s1
drun $NOSVC K3S_BIN="$W/fake/k3s" INSTALL_K3S_VERSION=v1.36.5+k3s1 TN_K3S_UPGRADE=true TN_K3S_TEST=1 "TN_K3S_CA_CHANGED=the CA was rotated; k3s was restarted" -- 'tn_inst_prepare server' && bad "downgrade allowed" || { grep -q 'earlier in this run: the CA was rotated; k3s was restarted' "$W/out.log" && ! grep -q 'Nothing was changed' "$W/out.log" && ok "a refusal after a CA repair lists what was changed" || bad "refusal after a change"; }
rm -f "$W/fake/k3s"

# the kubelet flag is in place before the CA step restarts k3s (the server script order), also for rotate-ca
fresh_legacy 1
rm -rf "$W/fcfg"; mkdir -p "$W/fcfg"
printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "k3s version v1.36.5+k3s1 (x)"; exit 0; fi\nif [ -f "%s/fcfg/config.yaml.d/99-teknoir-cgroupv1.yaml" ]; then echo "rotate flag=yes" >> "%s/fake/order.log"; else echo "rotate flag=no" >> "%s/fake/order.log"; fi\nexit 0\n' "$W" "$W" "$W" > "$W/fake/k3s"; chmod 755 "$W/fake/k3s"
rm -f "$W/fake/order.log"
RESTART="if [ -f $W/fcfg/config.yaml.d/99-teknoir-cgroupv1.yaml ]; then echo 'restart flag=yes' >> $W/fake/order.log; else echo 'restart flag=no' >> $W/fake/order.log; fi"
drun $UNITENV TN_K3S_CONFIG_DIR="$W/fcfg" K3S_BIN="$W/fake/k3s" TN_CGROUP_FSTYPE=tmpfs INSTALL_K3S_VERSION=v1.36.5+k3s1 "TN_K3S_RESTART_CMD=$RESTART" -- 'tn_ca_resolve_datadir; tn_inst_prepare server; tn_k3s_ca_setup' && [ "$(sort "$W/fake/order.log" | tr '\n' ' ')" = "restart flag=yes rotate flag=yes " ] && ok "server order: the kubelet flag is in place when rotate-ca runs and when k3s is restarted" || { bad "flag not in place before the CA step"; cat "$W/out.log" "$W/fake/order.log" >&2; }
fresh_legacy 1; rm -rf "$W/fcfg"; mkdir -p "$W/fcfg"; rm -f "$W/fake/order.log"
drun $UNITENV TN_K3S_CONFIG_DIR="$W/fcfg" K3S_BIN="$W/fake/k3s" TN_CGROUP_FSTYPE=tmpfs INSTALL_K3S_VERSION=v1.36.5+k3s1 "TN_K3S_RESTART_CMD=$RESTART" -- 'tn_k3s_ca_setup; tn_inst_prepare server' && [ "$(sort "$W/fake/order.log" | tr '\n' ' ')" = "restart flag=no rotate flag=no " ] && ok "(the old order, CA first, does not have the flag: this is what the new order fixes)" || bad "the control order test is wrong"
rm -f "$W/fake/k3s"

# a slow restart: default timeout 600 s, a unit that gets there during the grace is a success, rotate-ca is tried again
drun $UNITENV -- 'echo "TIMEOUT=$(tn_ca_svc_timeout)"' && grep -q 'TIMEOUT=600' "$W/out.log" && ok "TN_K3S_SERVICE_TIMEOUT defaults to 600 s" || bad "service timeout default"
fresh_legacy 1
printf '#!/bin/sh\necho "$*" >> "%s/fake/log"\ncase "$1" in\n is-active) if [ -f "%s/fake/restarted" ] && [ $(( $(date +%%s) - $(cat "%s/fake/restarted") )) -lt 3 ]; then echo activating; exit 3; fi; echo active ;;\n restart) date +%%s > "%s/fake/restarted"; sleep 20 ;;\n cat) exit 0 ;;\nesac\n' "$W" "$W" "$W" "$W" > "$W/fake/systemctl"; chmod 755 "$W/fake/systemctl"
printf '[Service]\nExecStart=/usr/local/bin/k3s server\n' > "$W/fake/k3s.service"
printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "k3s version v1.34.11+k3s1 (x)"; fi\nexit 0\n' > "$W/fake/k3s"; chmod 755 "$W/fake/k3s"
rm -f "$W/fake/restarted"
drun $UNITENV "PATH=$W/fake:$PATH" K3S_BIN="$W/fake/k3s" TN_K3S_SERVICE_TIMEOUT=1 TN_K3S_READY_GRACE=20 TN_K3S_READY_POLL=1 -- 'tn_ca_remediate all' && grep -q 'k3s is active now' "$W/out.log" && ! grep -q 'could not be restarted' "$W/out.log" && ok "a restart that is slow but gets there during the grace is a success" || { bad "grace after a timeout"; cat "$W/out.log" >&2; }
fresh_legacy 1
printf '#!/bin/sh\ncase "$1" in\n is-active) echo activating; exit 3 ;;\n cat) exit 0 ;;\nesac\n' > "$W/fake/systemctl"; chmod 755 "$W/fake/systemctl"
printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "k3s version v1.34.11+k3s1 (x)"; exit 0; fi\necho x >> "%s/fake/rotate.calls"\nn=$(wc -l < "%s/fake/rotate.calls")\n[ "$n" -ge 3 ] || exit 1\nexit 0\n' "$W" "$W" > "$W/fake/k3s"; chmod 755 "$W/fake/k3s"
rm -f "$W/fake/rotate.calls"
drun $UNITENV "PATH=$W/fake:$PATH" K3S_BIN="$W/fake/k3s" TN_K3S_RESTART_CMD=true TN_K3S_ROTATE_TRIES=5 TN_K3S_ROTATE_WAIT=1 -- 'tn_ca_remediate all' && [ "$(wc -l < "$W/fake/rotate.calls")" = 3 ] && ok "rotate-ca is tried again while the unit is starting (3rd try works)" || { bad "rotate-ca retry"; cat "$W/out.log" >&2; }
rm -rf "$W/fake"; mkdir -p "$W/fake"

# a data dir that disagrees with config.yaml is refused before anything is changed
rm -rf "$W/data" "$W/dcfg"; mkdir -p "$W/dcfg"
printf 'data-dir: %s/other\n' "$W" > "$W/dcfg/config.yaml"
printf '[Service]\nExecStart=/usr/local/bin/k3s \\\n    server \\\n\t%s \\\n\t%s\n' "'--data-dir'" "'$W/data'" > "$W/dcfg.service"
drun TN_K3S_CONFIG_DIR="$W/dcfg" TN_K3S_UNIT_FILE="$W/dcfg.service" CONFIG_PATH="$W/etc" PRODUCT=k3s _DEVICE_ID=dev1 _DOMAIN=test.local DATA_DIR= -- tn_k3s_ca_setup && bad "a data dir that disagrees with config.yaml was accepted" || { grep -q "config.yaml sets data-dir: $W/other" "$W/out.log" && grep -q 'were not changed' "$W/out.log" && [ ! -e "$W/data" ] && [ ! -e "$W/other" ] && ok "a data dir that disagrees with config.yaml stops the setup before anything is created" || { bad "data dir mismatch: wrong stop"; cat "$W/out.log" >&2; }; }

# INSTALL_K3S_EXEC is final before tn_inst_prepare reads it. The library takes a fail-cgroupv1 in
# INSTALL_K3S_EXEC as "set by the device itself" and removes its drop-in; the script used to rebuild the
# variable AFTER that, without the caller's value: the installer got no flag, and a k3s >= v1.35 did not
# start on a cgroup v1 device. These cases run the real text of templates/05_tn_install_k3s.sh from
# "# BEGIN install-k3s-exec" through "tn_inst_prepare server".
sed -n '/^# BEGIN install-k3s-exec$/,/^tn_inst_prepare server$/p' "$ROOT/templates/05_tn_install_k3s.sh" > "$W/prologue.sh"
grep -q '^tn_inst_prepare server$' "$W/prologue.sh" && grep -q '^tn_ca_require_consistent_datadir$' "$W/prologue.sh" || bad "could not extract the prologue of 05_tn_install_k3s.sh"
rm -rf "$W/fake" "$W/pcfg" "$W/pdata"; mkdir -p "$W/fake"
ik3s v1.36.5+k3s1
PENV="K3S_BIN=$W/fake/k3s TN_K3S_CONFIG_DIR=$W/pcfg DATA_DIR=$W/pdata TN_K3S_UNIT_FILE=$W/no-unit PRODUCT=k3s TN_CGROUP_FSTYPE=tmpfs _K3S_TOKEN=tok _DEVICE_ID=dev1 _DOMAIN=test.local INSTALL_K3S_VERSION=v1.36.5+k3s1 TN_K3S_PIN_SOURCE=default"
PD="$W/pcfg/config.yaml.d/99-teknoir-cgroupv1.yaml"
BASEEXEC="server --disable=traefik --token tok --tls-san dev1.test.local --tls-san 10.0.0.10"
if drun $PENV "INSTALL_K3S_EXEC=--kubelet-arg=fail-cgroupv1=false" -- ". '$W/prologue.sh'; echo \"EXEC=\$INSTALL_K3S_EXEC\""; then
  got=$(sed -n 's/^EXEC=//p' "$W/out.log")
  case $got in *fail-cgroupv1=false*) ok "caller's fail-cgroupv1 in INSTALL_K3S_EXEC (cgroup v1, k3s 1.36) reaches the installer" ;; *) bad "the flag is lost: INSTALL_K3S_EXEC='$got'"; cat "$W/out.log" >&2 ;; esac
  case $got in "$BASEEXEC"*) ok "... after the arguments of the script" ;; *) bad "INSTALL_K3S_EXEC lost the arguments of the script: '$got'" ;; esac
  [ -s "$PD" ] && grep -q 'stays until the installer' "$W/out.log" && ok "... and the drop-in is written too: the flag reaches the unit only when the installer has run" || bad "no drop-in for a flag that is only in INSTALL_K3S_EXEC"
else bad "prologue failed with the caller's INSTALL_K3S_EXEC"; cat "$W/out.log" >&2; fi
rm -rf "$W/pcfg" "$W/pdata"
if drun $PENV -- ". '$W/prologue.sh'; echo \"EXEC=\$INSTALL_K3S_EXEC\""; then
  got=$(sed -n 's/^EXEC=//p' "$W/out.log")
  [ "$got" = "$BASEEXEC" ] && ok "no INSTALL_K3S_EXEC from the caller: exactly the arguments of the script" || bad "INSTALL_K3S_EXEC='$got'"
  [ -s "$PD" ] && ok "... and the drop-in is written (cgroup v1, k3s 1.36)" || bad "no drop-in without a flag from the caller"
else bad "prologue failed"; cat "$W/out.log" >&2; fi
rm -rf "$W/pcfg" "$W/pdata"
if drun $PENV INSTALL_K3S_EXEC=--node-label=a=b USE_DOCKER=true -- ". '$W/prologue.sh'; echo \"EXEC=\$INSTALL_K3S_EXEC\""; then
  got=$(sed -n 's/^EXEC=//p' "$W/out.log")
  [ "$got" = "$BASEEXEC --node-label=a=b --docker" ] && ok "the caller's other arguments are kept, --docker is added last" || bad "INSTALL_K3S_EXEC='$got'"
else bad "prologue failed with USE_DOCKER"; cat "$W/out.log" >&2; fi
# the drop-in survives tn_inst_prepare when the caller's flag is only in INSTALL_K3S_EXEC (the CA step restarts k3s
# before the installer writes the unit); a persistent config file with the flag replaces it; none: it is written
rm -rf "$W/pcfg" "$W/pdata"; mkdir -p "$W/pcfg/config.yaml.d"; drun $PENV -- ". '$W/prologue.sh'" || bad "prologue failed (first run)"; [ -s "$PD" ] || bad "no drop-in from the first run"; before=$(sha256sum "$PD")
if drun $PENV "INSTALL_K3S_EXEC=--kubelet-arg=fail-cgroupv1=false" -- ". '$W/prologue.sh'"; then
  [ -f "$PD" ] && [ "$before" = "$(sha256sum "$PD")" ] && ! grep -q 'Removed' "$W/out.log" && ok "drop-in present + the caller's flag in INSTALL_K3S_EXEC: the drop-in remains after tn_inst_prepare" || { bad "drop-in removed before the CA step and the installer"; cat "$W/out.log" >&2; }
else bad "prologue failed (drop-in + INSTALL_K3S_EXEC)"; cat "$W/out.log" >&2; fi
printf 'kubelet-arg+:\n  - fail-cgroupv1=false\n' > "$W/pcfg/config.yaml.d/10-user.yaml"
if drun $PENV "INSTALL_K3S_EXEC=--kubelet-arg=fail-cgroupv1=false" -- ". '$W/prologue.sh'"; then
  [ ! -e "$PD" ] && [ -s "$W/pcfg/config.yaml.d/10-user.yaml" ] && ok "the flag in config.yaml.d/10-user.yaml (k3s reads it): our drop-in is removed" || { bad "drop-in kept next to a persistent setting"; cat "$W/out.log" >&2; }
else bad "prologue failed (config.yaml.d/10-user.yaml)"; cat "$W/out.log" >&2; fi
rm -rf "$W/pcfg" "$W/pdata"
if drun $PENV INSTALL_K3S_EXEC=--node-label=a=b -- ". '$W/prologue.sh'"; then
  [ -s "$PD" ] && ok "no flag from the device: the drop-in is written" || bad "no drop-in without a flag from the device"
else bad "prologue failed (no caller flag)"; cat "$W/out.log" >&2; fi
# an installed k3s older than v1.31 that is upgraded: no flag before the installer, tn_inst_finish writes it
rm -rf "$W/pcfg" "$W/pdata" "$W/fake"; mkdir -p "$W/fake"; ik3s v1.30.14+k3s1
UPG="K3S_BIN=$W/fake/k3s TN_K3S_CONFIG_DIR=$W/pcfg DATA_DIR=$W/pdata TN_CGROUP_FSTYPE=tmpfs INSTALL_K3S_VERSION=v1.31.4+k3s1 TN_K3S_UPGRADE=true TN_K3S_PIN_SOURCE=flag"
if drun $UPG -- 'tn_inst_prepare server'; then
  [ ! -e "$PD" ] && ok "installed k3s 1.30, upgrade to 1.31: no flag before the installer" || bad "flag written for an installed k3s 1.30"
else bad "prepare failed (upgrade from 1.30)"; cat "$W/out.log" >&2; fi
if drun $UPG -- 'tn_inst_prepare server; tn_inst_finish'; then
  [ -s "$PD" ] && ok "... and tn_inst_finish (after the installer) writes it" || bad "tn_inst_finish did not write the flag"
else bad "finish failed"; cat "$W/out.log" >&2; fi
rm -rf "$W/pcfg" "$W/pdata" "$W/fake"; mkdir -p "$W/fake"; ik3s v1.36.5+k3s1
# a data dir that disagrees with config.yaml is refused before tn_inst_prepare changes anything (no drop-in)
rm -rf "$W/pcfg" "$W/pdata"; mkdir -p "$W/pcfg"; printf 'data-dir: %s/other\n' "$W" > "$W/pcfg/config.yaml"
if drun $PENV -- ". '$W/prologue.sh'"; then bad "a data dir that disagrees with config.yaml was accepted by the prologue"
else
  grep -q "config.yaml sets data-dir: $W/other" "$W/out.log" && ! grep -q 'Checking the k3s release' "$W/out.log" && [ ! -e "$PD" ] && ok "a data dir mismatch is refused before the release step changes anything (no drop-in)" || { bad "data dir mismatch: not refused first"; cat "$W/out.log" >&2; }
fi
rm -rf "$W/pcfg" "$W/pdata" "$W/fake"; mkdir -p "$W/fake"

[ "$fail" = 0 ] && echo "setup smoke test passed" || { echo "setup smoke test FAILED" >&2; exit 1; }
