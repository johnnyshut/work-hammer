#!/usr/bin/env bash
NAME=l2tp IFACE=l2tp0 TABLE=102 PORT=14080
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../wsl/lib.sh"

l2tp_down() {
  echo "d vpn" | sudo -n tee /var/run/xl2tpd/l2tp-control >/dev/null 2>&1
  sudo -n pkill -x xl2tpd
  sudo -n ipsec stop >/dev/null 2>&1
}

if [[ "${1:-}" == stop ]]; then
  touch "$RUN/stop"
  l2tp_down
  socks_down
  exit 0
fi

begin
l2tp_down
sleep 1

server="$(env_get VPN_SERVER)"
user="$(env_get VPN_USER)"
pass="$(env_get VPN_PASSWORD)"
psk="$(env_get L2TP_PSK)"
server_ip="$(getent ahostsv4 "$server" | awk '{print $1; exit}')"
[[ -n "$server_ip" ]] || exit 1
local_ip="$(ip -4 route get "$server_ip" | sed -n 's/.* src \([^ ]*\).*/\1/p')"

umask 077
cat >"$RUN/ipsec.conf" <<EOF
conn vpn
    keyexchange=ikev1
    authby=secret
    type=transport
    left=$local_ip
    leftid=%any
    leftprotoport=17/1701
    right=$server_ip
    rightid=%any
    rightprotoport=17/1701
    forceencaps=yes
    auto=add
    ike=aes256-sha1-modp1024,aes128-sha1-modp1024,3des-sha1-modp1024!
    esp=aes256-sha1,aes128-sha1,3des-sha1!
EOF
echo ": PSK \"$psk\"" >"$RUN/ipsec.secrets"

cat >"$RUN/xl2tpd.conf" <<EOF
[lac vpn]
lns = $server_ip
pppoptfile = $RUN/ppp.options
length bit = yes
EOF

cat >"$RUN/ppp.options" <<EOF
ifname $IFACE
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-mschap-v2
noccp
noauth
nodefaultroute
usepeerdns
mtu 1410
mru 1410
name "$user"
password "$pass"
EOF

sudo -n mkdir -p /var/run/xl2tpd
sudo -n cp "$RUN/ipsec.conf" /etc/ipsec.conf
sudo -n cp "$RUN/ipsec.secrets" /etc/ipsec.secrets
sudo -n ipsec restart || exit 1
sleep 2
timeout 30 sudo -n ipsec up vpn || exit 1
[[ -f "$RUN/stop" ]] && exit 0

sudo -n xl2tpd -D -c "$RUN/xl2tpd.conf" &
vpn=$!
sleep 2
echo "c vpn" | sudo -n tee /var/run/xl2tpd/l2tp-control >/dev/null

wait_iface 60 || exit 1
sleep 2

awk '/^nameserver/ {print $2}' /etc/ppp/resolv.conf >"$STATE/dns" 2>/dev/null
: >"$STATE/nets"

socks_up
status up
wait "$vpn"
