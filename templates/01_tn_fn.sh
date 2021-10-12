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

SUDO=''
if [ ! ${EUID} = 0 ] && [ -z "${OS_BUILD+x}" ]; then
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

# --- regexp ---
exprq() {
  local value

  test "$2" = ":" && value="$3" || value="$2"
  expr "$1" : "$value" 1>/dev/null
}

TMP=$(mktemp -d -t bootstrap-device-XXX)
# --- cleanup/error trap ---
error() {
  local code="$1"
  echo "[ERROR] Error: exiting with status ${code}"
  exit "${code}"
}
cleanup() {
  rm -rf "$TMP"
  [ $? -eq 0 ] && exit
  error "$?"
}
trap 'cleanup' EXIT

cd $TMP
info "Teknoir bootstrapping...${TMP}"
