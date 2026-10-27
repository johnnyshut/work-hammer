# shellcheck shell=bash
# Expects: NAME, DIR, IFACE, TABLE, PORT

STATE="$DIR/state"
RUN="/tmp/work-hammer/$NAME"
mkdir -p "$STATE" "$RUN"

status() { printf '%s' "$1" >"$STATE/status"; }

env_get() { grep -E "^$1=" "$DIR/.env" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r'; }

iface_ip() { ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1; }

wait_iface() {
  local i pid="${2:-}"
  for ((i = 0; i < $1; i++)); do
    [[ -n "$(iface_ip)" ]] && return 0
    [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null && return 1
    sleep 1
  done
  return 1
}

socks_down() {
  pkill -f "microsocks .*-p $PORT( |$)" 2>/dev/null
  while sudo -n ip rule del priority "$TABLE" 2>/dev/null; do :; done
  sudo -n ip route flush table "$TABLE" 2>/dev/null
}

socks_up() {
  local ip
  ip="$(iface_ip)"
  socks_down
  sudo -n ip route replace default dev "$IFACE" table "$TABLE"
  sudo -n ip rule add from "$ip" lookup "$TABLE" priority "$TABLE"
  microsocks -i 0.0.0.0 -p "$PORT" -b "$ip" >/dev/null 2>&1 &
}

finish() {
  socks_down
  if [[ -f "$RUN/stop" ]]; then status stopped; else status failed; fi
}

begin() {
  exec >"$STATE/run.log" 2>&1
  rm -f "$RUN/stop" "$STATE/dns" "$STATE/nets"
  status connecting
  trap finish EXIT
  trap 'exit 0' INT TERM
}
