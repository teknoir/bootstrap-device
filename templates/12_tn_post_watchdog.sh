  $SUDO chmod 644 /lib/systemd/system/tn-watchdog.service
  info "Enable and start watchdog service"
  if [ ${OS_BUILD} ]; then
      info "OS Build specifics"
      $SUDO ln -s /lib/systemd/system/tn-watchdog.service /etc/systemd/system/multi-user.target.wants/tn-watchdog.service
  else
      $SUDO systemctl enable --now tn-watchdog.service
  fi
fi
