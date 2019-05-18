#!/bin/bash

# Load wireguard variables. specifically $publicKey
source /etc/wg

# Infinate loop
while true; do
  # iterate through interfaces
  for int in $(find /sys/class/net/* -maxdepth 1 -print0 | xargs -0 -l basename); do
    # only broadcast on eth and wlan interfaces
    if [[ "$int" == "eth"* || "$int" == "wlan"* ]] ; then
      # Announce wireguard's existanse and it's public key
      echo "WG|$publicKey" | socat - UDP6-datagram:[ff02::1%$int]:1234
    fi
  done
  # Repeat every 30 seconds (heartbeat)
  sleep 30
done
