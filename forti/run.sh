#!/usr/bin/env bash
NAME=forti IFACE=forti0 TABLE=101 PORT=11080
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/../wsl/lib.sh"

if [[ "${1:-}" == stop ]]; then
  touch "$RUN/stop"
  sudo -n pkill -x openfortivpn
  socks_down
  exit 0
fi

begin
sudo -n pkill -x openfortivpn && sleep 2

server="$(env_get VPN_SERVER)"
host="${server%%:*}"
port="${server#*:}"
[[ "$port" == "$server" ]] && port=443
cert="$(env_get TRUSTED_CERT)"

umask 077
{
  echo "host = $host"
  echo "port = $port"
  echo "username = $(env_get VPN_USER)"
  echo "password = $(env_get VPN_PASSWORD)"
  [[ -n "$cert" ]] && echo "trusted-cert = $cert"
  echo "pppd-ifname = $IFACE"
  echo "set-dns = 0"
  echo "pppd-use-peerdns = 0"
  echo "set-routes = 1"
} >"$RUN/openfortivpn.conf"

sudo -n openfortivpn -c "$RUN/openfortivpn.conf" &
vpn=$!

wait_iface 180 || exit 1
sleep 3

sed -n 's/.*ns \[\([^]]*\)\].*/\1/p' "$STATE/run.log" | tail -1 | tr -d ' ' | tr ',' '\n' >"$STATE/dns"
ip -4 route show dev "$IFACE" | awk '!/proto kernel/ {print ($1 ~ /\//) ? $1 : $1 "/32"}' >"$STATE/nets"

socks_up
status up
wait "$vpn"
