# --- helper functions for logs ---
info()
{
    echo '[INFO] ' "$@"
}
warn()
{
    echo '[WARN] ' "$@" >&2
}
fatal()
{
    echo '[ERROR] ' "$@" >&2
    exit 1
}

error() {
  local message="$1"
  local code="${3:-1}"
  if [[ -n "$message" ]] ; then
    echo "[ERROR] Error: ${message}; exiting with status ${code}"
  else
    echo "[ERROR] Error: exiting with status ${code}"
  fi
  exit "${code}"
}
trap error ERR

SUDO=''
if [ ${EUID} -ne 0 ] && [ -z "${OS_BUILD+x}" ]; then
    info "Please be ready to enter the device´s sudo password:"
    SUDO='sudo -H'
fi

DOWNLOADER=
# --- download ---
download() {
    [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'

    case $DOWNLOADER in
        curl)
            if [ "${OS_BUILD}" = true ] || [ "${INSECURE}" = true ]; then
                info "Running installation without verifying ssl certs on URLs"
                $SUDO curl --insecure -o $1 -sSfL $2
            else
                $SUDO curl -o $1 -sSfL $2
            fi
            ;;
        wget)
            $SUDO wget -qO $1 $2
            ;;
        *)
            fatal "Incorrect executable '$DOWNLOADER'"
            ;;
    esac

    # Abort if download command failed
    [ $? -eq 0 ] || fatal 'Download failed'
}

# --- verify existence of network downloader executable ---
verify_downloader() {
    # Return failure if it doesn't exist or is no executable
    [ -x "$(command -v $1)" ] || return 1

    # Set verified executable as our downloader program and return success
    DOWNLOADER=$1
    return 0
}

verify_downloader curl || verify_downloader wget || fatal 'Can not find curl or wget for downloading files'

TMP=$(mktemp -d -t bootstrap-device-XXX)
# --- cleanup trap ---
cleanup() {
  rm -rf "$TMP"
}
trap cleanup 0

cd $TMP
info "Teknoir bootstrapping...${TMP}"
