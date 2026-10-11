---
id: index
title: Development Documentation
# prettier-ignore
description: How to do local development.
---

## Build pipeline
```bash
gcloud builds submit . \
--config=cloudbuild.yaml \
--substitutions=_GCP_PROJECT=teknoir-poc,_IOT_REGISTRY=demonstrations,_DEVICE_ID=my-new-device,_DOMAIN=teknoir.dev,_RSA_PRIVATE=...the...actual...private.....key
```

## Local build
This only works if you kubectl contexts are set up as follows:
> teknoir-prod is the context name for cluster in teknoir project                                                                                                                                                                                                         
> teknoir-dev is the context name for cluster in teknoir-poc project

### Run
```bash
./build_local.sh -p teknoir-poc -n demonstrations -d my-new-device
```
> where:
> "teknoir-poc" is the GCP project
> "demonstrations" is the namespace/project in the Teknoir platform
> "my-new-device" is the device name, that is already created in the namespace/project above

## The k3s CA library and its tests

`templates/05_tn_install_k3s.sh` calls `tn_k3s_ca_setup`, defined in `templates/04_tn_k3s_ca_lib.sh`,
and `tn_inst_prepare`, defined in `templates/04_tn_k3s_install_lib.sh` (the agent script has the
latter as `agent_templates/02_tn_k3s_install_lib.sh`).
These files are **vendored, not edited here**: they are `pkg/templates/scripts/tn-k3s-ca.sh` and
`pkg/templates/scripts/tn-k3s-install.sh` of [teknoir/cli](https://github.com/teknoir/cli) at the
commit recorded in `test/k3s-ca/VENDORED_FROM` (one header line plus the file, byte for byte). The
same goes for the docker test harness in `test/k3s-ca/`. Change them in `cli` and re-vendor; do not
patch them here.

Why: k3s v1.34.12 / v1.35.9 / v1.36.5 / v1.37.1 and later only accept a CA root with the
`keyCertSign` key usage, and the device certificate has never had it. The library re-issues the
device certificate from the same key as the root. A server script run on a device that was
bootstrapped with the old root repairs it before the k3s installer can upgrade k3s
(`TN_K3S_CA_AUTO_REMEDIATE=false` stops with advice instead). The same file is the stand-alone
tool `sh tn-k3s-ca.sh check|remediate`, see the cli troubleshooting page.

### Re-runs keep the installed k3s, and cgroup v1

- **A re-run keeps the installed k3s.** `tn_inst_prepare` (install library) reads `k3s --version`. A device
  that has k3s keeps that exact release (the pin is the release for a new device); `TN_K3S_UPGRADE=true`
  lets the pin replace it. A downgrade is always refused, and an upgrade over more than one minor
  version is refused unless `TN_K3S_FORCE=true`. A k3s binary or `server/db` whose version cannot be
  read is not installed over (`TN_K3S_FORCE=true` overrides).
- **An agent follows its server.** A kubelet must not be newer than its apiserver, so a new agent installs
  the k3s release of its server, not `TN_K3S_VERSION`. k3s does not answer `/version` anonymously (401), so
  the **server script publishes** the release it runs (`tn_inst_publish_release`, after the installer) as
  `<data dir>/server/static/teknoir/k3s-version`, which k3s serves without authentication; the agent reads
  `https://<K3S_URL>/static/teknoir/k3s-version`. A release asked for with `INSTALL_K3S_VERSION` is installed
  if it is not newer than the server's, refused if it is. If the release of the server cannot be read the
  agent script stops, unless a release was asked for or `TN_K3S_FORCE=true`; a server bootstrapped by an
  older script publishes nothing: run its script again (it keeps k3s). OS builds install the pin.
- **Order in the server script**: `tn_ca_resolve_datadir`, `tn_inst_prepare server` (release policy and
  kubelet flag), `tn_k3s_ca_setup` (CA; may restart k3s), the installer, `tn_inst_publish_release`. The flag is
  in place before the CA step restarts k3s, so a k3s that a cgroup v1 host made exit is up for `rotate-ca`.
  A data dir that disagrees with `config.yaml` stops the script before anything is changed. Restarts wait up
  to `TN_K3S_SERVICE_TIMEOUT` (600 s) plus a 120 s grace.
- **cgroup v1 hosts** (Jetson L4T r32/r35, Ubuntu 18.04/20.04; `stat -fc %T /sys/fs/cgroup` is not
  `cgroup2fs`): Kubernetes >= 1.35 refuses to start the kubelet there. For k3s >= v1.31 (the kubelet knows the flag from then on; it only matters from v1.35) the script writes
  `/etc/rancher/k3s/config.yaml.d/99-teknoir-cgroupv1.yaml` (`kubelet-arg+: fail-cgroupv1=false`, which
  appends to the owner's `kubelet-arg`) and warns that cgroup v1 is deprecated. `TN_K3S_CGROUPV1=true|false`
  forces the answer; an OS build cannot tell and sets the flag (harmless on v2).
- `/etc/rancher/k3s/config.yaml` is no longer replaced by a re-run: missing keys are added.

### The k3s version and the data dir

- **Pinned k3s.** `TN_K3S_VERSION` at the top of `templates/00_tn_header.sh` and
  `agent_templates/00_tn_header.sh` is the k3s release the scripts install (`v1.36.5+k3s1`, the stable
  channel when written and the release the harness proves with the fixed CA). The installer gets it as
  `INSTALL_K3S_VERSION`; `INSTALL_K3S_VERSION=v1.xx.y+k3sN sh script` overrides it and
  `INSTALL_K3S_VERSION=stable` restores the installer's own choice. A server and its agents must run the
  same release, and k3s cannot be downgraded (a device that already has k3s keeps its version anyway, see
  above). Keep the value equal to `DefaultK3SVersion` in
  teknoir/cli (`pkg/templates/bootstrap_templates.go`).
- **Data dir.** Devices run k3s from `/var/lib/rancher/k3s`. An older `05_tn_install_k3s.sh` wrote
  `data-dir: /opt/k3s` to `/etc/rancher/k3s/config.yaml`, but the `config.yaml` written a few lines
  later replaced the file before the installer ran, so the line never took effect; it is gone. The CA
  library finds the data dir the way k3s does (`ExecStart` of `k3s.service`, `config.yaml.d/*.yaml`,
  `config.yaml`, default) and exports `DATA_DIR`; the script writes it back to `config.yaml` if it is
  not the default, and installs the Teknoir manifests there.

```bash
test/check-assembly.sh              # assemble server and agent scripts, sh -n/dash -n, library embedded
test/check-setup.sh                 # setup under dash with the bootstrap shell options (needs openssl), data dir resolution
test/k3s-ca/check-vendored.sh --cli ../cli   # both vendored libraries and the harness == cli at VENDORED_FROM (or: gh api, no --cli)
(cd test/k3s-ca && go test ./...)   # offline unit tests of the harness

# real k3s releases in docker (needs docker, go, network; minutes):
TN_K3S_CA_LIB=$PWD/templates/04_tn_k3s_ca_lib.sh TN_K3S_INSTALL_LIB=$PWD/templates/04_tn_k3s_install_lib.sh \
  test/k3s-ca/run.sh --suite fresh,rerun,remediation,agent,install --gens bs-o111 --versions "v1.34.11 v1.36.5"
```

See `test/k3s-ca/README.md` for the suites and the hooks.
