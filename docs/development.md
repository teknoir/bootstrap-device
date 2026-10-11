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

`templates/05_tn_install_k3s.sh` calls `tn_k3s_ca_setup`, defined in `templates/04_tn_k3s_ca_lib.sh`.
That file is **vendored, not edited here**: it is `pkg/templates/scripts/tn-k3s-ca.sh` of
[teknoir/cli](https://github.com/teknoir/cli) at the commit recorded in `test/k3s-ca/VENDORED_FROM`
(one header line plus the file, byte for byte). The same goes for the docker test harness in
`test/k3s-ca/`. Change both in `cli` and re-vendor them; do not patch them here.

Why: k3s v1.34.12 / v1.35.9 / v1.36.5 / v1.37.1 and later only accept a CA root with the
`keyCertSign` key usage, and the device certificate has never had it. The library re-issues the
device certificate from the same key as the root. A server script run on a device that was
bootstrapped with the old root repairs it before the k3s installer can upgrade k3s
(`TN_K3S_CA_AUTO_REMEDIATE=false` stops with advice instead). The same file is the stand-alone
tool `sh tn-k3s-ca.sh check|remediate`, see the cli troubleshooting page.

```bash
test/check-assembly.sh              # assemble server and agent scripts, sh -n/dash -n, library embedded
test/check-setup.sh                 # setup under dash with the bootstrap shell options (needs openssl)
test/k3s-ca/check-vendored.sh --cli ../cli   # vendored files == cli at VENDORED_FROM (or: gh api, no --cli)
(cd test/k3s-ca && go test ./...)   # offline unit tests of the harness

# real k3s releases in docker (needs docker, go, network; minutes):
TN_K3S_CA_LIB=$PWD/templates/04_tn_k3s_ca_lib.sh \
  test/k3s-ca/run.sh --suite fresh,rerun,remediation,agent --gens bs-o111 --versions "v1.34.11 v1.36.5"
```

See `test/k3s-ca/README.md` for the suites and the hooks.
