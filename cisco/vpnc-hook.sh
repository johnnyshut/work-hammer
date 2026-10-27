#!/usr/bin/env bash
/usr/share/vpnc-scripts/vpnc-script
rc=$?

if [[ "$reason" == connect ]]; then
  for d in ${INTERNAL_IP4_DNS:-}; do
    ip route replace "$d/32" dev "$TUNDEV"
  done
  printf '%s\n' ${INTERNAL_IP4_DNS:-} >/state/dns
  {
    for ((i = 0; i < ${CISCO_SPLIT_INC:-0}; i++)); do
      addr="CISCO_SPLIT_INC_${i}_ADDR"
      len="CISCO_SPLIT_INC_${i}_MASKLEN"
      echo "${!addr}/${!len}"
    done
    printf '%s/32\n' ${INTERNAL_IP4_DNS:-}
  } >/state/nets
fi

exit $rc
