#!/usr/bin/env bash
set -uo pipefail

status() { printf '%s' "$1" >/state/status; }

rm -f /state/dns /state/nets
status connecting
trap 'status stopped; kill "${vpn:-}" 2>/dev/null; exit 0' INT TERM

for part in crt key; do
  [[ $part == crt ]] && opt=(-clcerts -nokeys) || opt=(-nocerts -nodes)
  openssl pkcs12 -legacy -in /certs/client.p12 -passin env:CERT_PASS "${opt[@]}" -out "/tmp/client.$part" \
    || { status failed; exit 1; }
done

microsocks -p 1080 >/dev/null 2>&1 &

printf '%s\n' "$VPN_PASSWORD" | openconnect \
  --protocol=anyconnect \
  --interface=tun0 \
  --script="bash /app/vpnc-hook.sh" \
  --disable-ipv6 \
  --os=win \
  --useragent="AnyConnect Windows 4.10.07073" \
  --version-string=4.10.07073 \
  --local-hostname="${LOCAL_HOSTNAME:-$(hostname)}" \
  --certificate=/tmp/client.crt \
  --sslkey=/tmp/client.key \
  --user="$VPN_USER" \
  --passwd-on-stdin \
  "$VPN_SERVER" &
vpn=$!

for ((i = 0; i < 180; i++)); do
  kill -0 "$vpn" 2>/dev/null || break
  if [[ -f /state/nets ]] && ip link show tun0 >/dev/null 2>&1; then
    status up
    break
  fi
  sleep 1
done

wait "$vpn"
status failed
