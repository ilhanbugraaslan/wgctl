#!/usr/bin/env bash
# wgctl.sh — manage the WireGuard server over SSH from this machine.
#
#   ./wgctl.sh status              interface, peers, handshakes, firewall, permissions
#   ./wgctl.sh apply               regenerate the server config and firewall
#   ./wgctl.sh list                list clients
#   ./wgctl.sh add <name> [ip]     new client, keys generated on the server
#   ./wgctl.sh add-peer <name> <pubkey> [ip]
#                                  register a client that generated its own key
#   ./wgctl.sh rm <name>           retire a client
#   ./wgctl.sh show <name>         print a client config
#   ./wgctl.sh qr <name>           print a QR code for phones
#   ./wgctl.sh fetch <name>        download a config into ./clients/
#   ./wgctl.sh bootstrap <name>    print the one-line installer for a new machine
#   ./wgctl.sh home-profile <name> LAN-safe variant of an existing client
#   ./wgctl.sh install <name>      print the commands to install a client here
#   ./wgctl.sh backups             list server-side backups
#   ./wgctl.sh rollback <ts>       restore a backup
#
# apply, add, add-peer and rm apply firewall changes behind a rollback guard:
# if a fresh SSH connection cannot be made afterwards, the server restores the
# previous ruleset on its own.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HERE/wg.env"
REMOTE_DIR=/opt/wgctl
ROLLBACK_SECS="${ROLLBACK_SECS:-90}"

CMD="${1:-status}"

# `init` creates wg.env, so it must run without one.
if [ "$CMD" != "init" ]; then
  [ -f "$ENV_FILE" ] || {
    echo "error: $ENV_FILE not found — run './wgctl.sh init' to create it" >&2
    exit 1
  }
  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE"; set +a
  : "${WG_SSH_HOST:?WG_SSH_HOST is not set in wg.env}"
fi

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_ok=; c_warn=; c_err=; c_dim=; c_off=; }

