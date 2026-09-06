#!/usr/bin/env bash
# wg-apply.sh — runs ON THE SERVER.
#
# Treats the clients/ directory as the single source of truth and regenerates
#   /etc/wireguard/<iface>.conf   and   /etc/iptables/rules.v4
# from it. Do not hand-edit those two files; this script overwrites them.
#
# Firewall changes are applied behind a rollback guard: if no "commit" arrives
# within ROLLBACK_SECS, the previous ruleset is restored. That keeps a bad rule
# from locking everyone out over SSH.

set -euo pipefail

IFACE="${WG_IFACE:-wg0}"
PORT="${WG_PORT:-51825}"
SUBNET="${WG_SUBNET:-10.10.0.0/24}"
SERVER_IP="${WG_SERVER_IP:-10.10.0.1}"
LAN="${WG_LAN:-192.168.1.0/24}"
# Fall back to whatever the default route uses, so this works off Proxmox too.
EGRESS="${WG_EGRESS:-$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)}"
HOST_PORTS="${WG_HOST_PORTS:-22,8006}"
ROLLBACK_SECS="${ROLLBACK_SECS:-90}"

WG_DIR=/etc/wireguard
CLIENTS_DIR="$WG_DIR/clients"
CONF="$WG_DIR/$IFACE.conf"
RULES=/etc/iptables/rules.v4
BACKUP_ROOT=/root/wgctl-backups
COMMIT_FLAG=/run/wgctl-commit
PREFIX="${SUBNET##*/}"

