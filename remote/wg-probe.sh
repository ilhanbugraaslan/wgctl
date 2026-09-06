#!/usr/bin/env bash
# wg-probe.sh — runs ON THE SERVER, prints detected settings as KEY=VALUE.
# `wgctl.sh init` uses these as the defaults it offers.
# Read-only: changes nothing.

set -uo pipefail

emit() { printf '%s=%s\n' "$1" "${2:-}"; }

# Egress interface: whatever the default route uses.
EGRESS=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
emit EGRESS "$EGRESS"

# Connected subnet and address on that interface.
if [ -n "$EGRESS" ]; then
  emit LAN        "$(ip -4 route show dev "$EGRESS" proto kernel scope link 2>/dev/null | awk 'NR==1{print $1}')"
  emit SERVER_LAN_IP "$(ip -4 -brief addr show "$EGRESS" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 | head -1)"
fi

# Public address, best effort; empty if there is no outbound access.
PUB=""
for u in https://ifconfig.me https://api.ipify.org https://icanhazip.com; do
  PUB=$(curl -s -4 --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]')
  case "$PUB" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;; *) PUB="" ;; esac
done
emit PUBLIC_IP "$PUB"

# Package manager, so wg-apply.sh can install what is missing.
for m in apt-get dnf yum pacman apk zypper xbps-install emerge; do
  command -v "$m" >/dev/null 2>&1 && { emit PKG "$m"; break; }
done

emit HAS_WG          "$(command -v wg          >/dev/null 2>&1 && echo yes || echo no)"
emit HAS_QRENCODE    "$(command -v qrencode    >/dev/null 2>&1 && echo yes || echo no)"
emit HAS_IPTABLES    "$(command -v iptables    >/dev/null 2>&1 && echo yes || echo no)"
emit HAS_PERSISTENT  "$([ -d /etc/iptables ] || command -v netfilter-persistent >/dev/null 2>&1 && echo yes || echo no)"
emit HAS_SYSTEMD     "$(command -v systemctl  >/dev/null 2>&1 && echo yes || echo no)"
emit IS_PROXMOX      "$(command -v pveversion >/dev/null 2>&1 && echo yes || echo no)"
emit KERNEL          "$(uname -r)"
emit WG_MODULE       "$([ -d /sys/module/wireguard ] && echo loaded || echo absent)"

# An existing install we should not silently clobber.
emit EXISTING_CONF   "$(ls /etc/wireguard/*.conf 2>/dev/null | head -3 | tr '\n' ' ')"

# Ports already listening, so the wizard can suggest a free one.
emit USED_UDP_PORTS  "$(ss -lun 2>/dev/null | awk 'NR>1{n=split($5,a,":"); if (a[n] ~ /^[0-9]+$/) print a[n]}' | sort -un | tr '\n' ',' | sed 's/,$//')"

if [ -r /etc/os-release ]; then
  . /etc/os-release
  emit OS "${PRETTY_NAME:-${ID:-unknown}}"
fi
