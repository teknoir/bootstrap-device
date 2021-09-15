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

DOWNLOADER=
# --- download ---
download() {
    [ $# -eq 2 ] || fatal 'download needs exactly 2 arguments'

    case $DOWNLOADER in
        curl)
            if [ "${OS_BUILD}" = true ]; then
                curl --insecure -o $1 -sfL $2
            else
                curl -o $1 -sfL $2
            fi
            ;;
        wget)
            wget -qO $1 $2
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

