warn "To enable tunneling, the user ${_FIRST_USER_NAME} has to be created."

on_sudo() {
  $SUDO bash -- "$@"
}

setup_user() {
  on_sudo << EOF
mkdir -p /home/${_FIRST_USER_NAME}/.ssh
cp ${CONFIG_PATH}/rsa_private.pem /home/${_FIRST_USER_NAME}/.ssh/id_rsa
ssh-keygen -y -f ${CONFIG_PATH}/rsa_private.pem > /home/${_FIRST_USER_NAME}/.ssh/id_rsa.pub
cat /home/${_FIRST_USER_NAME}/.ssh/id_rsa.pub > /home/${_FIRST_USER_NAME}/.ssh/authorized_keys
if [ -z ${_FIRST_USER_KEY+x} ]; then
  info "_FIRST_USER_KEY is unset";
else
  echo "${_FIRST_USER_KEY}" >> /home/${_FIRST_USER_NAME}/.ssh/authorized_keys
fi
chmod 600 /home/${_FIRST_USER_NAME}/.ssh/*
chmod 744 /home/${_FIRST_USER_NAME}/.ssh
chown -R ${_FIRST_USER_NAME}:${_FIRST_USER_NAME} /home/${_FIRST_USER_NAME}

adduser ${_FIRST_USER_NAME} users
adduser ${_FIRST_USER_NAME} sudo
EOF
}

[[ $OS_BUILD = true ]] || read -p "Do you want to add ${_FIRST_USER_NAME} and enable tunneling? [yY]" -n 1 -r
echo    # (optional) move to a new line
if [[ $REPLY =~ ^[Yy]$ ]] || [[ $OS_BUILD = true ]]; then
  if ! id -u ${_FIRST_USER_NAME} >/dev/null 2>&1; then
    $SUDO adduser --disabled-password --gecos "" ${_FIRST_USER_NAME}
    echo "${_FIRST_USER_NAME}:${_FIRST_USER_PASS}" | $SUDO chpasswd
    setup_user
  else
    warn "The user ${_FIRST_USER_NAME} already exist, this will change password and OVERWRITE ssh keys."
    [[ $OS_BUILD = true ]] || read -p "Do you want to update ${_FIRST_USER_NAME} and enable tunneling? [yY]" -n 1 -r
    echo    # (optional) move to a new line
    if [[ $REPLY =~ ^[Yy]$ ]] || [[ $OS_BUILD = true ]]; then
      echo "${_FIRST_USER_NAME}:${_FIRST_USER_PASS}" | $SUDO chpasswd
      setup_user
    fi
  fi
fi
