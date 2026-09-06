#!/usr/bin/env bash
# wg-client.sh — runs ON THE SERVER. Manages client directories.
# Peers are never written to wg0.conf here; wg-apply.sh regenerates that file
# from the clients/ directory, which is the single source of truth.
#
#   add <name> [ip]              new client (server generates key + PSK)
#   add-peer <name> <pub> [ip]   register a client that generated its own key
#   rm <name>                    retire a client (kept as a backup)
#   list                         table of clients
#   show <name>                  print the client config
#   blob <name>                  base64 of the client config, for install.sh
#   qr <name>                    print a QR code

set -euo pipefail

IFACE="${WG_IFACE:-wg0}"
PORT="${WG_PORT:-51825}"
SERVER_IP="${WG_SERVER_IP:-10.10.0.1}"
ENDPOINT="${WG_ENDPOINT:?WG_ENDPOINT is required}"
DNS="${WG_CLIENT_DNS:-1.1.1.1, 1.0.0.1}"
ALLOWED="${WG_ALLOWED_IPS:-10.10.0.0/24}"

WG_DIR=/etc/wireguard
CLIENTS_DIR="$WG_DIR/clients"
TRASH=/root/wgctl-backups/removed
KEY_PLACEHOLDER='__PRIVATE_KEY__'

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,14}$ ]] \
    || die "invalid name: '$1' (A-Z a-z 0-9 . _ -, max 15 chars so it can be an interface name)"
}

valid_key() {
  [[ "$1" =~ ^[A-Za-z0-9+/]{42}[A-Za-z0-9+/]=$ ]] || die "not a valid WireGuard public key: '$1'"
}

# Address of a client: the 'address' file for externally-keyed peers,
# otherwise parsed out of its config.
client_addr() {
  local n="$1" d="$CLIENTS_DIR/$1"
  if [ -s "$d/address" ]; then
    cat "$d/address"
  else
    sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*\([^,[:space:]]*\).*/\1/p' \
      "$d/$n.conf" 2>/dev/null | head -1 | cut -d/ -f1
  fi
}

next_ip() {
  local net="${SERVER_IP%.*}" used=" " d a n
  used+="${SERVER_IP##*.} "
  for d in "$CLIENTS_DIR"/*/; do
    [ -d "$d" ] || continue
    a=$(client_addr "$(basename "$d")") || true
    [ -n "${a:-}" ] && used+="${a##*.} "
  done
  for n in $(seq 2 254); do
    [[ "$used" == *" $n "* ]] || { echo "$net.$n"; return; }
  done
  die "no free addresses left in $net.0/24"
}

claim_ip() {   # $1 = requested ip or empty
  local ip="${1:-}" o
  if [ -n "$ip" ]; then
    for o in "$CLIENTS_DIR"/*/; do
      [ -d "$o" ] || continue
      [ "$(client_addr "$(basename "$o")")" = "$ip" ] \
        && die "$ip is already used by $(basename "$o")"
    done
    echo "$ip"
  else
    next_ip
  fi
}

write_conf() {   # $1=name $2=ip $3=private-key-or-placeholder $4=dir
  local name="$1" ip="$2" priv="$3" d="$4"
  cat > "$d/$name.conf" <<EOF
# $name — WireGuard client
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = $DNS

[Peer]
PublicKey = $(cat "$WG_DIR/server_public.key")
PresharedKey = $(cat "$d/preshared.key")
Endpoint = $ENDPOINT:$PORT
# Split tunnel: only these networks are routed through the tunnel.
AllowedIPs = $ALLOWED
PersistentKeepalive = 25
EOF
}

