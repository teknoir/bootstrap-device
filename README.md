# drop-in-device-bootstrap-script
Bootstrap, almost any Linux device to connect to the Teknoir platform.
This project creates a shell script that sets up a device to connect to our platform.

The script does NOT:
* Set up networking, this is manual
* Set up user used for tunneling etc. there will be documentation on how to activate this

## Build pipeline
```bash
gcloud builds submit . \
--config=cloudbuild.yaml \
--substitutions=_GCP_PROJECT=teknoir,_IOT_REGISTRY=jeremy-johnston,_DEVICE_ID=khadas-test,_DOMAIN=teknoir.cloud,_RSA_PRIVATE=...the...actual...private.....key
```

## Local build
This only works if you kubectl contexts are set up as follows:
> teknoir-prod is the context name for cluster in teknoir project                                                                                                                                                                                                         
> teknoir-dev is the context name for cluster in teknoir-poc project

### Run
```bash
./build_local.sh -p teknoir -n jeremy-johnston -d khadas-test
```
> where:
> "teknoir" is the GCP project
> "jeremey-johnston" is the namespace/project in the Teknoir platform
> "khadas-test" is the device name, that is already created in the namespace/project above
