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
