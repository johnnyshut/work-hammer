#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
user="$(whoami)"

if [[ "${1:-}" == stop ]]; then
  sudo -n pkill -x dnsmasq 2>/dev/null || true
  sudo -n pkill -x redsocks 2>/dev/null || true
  exit 0
fi

if ! command -v iptables >/dev/null; then
  sudo -n apt-get install -y iptables </dev/null
fi
if ! command -v dnsmasq >/dev/null; then
  sudo -n apt-get install -y dnsmasq </dev/null
fi

tmp="$(mktemp)"
printf '%s\n' "$user ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/iptables-nft, /usr/sbin/iptables-legacy, /usr/sbin/xtables-nft-multi, /usr/sbin/xtables-legacy-multi, /usr/sbin/sysctl, /usr/sbin/dnsmasq, /usr/bin/dnsmasq, /usr/sbin/redsocks, /usr/bin/redsocks" >"$tmp"
sudo -n install -m 440 "$tmp" /etc/sudoers.d/zzz-work-hammer-fwd
rm -f "$tmp"

echo 1 | sudo -n tee /proc/sys/net/ipv4/ip_forward >/dev/null

ensure() {
  local t=()
  if [[ "$1" == -t ]]; then t=(-t "$2"); shift 2; fi
  sudo -n iptables "${t[@]}" -C "$@" 2>/dev/null || sudo -n iptables "${t[@]}" -A "$@"
}

for iface in forti0 l2tp0; do
  ip link show "$iface" >/dev/null 2>&1 || continue
  ensure -t nat POSTROUTING -o "$iface" -j MASQUERADE
  ensure FORWARD -i eth0 -o "$iface" -j ACCEPT
  ensure FORWARD -i "$iface" -o eth0 -j ACCEPT
  ensure -t mangle OUTPUT -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1000
  ensure -t mangle FORWARD -o "$iface" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1000
done

if ip link show l2tp0 >/dev/null 2>&1; then
  nets="$(grep -E '^NETS=' "$DIR/../l2tp/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')"
  IFS=', ' read -r -a arr <<<"$nets"
  for n in "${arr[@]}"; do
    [[ -n "$n" ]] && sudo -n ip route replace "$n" dev l2tp0
  done
fi

eth="$(ip -4 -o addr show eth0 | awk '{print $4}' | cut -d/ -f1)"
[[ -n "$eth" ]] || exit 1
sudo -n systemctl stop dnsmasq 2>/dev/null || true
sudo -n pkill -x dnsmasq 2>/dev/null || true

conf="/tmp/work-hammer/dnsmasq.conf"
mkdir -p /tmp/work-hammer
{
  echo "port=5353"
  echo "listen-address=$eth"
  echo "bind-interfaces"
  echo "no-resolv"
  echo "no-hosts"
  echo "cache-size=200"
  for name in forti l2tp; do
    dnsf="$DIR/../$name/state/dns"
    envf="$DIR/../$name/.env"
    [[ -f "$dnsf" && -f "$envf" ]] || continue
    dns="$(head -1 "$dnsf" | tr -d '\r')"
    [[ -n "$dns" ]] || continue
    domains="$(grep -E '^DOMAINS=' "$envf" | tail -1 | cut -d= -f2- | tr -d '\r')"
    IFS=', ' read -r -a ds <<<"$domains"
    for d in "${ds[@]}"; do
      [[ -n "$d" ]] && echo "server=/${d#.}/${dns}"
    done
  done
} >"$conf"

sudo -n pkill -x dnsmasq 2>/dev/null || true
sudo -n dnsmasq -C "$conf"

if ! command -v redsocks >/dev/null; then
  sudo -n apt-get install -y redsocks </dev/null
  sudo -n systemctl disable --now redsocks >/dev/null 2>&1 || true
fi
sudo -n systemctl stop redsocks >/dev/null 2>&1 || true

cat >/tmp/work-hammer/redsocks.conf <<'EOF'
base {
  log_debug = off;
  log_info = off;
  daemon = on;
  redirector = iptables;
  rlimit_nofile = 8192;
  redsocks_conn_max = 1024;
  connpres_idle_timeout = 180;
  max_accept_backoff = 1000;
  tcp_keepalive_time = 30;
  tcp_keepalive_probes = 3;
  tcp_keepalive_intvl = 10;
}
redsocks {
  local_ip = 0.0.0.0;
  local_port = 12345;
  ip = 127.0.0.1;
  port = 1080;
  type = socks5;
}
EOF
sudo -n redsocks -t -c /tmp/work-hammer/redsocks.conf
if ! ss -lnt | grep -q ':12345'; then
  sudo -n redsocks -c /tmp/work-hammer/redsocks.conf
fi

{
  [[ -f "$DIR/../cisco/state/nets" ]] && cat "$DIR/../cisco/state/nets"
  grep -E '^NETS=' "$DIR/../cisco/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr ',' '\n'
  grep -E '^BYPASS_NETS=' "$DIR/../proxy/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr ',' '\n'
} | while read -r net; do
  net="${net//$'\r'/}"
  net="${net// /}"
  [[ "$net" == */* ]] || continue
  for chain in PREROUTING OUTPUT; do
    sudo -n iptables -t nat -C "$chain" -d "$net" -p tcp -m comment --comment work-hammer -j REDIRECT --to-ports 12345 2>/dev/null ||
      sudo -n iptables -t nat -A "$chain" -d "$net" -p tcp -m comment --comment work-hammer -j REDIRECT --to-ports 12345
  done
done