info() { printf '%s==>%s %s\n' "$c_dim" "$c_off" "$*"; }
ok()   { printf '%s✓%s %s\n'  "$c_ok" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n'  "$c_warn" "$c_off" "$*"; }
die()  { printf '%s✗%s %s\n'  "$c_err" "$c_off" "$*" >&2; exit 1; }

sh_() { ssh "$WG_SSH_HOST" "$@"; }

remote_env() {
  printf 'WG_IFACE=%q WG_PORT=%q WG_SUBNET=%q WG_SERVER_IP=%q WG_ENDPOINT=%q WG_LAN=%q WG_EGRESS=%q WG_HOST_PORTS=%q WG_CLIENT_DNS=%q WG_ALLOWED_IPS=%q ROLLBACK_SECS=%q' \
    "${WG_IFACE:-wg0}" "${WG_PORT:-51820}" "${WG_SUBNET:-10.10.0.0/24}" \
    "${WG_SERVER_IP:-10.10.0.1}" \
    "${WG_ENDPOINT:?WG_ENDPOINT is not set in wg.env}" \
    "${WG_LAN:?WG_LAN is not set in wg.env}" \
    "${WG_EGRESS:?WG_EGRESS is not set in wg.env}" \
    "${WG_HOST_PORTS:-22}" "${WG_CLIENT_DNS:-1.1.1.1}" \
    "${WG_ALLOWED_IPS:-10.10.0.0/24}" "$ROLLBACK_SECS"
}

push() {
  sh_ "mkdir -p $REMOTE_DIR && chmod 700 $REMOTE_DIR"
  scp -q "$HERE/remote/wg-apply.sh" "$HERE/remote/wg-client.sh" "$HERE/remote/wg-probe.sh" \
         "$WG_SSH_HOST:$REMOTE_DIR/"
  sh_ "chmod 700 $REMOTE_DIR/wg-apply.sh $REMOTE_DIR/wg-client.sh $REMOTE_DIR/wg-probe.sh"
}

client() {   # run wg-client.sh on the server
  local q=(); local a; for a in "$@"; do q+=("$(printf '%q' "$a")"); done
  sh_ "$(remote_env) $REMOTE_DIR/wg-client.sh ${q[*]}"
}

# Apply, then prove SSH still works before making the rules permanent.
apply() {
  push
  info "regenerating configuration on the server..."
  sh_ "$(remote_env) $REMOTE_DIR/wg-apply.sh" || die "apply failed — firewall unchanged"

  if [ "$ROLLBACK_SECS" -gt 0 ]; then
    info "verifying a fresh SSH connection (rollback fires in ${ROLLBACK_SECS}s)..."
    local tries=0
    until ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=no -o ControlPath=none \
              "$WG_SSH_HOST" true 2>/dev/null; do
      tries=$((tries+1))
      [ "$tries" -ge 5 ] && die "could not reconnect over SSH — NOT committed; the server reverts within ${ROLLBACK_SECS}s"
      sleep 3
    done
    sh_ "$REMOTE_DIR/wg-apply.sh commit" >/dev/null
    ok "SSH verified, rules made permanent"
  fi
}

need_name() { [ -n "${1:-}" ] || die "a name is required"; }

# One-line installer for a new machine. INSTALL_URL comes from wg.env.
print_bootstrap() {
  local name="$1" blob url
  url="${WG_INSTALL_URL:-<set WG_INSTALL_URL in wg.env>}"
  blob=$(client blob "$name")
  echo
  info "run this on the new machine:"
  echo
  printf '  sudo WG_CONF_B64=%s \\\n' "'$blob'"
  printf '    WG_IFACE=%s sh -c "$(curl -fsSL %s)"\n' "$name" "$url"
  echo
  # An externally-keyed peer ships a placeholder, so the blob carries no secret
  # beyond the preshared key; a server-keyed one carries the private key itself.
  if printf '%s' "$blob" | base64 -d 2>/dev/null | grep -q '__PRIVATE_KEY__'; then
    info "no private key in this blob — the installer fills in the one it generated locally"
  else
    warn "this blob contains a private key — send it over a private channel, and"
    warn "prefer the env-var form above: command arguments are world-readable in /proc"
  fi
}

# Prompt with a default; reads from the terminal even if stdin is redirected.
ask() {   # ask VAR "question" "default"
  local __var="$1" __q="$2" __def="${3:-}" __in=""
  if [ -r /dev/tty ]; then
    if [ -n "$__def" ]; then
      printf '  %s [%s]: ' "$__q" "$__def" > /dev/tty
    else
      printf '  %s: ' "$__q" > /dev/tty
    fi
    read -r __in < /dev/tty || true
  fi
  printf -v "$__var" '%s' "${__in:-$__def}"
}

case "$CMD" in

  init)
    echo
    info "wgctl setup — this writes $ENV_FILE"
    echo
    if [ -f "$ENV_FILE" ]; then
      warn "$ENV_FILE already exists; it will be backed up to wg.env.bak"
    fi

    ask SSH_HOST "SSH host for the server (user@host, or an ~/.ssh/config alias)" "${WG_SSH_HOST:-}"
    [ -n "$SSH_HOST" ] || die "an SSH host is required"

    info "testing SSH to $SSH_HOST ..."
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true 2>/dev/null \
      || die "cannot reach $SSH_HOST over SSH with key auth — set that up first (ssh-copy-id)"
    [ "$(ssh "$SSH_HOST" id -u)" = "0" ] \
      || die "$SSH_HOST must log in as root (wgctl configures the firewall and /etc/wireguard)"
    ok "SSH works and has root"

    info "probing the server..."
    ssh "$SSH_HOST" "mkdir -p $REMOTE_DIR && chmod 700 $REMOTE_DIR"
    scp -q "$HERE/remote/wg-probe.sh" "$SSH_HOST:$REMOTE_DIR/"
    PROBE=$(ssh "$SSH_HOST" "chmod 700 $REMOTE_DIR/wg-probe.sh && $REMOTE_DIR/wg-probe.sh")
    p() { printf '%s\n' "$PROBE" | sed -n "s/^$1=//p" | head -1; }

    echo
    printf '  %-16s %s\n' "os:"        "$(p OS)"
    printf '  %-16s %s\n' "kernel:"    "$(p KERNEL) (wireguard module: $(p WG_MODULE))"
    printf '  %-16s %s\n' "egress:"    "$(p EGRESS) — $(p SERVER_LAN_IP) on $(p LAN)"
    PUB_=$(p PUBLIC_IP)
    printf '  %-16s %s\n' "public ip:" "${PUB_:-unknown (no outbound access?)}"
    printf '  %-16s %s\n' "pkg mgr:"   "$(p PKG)"
    printf '  %-16s %s\n' "installed:" "wg=$(p HAS_WG) iptables=$(p HAS_IPTABLES) persistent=$(p HAS_PERSISTENT) qrencode=$(p HAS_QRENCODE)"
    [ "$(p IS_PROXMOX)" = yes ] && printf '  %-16s %s\n' "proxmox:" "yes"
    [ -n "$(p EXISTING_CONF)" ] && warn "existing WireGuard configs: $(p EXISTING_CONF)"
    echo

    DEF_PORTS=22
    [ "$(p IS_PROXMOX)" = yes ] && DEF_PORTS="22,8006"

    ask IFACE_    "interface name"                       "wg0"
    ask PORT_     "UDP listen port"                      "51820"
    ask SUBNET_   "VPN subnet"                           "10.10.0.0/24"
    SRV_DEFAULT="$(printf '%s' "${SUBNET_%%/*}" | sed 's/\.[0-9]*$/.1/')"
    ask SRVIP_    "server address inside the VPN"        "$SRV_DEFAULT"
    ask ENDPOINT_ "endpoint clients connect to (public IP or DDNS name)" "$(p PUBLIC_IP)"
    ask LANIP_    "server address on its LAN"            "$(p SERVER_LAN_IP)"
    ask LAN_      "server LAN subnet"                    "$(p LAN)"
    ask EGRESS_   "NAT egress interface"                 "$(p EGRESS)"
    ask PORTS_    "host TCP ports open to LAN and VPN"   "$DEF_PORTS"
    ask DNS_      "DNS servers pushed to clients"        "1.1.1.1, 1.0.0.1"
    ask ALLOWED_  "AllowedIPs for clients (split tunnel)" "$SUBNET_, $LAN_"
    ask URL_      "raw URL of install.sh (for bootstrap)" "${WG_INSTALL_URL:-}"

    [ -f "$ENV_FILE" ] && cp -a "$ENV_FILE" "$ENV_FILE.bak"
    umask 077
    cat > "$ENV_FILE" <<EOF
# Generated by \`wgctl.sh init\` on $(date -Is).
# This file is gitignored: it holds your endpoint and host details.

WG_SSH_HOST=$SSH_HOST
WG_IFACE=$IFACE_
WG_PORT=$PORT_
WG_SUBNET=$SUBNET_
WG_SERVER_IP=$SRVIP_

WG_ENDPOINT=$ENDPOINT_
WG_SERVER_LAN_IP=$LANIP_

WG_LAN=$LAN_
WG_EGRESS=$EGRESS_
WG_HOST_PORTS=$PORTS_

WG_CLIENT_DNS="$DNS_"
WG_ALLOWED_IPS="$ALLOWED_"

WG_INSTALL_URL=$URL_
EOF
    chmod 600 "$ENV_FILE"
    ok "wrote $ENV_FILE"
    echo
    ask RUN_ "apply this to the server now? (y/N)" "N"
    case "$RUN_" in
      [Yy]*) exec "$HERE/wgctl.sh" apply ;;
      *) info "when ready:  ./wgctl.sh apply" ;;
    esac
    ;;

  status)
    sh_ "$(remote_env) bash -s" <<'EOS'
set -u
I="${WG_IFACE:-wg0}"
echo "── interface ────────────────────────────────────────────"
ip -4 -brief addr show "$I" 2>/dev/null || echo "$I missing"
systemctl is-enabled "wg-quick@$I" 2>/dev/null | sed 's/^/  boot:   /'
systemctl is-active  "wg-quick@$I" 2>/dev/null | sed 's/^/  state:  /'
echo "  pubkey: $(wg show "$I" public-key 2>/dev/null || echo -)"
echo "  port:   $(wg show "$I" listen-port 2>/dev/null || echo -)"
echo
echo "── peers ────────────────────────────────────────────────"
now=$(date +%s); n=0
while read -r pub hs; do
  [ -z "${pub:-}" ] && continue
  n=$((n+1))
  name=$(awk -v k="$pub" '/^# /{c=substr($0,3)} $0 == "PublicKey = " k {print c; exit}' /etc/wireguard/wg0.conf 2>/dev/null)
  tr=$(wg show "$I" transfer | awk -v k="$pub" '$1==k{printf "rx=%s tx=%s", $2, $3}')
  if [ "${hs:-0}" -gt 0 ]; then h="$(( (now-hs)/60 ))m ago"; else h="never connected"; fi
  printf '  %-12s %-46s %-16s %s\n' "${name:-?}" "$pub" "$h" "$tr"
done < <(wg show "$I" latest-handshakes 2>/dev/null)
[ "$n" -eq 0 ] && echo "  (no peers)"
echo
echo "── firewall ─────────────────────────────────────────────"
# Normalise both sides the same way: drop comments, chain policies,
# table headers and COMMIT lines before comparing.
norm() { grep -vE '^#|^:|^\*|^COMMIT|^[[:space:]]*$' | sort; }
live=$(iptables-save | norm)
file=$(norm < /etc/iptables/rules.v4 2>/dev/null)
if [ "$live" = "$file" ]; then echo "  live rules match rules.v4 (reboot-safe)"
else echo "  WARNING: live rules differ from rules.v4 — rules will be lost on reboot"
     diff <(echo "$file") <(echo "$live") | sed 's/^/    /' | head -20; fi
echo "  ip_forward: $(sysctl -n net.ipv4.ip_forward)"
echo "  MASQUERADE: $(iptables -t nat -S POSTROUTING | grep -c MASQUERADE) rule(s)"
echo
echo "── permissions ──────────────────────────────────────────"
stat -c '  %A %n' /etc/wireguard /etc/wireguard/wg0.conf /etc/wireguard/clients 2>/dev/null
bad=$(find /etc/wireguard/clients -type f ! -perm 600 2>/dev/null | wc -l)
[ "$bad" -eq 0 ] && echo "  all client files are 600" || echo "  WARNING: $bad file(s) not 600"
EOS
    ;;

  apply)  apply ;;
  list)   push; client list ;;
  show)   need_name "${2:-}"; push; client show "$2" ;;
  qr)     need_name "${2:-}"; push; client qr "$2" ;;

  add)
    need_name "${2:-}"; push
    client add "$2" "${3:-}"
    apply
    ok "client '$2' added and applied"
    info "next: ./wgctl.sh bootstrap $2   (or: qr / fetch / install)"
    ;;

  add-peer)
    need_name "${2:-}"; [ -n "${3:-}" ] || die "a public key is required"
    push
    client add-peer "$2" "$3" "${4:-}"
    apply
    ok "peer '$2' registered (private key stays on the client)"
    print_bootstrap "$2"
    ;;

  rm)
    need_name "${2:-}"; push
    client rm "$2"
    apply
    ok "client '$2' removed"
    ;;

  bootstrap)
    need_name "${2:-}"; push
    print_bootstrap "$2"
    ;;

  fetch)
    need_name "${2:-}"; push
    mkdir -p "$HERE/clients"; chmod 700 "$HERE/clients"
    ( umask 077; client show "$2" > "$HERE/clients/$2.conf" )
    chmod 600 "$HERE/clients/$2.conf"
    ok "clients/$2.conf downloaded (contains a private key — do not share)"
    ;;

  home-profile)
    # Same peer key, but routing that leaves the LAN alone: VPN subnet only,
    # and the server's LAN address as the endpoint.
    need_name "${2:-}"
    [ -n "${WG_SERVER_LAN_IP:-}" ] || die "set WG_SERVER_LAN_IP in wg.env first (the server's address on its LAN)"
    push
    src="$HERE/clients/$2.conf"
    [ -f "$src" ] || { ( umask 077; client show "$2" > "$src" ); chmod 600 "$src"; }
    out="$HERE/clients/$2-home.conf"
    ( umask 077
      sed -E \
        -e "s#^Endpoint = .*#Endpoint = ${WG_SERVER_LAN_IP}:${WG_PORT}#" \
        -e "s#^AllowedIPs = .*#AllowedIPs = ${WG_SUBNET}#" \
        -e '/^DNS = /d' \
        -e "1s|^#.*|# $2-home — home profile (leaves the LAN route untouched)|" \
        -e 's|^# Split tunnel.*|# Only the VPN subnet is routed; the LAN is reachable directly.|' \
        "$src" > "$out" )
    chmod 600 "$out"
    ok "clients/$2-home.conf written (AllowedIPs=${WG_SUBNET}, endpoint on the LAN)"
    ;;

  install)
    # AppArmor confines wg-quick to /etc/wireguard, so the config must go there.
    need_name "${2:-}"; push
    mkdir -p "$HERE/clients"; chmod 700 "$HERE/clients"
    ( umask 077; client show "$2" > "$HERE/clients/$2.conf" )
    chmod 600 "$HERE/clients/$2.conf"
    ok "clients/$2.conf ready"
    echo
    info "these need root, so run them in your own terminal:"
    cat <<EOS

  sudo install -D -m 600 -o root -g root \\
    $HERE/clients/$2.conf /etc/wireguard/$2.conf

  sudo wg-quick up $2       # start
  sudo wg-quick down $2     # stop
  sudo systemctl enable --now wg-quick@$2   # start at boot

EOS
    ;;

  backups)
    sh_ 'ls -1 /root/wgctl-backups 2>/dev/null || echo "(no backups)"' ;;

  rollback)
    need_name "${2:-}"
    sh_ "test -d /root/wgctl-backups/$2" || die "no such backup: $2"
    warn "restoring backup: $2"
    sh_ "set -e
      B=/root/wgctl-backups/$2
      [ -f \$B/rules.v4 ] && cp -a \$B/rules.v4 /etc/iptables/rules.v4 && iptables-restore < /etc/iptables/rules.v4
      [ -f \$B/${WG_IFACE:-wg0}.conf ] && cp -a \$B/${WG_IFACE:-wg0}.conf /etc/wireguard/
      [ -f \$B/clients.tar.gz ] && rm -rf /etc/wireguard/clients && tar xzf \$B/clients.tar.gz -C /etc/wireguard
      systemctl restart wg-quick@${WG_IFACE:-wg0}"
    ok "restored: $2"
    ;;

  *) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
esac
