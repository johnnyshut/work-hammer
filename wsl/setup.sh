#!/usr/bin/env bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y openfortivpn ppp xl2tpd strongswan microsocks iproute2

sudo tee /etc/sudoers.d/work-hammer >/dev/null <<EOF
$USER ALL=(root) NOPASSWD: /usr/bin/openfortivpn, /usr/sbin/xl2tpd, /usr/sbin/ipsec, /usr/sbin/ip, /usr/bin/pkill, /usr/bin/tee, /usr/bin/cp, /usr/bin/mkdir
EOF
sudo chmod 440 /etc/sudoers.d/work-hammer