cmd_add() {
  local name="${1:?name required}" ip
  valid_name "$name"
  local d="$CLIENTS_DIR/$name"
  [ -e "$d" ] && die "'$name' already exists (remove it first: rm $name)"
  ip=$(claim_ip "${2:-}")

  umask 077
  mkdir -p "$d"; chmod 700 "$d"
  wg genkey > "$d/private.key"
  wg pubkey < "$d/private.key" > "$d/public.key"
  wg genpsk > "$d/preshared.key"
  write_conf "$name" "$ip" "$(cat "$d/private.key")" "$d"
  chmod 600 "$d"/*
  echo "added: $name -> $ip"
}

# The client generated its own key; only the public key reached the server.
cmd_add_peer() {
  local name="${1:?name required}" pub="${2:?public key required}" ip
  valid_name "$name"; valid_key "$pub"
  local d="$CLIENTS_DIR/$name"
  [ -e "$d" ] && die "'$name' already exists (remove it first: rm $name)"
  ip=$(claim_ip "${3:-}")

  umask 077
  mkdir -p "$d"; chmod 700 "$d"
  printf '%s\n' "$pub" > "$d/public.key"
  printf '%s\n' "$ip"  > "$d/address"
  wg genpsk > "$d/preshared.key"
  : > "$d/external"          # marker: private key lives on the client
  write_conf "$name" "$ip" "$KEY_PLACEHOLDER" "$d"
  chmod 600 "$d"/*
  echo "added: $name -> $ip (external key)"
}

cmd_rm() {
  local name="${1:?name required}"
  valid_name "$name"
  local d="$CLIENTS_DIR/$name"
  [ -d "$d" ] || die "'$name' does not exist"
  mkdir -p "$TRASH"; chmod 700 "$TRASH"
  mv "$d" "$TRASH/$name-$(date +%Y%m%d-%H%M%S)"
  echo "removed: $name (backup in $TRASH/)"
}

cmd_list() {
  printf '%-14s %-12s %-46s %-9s %s\n' NAME IP "PUBLIC KEY" KEY STATUS
  printf '%-14s %-12s %-46s %-9s %s\n' "-----" "-----" "-----" "-----" "-----"
  shopt -s nullglob
  local any=0 d name pub ip st kind hs now
  now=$(date +%s)
  for d in "$CLIENTS_DIR"/*/; do
    any=1
    name=$(basename "$d")
    pub=$(cat "$d/public.key" 2>/dev/null || echo "-")
    ip=$(client_addr "$name"); ip="${ip:--}"
    kind=$([ -e "$d/external" ] && echo external || echo server)
    st="not in $IFACE"
    if wg show "$IFACE" peers 2>/dev/null | grep -qxF "$pub"; then
      hs=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk -v k="$pub" '$1==k{print $2}')
      if [ "${hs:-0}" -gt 0 ]; then st="handshake $(( (now-hs)/60 ))m ago"
      else st="registered, never connected"; fi
    fi
    printf '%-14s %-12s %-46s %-9s %s\n' "$name" "$ip" "$pub" "$kind" "$st"
  done
  [ "$any" -eq 0 ] && echo "(no clients)"
  return 0
}

cmd_show() { local n="${1:?name required}"; valid_name "$n"; cat "$CLIENTS_DIR/$n/$n.conf"; }
cmd_blob() { local n="${1:?name required}"; valid_name "$n"; base64 -w0 < "$CLIENTS_DIR/$n/$n.conf"; echo; }
cmd_qr() {
  local n="${1:?name required}"; valid_name "$n"
  [ -e "$CLIENTS_DIR/$n/external" ] \
    && die "'$n' has an external key; its config has no private key, so a QR code is useless"
  qrencode -t ansiutf8 < "$CLIENTS_DIR/$n/$n.conf"
}

case "${1:-}" in
  add)      shift; cmd_add      "$@" ;;
  add-peer) shift; cmd_add_peer "$@" ;;
  rm)       shift; cmd_rm       "$@" ;;
  list)     shift; cmd_list     "$@" ;;
  show)     shift; cmd_show     "$@" ;;
  blob)     shift; cmd_blob     "$@" ;;
  qr)       shift; cmd_qr       "$@" ;;
  *) die "usage: wg-client.sh {add|add-peer|rm|list|show|blob|qr} ..." ;;
esac