# Progress goes to stderr: stdout is redirected into the generated config below.
log() { printf '  %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- commit
# Cancels the rollback timer. Called by the local wgctl.sh only after it has
# proven that a fresh SSH connection still works.
if [ "${1:-}" = "commit" ]; then
  touch "$COMMIT_FLAG"
  systemctl stop wgctl-rollback.timer 2>/dev/null || true
  netfilter-persistent save >/dev/null 2>&1 || true
  echo "commit: rollback cancelled, rules are permanent."
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "root required"

# ---------------------------------------------------------- prerequisites
# Works on any distribution, not just Proxmox/Debian.
pkg_install() {
  local pkgs="$*"
  if   command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive        # iptables-persistent asks otherwise
    apt-get update -qq >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    apt-get install -y -qq $pkgs >/dev/null 2>&1
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q $pkgs >/dev/null 2>&1
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q $pkgs >/dev/null 2>&1
  elif command -v pacman  >/dev/null 2>&1; then pacman -S --noconfirm --needed $pkgs >/dev/null 2>&1
  elif command -v apk     >/dev/null 2>&1; then apk add --no-cache $pkgs >/dev/null 2>&1
  elif command -v zypper  >/dev/null 2>&1; then zypper --non-interactive install $pkgs >/dev/null 2>&1
  else return 1; fi
}

need_cmd() {   # need_cmd <command> <package...>
  command -v "$1" >/dev/null 2>&1 && return 0
  log "installing missing dependency: $1"
  shift
  pkg_install "$@" || die "could not install $* — install it manually and retry"
  command -v "$1" >/dev/null 2>&1 || die "$1 still missing after installing $*"
}

need_cmd wg wireguard-tools
need_cmd wg-quick wireguard-tools
need_cmd iptables iptables

# Rule persistence across reboots. Debian/Ubuntu use iptables-persistent;
# elsewhere iptables-services or a plain systemd unit provides it.
if [ ! -d /etc/iptables ] && ! command -v netfilter-persistent >/dev/null 2>&1; then
  log "installing iptables persistence"
  pkg_install iptables-persistent || pkg_install iptables-services || \
    log "WARNING: no persistence package found; rules.v4 will not reload on boot"
fi
mkdir -p /etc/iptables

# Fallback unit when netfilter-persistent is unavailable (non-Debian systems).
if ! command -v netfilter-persistent >/dev/null 2>&1 && [ ! -f /etc/systemd/system/wgctl-iptables.service ]; then
  cat > /etc/systemd/system/wgctl-iptables.service <<'UNIT'
[Unit]
Description=Restore iptables rules for wgctl
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables-restore < /etc/iptables/rules.v4'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable wgctl-iptables.service >/dev/null 2>&1 \
    && log "installed wgctl-iptables.service to restore rules at boot"
fi

# ---------------------------------------------------------------- backup
TS=$(date +%Y%m%d-%H%M%S)
BACKUP="$BACKUP_ROOT/$TS"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP_ROOT" "$BACKUP"
iptables-save > "$BACKUP/iptables.live"
[ -f "$RULES" ] && cp -a "$RULES" "$BACKUP/rules.v4"
[ -f "$CONF" ]  && cp -a "$CONF"  "$BACKUP/$IFACE.conf"
[ -d "$CLIENTS_DIR" ] && tar czf "$BACKUP/clients.tar.gz" -C "$WG_DIR" clients
log "backup: $BACKUP"

# ------------------------------------------------------------ server keys
umask 077
mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"
if [ ! -s "$WG_DIR/server_private.key" ]; then
  wg genkey > "$WG_DIR/server_private.key"
  wg pubkey < "$WG_DIR/server_private.key" > "$WG_DIR/server_public.key"
  log "generated a server keypair"
fi
chmod 600 "$WG_DIR/server_private.key"
chmod 644 "$WG_DIR/server_public.key"

# ------------------------------------------------------------ permissions
mkdir -p "$CLIENTS_DIR"
chmod 700 "$CLIENTS_DIR"
find "$CLIENTS_DIR" -mindepth 1 -type d -exec chmod 700 {} +
find "$CLIENTS_DIR" -type f -exec chmod 600 {} +

# --------------------------------------------------------- generate config
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
{
  echo "# ==============================================================="
  echo "# GENERATED by wgctl.sh apply   ($(date -Is))"
  echo "# Source: $CLIENTS_DIR/*/"
  echo "# Hand edits are lost on the next apply."
  echo "# ==============================================================="
  echo
  echo "[Interface]"
  echo "Address = $SERVER_IP/$PREFIX"
  echo "ListenPort = $PORT"
  echo "PrivateKey = $(cat "$WG_DIR/server_private.key")"
  echo "# SaveConfig is deliberately absent: runtime state must not overwrite this file."
  echo "# Firewall rules live in $RULES, not in PostUp."
  echo
  peers=0
  for d in "$CLIENTS_DIR"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    [ -s "$d/public.key" ] || { log "skipped (no public.key): $name"; continue; }
    # Address: the 'address' file for externally-keyed peers, else the config.
    if [ -s "$d/address" ]; then
      addr=$(cat "$d/address")
    else
      cconf="$d/$name.conf"
      [ -s "$cconf" ] || { log "skipped (no $name.conf and no address): $name"; continue; }
      addr=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*\([^,[:space:]]*\).*/\1/p' "$cconf" | head -1)
    fi
    [ -n "$addr" ] || { log "skipped (could not read address): $name"; continue; }
    echo "[Peer]"
    echo "# $name"
    echo "PublicKey = $(cat "$d/public.key")"
    [ -s "$d/preshared.key" ] && echo "PresharedKey = $(cat "$d/preshared.key")"
    echo "AllowedIPs = ${addr%%/*}/32"
    echo
    peers=$((peers+1))
  done
  echo "# total peers: $peers"
} > "$tmp"
install -m 600 "$tmp" "$CONF"
rm -f "$WG_DIR/$IFACE.conf.tmp"        # leftover from an interrupted SaveConfig
log "$CONF generated ($(grep -c '^\[Peer\]' "$CONF") peers)"

# -------------------------------------------------------- generate rules.v4
mkdir -p /etc/iptables
cat > "$RULES" <<EOF
# GENERATED by wgctl.sh apply ($(date -Is))
# Single source of truth for the firewall. wg-quick PostUp adds no rules.
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
# Only VPN-sourced traffic is NAT'ed; an unrestricted MASQUERADE would also
# rewrite guest traffic leaving $EGRESS.
-A POSTROUTING -s $SUBNET -o $EGRESS -j MASQUERADE
COMMIT

*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
# ICMP from the LAN and the VPN only. Path MTU discovery still works, because
# ICMP errors for existing flows match the RELATED rule above.
-A INPUT -s $LAN -p icmp -j ACCEPT
-A INPUT -i $IFACE -s $SUBNET -p icmp -j ACCEPT
# WireGuard listen port
-A INPUT -p udp -m udp --dport $PORT -j ACCEPT
# Host services from the LAN
-A INPUT -s $LAN -p tcp -m multiport --dports $HOST_PORTS -j ACCEPT
# Host services from the VPN (a blanket "-i $IFACE -j ACCEPT" is deliberately absent)
-A INPUT -i $IFACE -s $SUBNET -p tcp -m multiport --dports $HOST_PORTS -j ACCEPT
# VPN <-> LAN forwarding
-A FORWARD -i $IFACE -o $EGRESS -j ACCEPT
-A FORWARD -i $EGRESS -o $IFACE -j ACCEPT
COMMIT
EOF
chmod 600 "$RULES"
iptables-restore --test < "$RULES" || die "generated rules.v4 is invalid; nothing was applied"
log "$RULES generated and syntax-checked"

# ------------------------------------------------- arm rollback, then apply
if [ "$ROLLBACK_SECS" -gt 0 ]; then
  rm -f "$COMMIT_FLAG"
  systemctl stop wgctl-rollback.timer 2>/dev/null || true
  systemd-run --quiet --unit=wgctl-rollback --on-active="${ROLLBACK_SECS}s" \
    /bin/bash -c "[ -f $COMMIT_FLAG ] || { /usr/sbin/iptables-restore < $BACKUP/iptables.live; logger -t wgctl 'firewall rolled back'; }"
  log "rollback armed: previous rules return in ${ROLLBACK_SECS}s unless committed"
fi

iptables-restore < "$RULES"
log "firewall applied"

# ---------------------------------------------------------------- sysctl
if ! grep -qs '^net.ipv4.ip_forward *= *1' /etc/sysctl.d/99-wireguard.conf 2>/dev/null; then
  echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-wireguard.conf
fi
sysctl -q -w net.ipv4.ip_forward=1

# ------------------------------------------------------------ apply to wg
systemctl enable "wg-quick@$IFACE" >/dev/null 2>&1 || true
if ip link show "$IFACE" >/dev/null 2>&1; then
  cur_addr=$(ip -4 -brief addr show "$IFACE" | awk '{print $3}')
  cur_port=$(wg show "$IFACE" listen-port 2>/dev/null || echo "")
  if [ "$cur_addr" = "$SERVER_IP/$PREFIX" ] && [ "$cur_port" = "$PORT" ]; then
    wg syncconf "$IFACE" <(wg-quick strip "$IFACE")   # peers only; tunnel stays up
    log "wg syncconf: peers updated without dropping the tunnel"
  else
    systemctl restart "wg-quick@$IFACE"
    log "address or port changed -> restarted wg-quick@$IFACE"
  fi
else
  systemctl start "wg-quick@$IFACE"
  log "started wg-quick@$IFACE"
fi

echo "APPLY-OK rollback=${ROLLBACK_SECS}s backup=$BACKUP"
