EOL
fi

echo "Device bootstrapped successfully!"
popd
rm -rf $TMP

echo "Notice!"
echo "No networking or user settings has been changed to match settings in the platform."
echo "To enable tunneling from the platform, please refer to our documentation."

# TBD: some info about FAQ/Tunneling etc.
# Remember no networking, user or tunneling settings are applied
#info "update-alternatives --set iptables /usr/sbin/iptables-legacy
#     update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy"
#mkdir -p $HOME/.ssh
#$SUDO ssh-keygen -y -f ${CONFIG_PATH}/rsa_private.pem > $HOME/.ssh/authorized_keys
#$SUDO chown $USER.$USER $HOME/.ssh/authorized_keys
