#!/bin/sh
# WireGuard client installer — one command on any Linux distribution.
#
#   sudo WG_CONF_B64='<blob>' sh -c "$(curl -fsSL <raw-url>/install.sh)"
#
# Generate the blob on the admin machine with `./wgctl.sh bootstrap <name>`.
# This script contains NO server-specific data; everything comes from the blob.
#
# Key-generation mode (the private key never leaves this machine):
#   sudo sh -c "$(curl -fsSL <raw-url>/install.sh)" -- --keygen --name <name>
#
# POSIX sh; does not require bash.

set -eu

IFACE="${WG_IFACE:-wg0}"
CONF_B64="${WG_CONF_B64:-}"
KEYGEN=0
NAME=""
DO_START="${WG_START:-1}"
DO_ENABLE="${WG_ENABLE:-0}"
ASSUME_YES="${WG_YES:-0}"

WG_DIR=/etc/wireguard
KEY_PLACEHOLDER='__PRIVATE_KEY__'

# ----------------------------------------------------------------- output
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$(printf '\033[32m'); C_WARN=$(printf '\033[33m')
  C_ERR=$(printf '\033[31m'); C_DIM=$(printf '\033[2m'); C_OFF=$(printf '\033[0m')
else
  C_OK=''; C_WARN=''; C_ERR=''; C_DIM=''; C_OFF=''
fi
info() { printf '%s==>%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
ok()   { printf '%s✓%s %s\n'  "$C_OK"  "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n'  "$C_WARN" "$C_OFF" "$*" >&2; }
die()  { printf '%s✗%s %s\n'  "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo WG_CONF_B64='<blob>' sh -c "$(curl -fsSL <url>/install.sh)"
  sudo sh -c "$(curl -fsSL <url>/install.sh)" -- --keygen --name <name>

Options:
  --conf-b64 <blob>   base64-encoded WireGuard config. Prefer the WG_CONF_B64
                      environment variable: arguments are world-readable
                      through /proc/*/cmdline, environments are not.
  --keygen            generate a keypair here and print the public key,
                      so the private key never leaves this machine
  --name <name>       peer name, used with --keygen
  --iface <name>      interface and config file name (default: wg0)
  --enable            start automatically at boot
  --no-start          do not bring the tunnel up after installing
  --yes               do not prompt
  --help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --conf-b64) CONF_B64="${2:-}"; shift 2 ;;
    --keygen)   KEYGEN=1; shift ;;
    --name)     NAME="${2:-}"; shift 2 ;;
    --iface)    IFACE="${2:-}"; shift 2 ;;
    --enable)   DO_ENABLE=1; shift ;;
    --no-start) DO_START=0; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --help|-h)  usage; exit 0 ;;
    --)         shift ;;
    *)          die "unknown option: $1  (see --help)" ;;
  esac
done

case "$IFACE" in
  *[!A-Za-z0-9_=+.-]*|'') die "invalid interface name: '$IFACE'" ;;
esac
[ ${#IFACE} -le 15 ] || die "interface name must be at most 15 characters: '$IFACE'"

[ "$(id -u)" -eq 0 ] || die "root required — run this with sudo"

# --------------------------------------------------------- distro detection
DISTRO=unknown; DISTRO_NAME=unknown
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO="${ID:-unknown}"
  DISTRO_NAME="${PRETTY_NAME:-$DISTRO}"
fi

PKG=''; PKG_INSTALL=''; PKG_REFRESH=''
if   command -v apt-get      >/dev/null 2>&1; then
  PKG=apt;    PKG_REFRESH='apt-get update -qq'; PKG_INSTALL='apt-get install -y -qq'
elif command -v dnf          >/dev/null 2>&1; then
  PKG=dnf;    PKG_INSTALL='dnf install -y -q'
elif command -v yum          >/dev/null 2>&1; then
  PKG=yum;    PKG_INSTALL='yum install -y -q'
elif command -v pacman       >/dev/null 2>&1; then
  PKG=pacman; PKG_INSTALL='pacman -S --noconfirm --needed'
elif command -v apk          >/dev/null 2>&1; then
  PKG=apk;    PKG_INSTALL='apk add --no-cache'
elif command -v zypper       >/dev/null 2>&1; then
  PKG=zypper; PKG_INSTALL='zypper --non-interactive install'
elif command -v xbps-install >/dev/null 2>&1; then
  PKG=xbps;   PKG_INSTALL='xbps-install -Sy'
elif command -v emerge       >/dev/null 2>&1; then
  PKG=emerge; PKG_INSTALL='emerge --quiet'
fi

info "system: $DISTRO_NAME  |  package manager: ${PKG:-none}  |  kernel: $(uname -r)"

# ------------------------------------------------------------- dependencies
pkg_for() {
  case "$1:$PKG" in
    wireguard-tools:emerge) echo net-vpn/wireguard-tools ;;
    wireguard-tools:*)      echo wireguard-tools ;;
    resolvconf:*)           echo openresolv ;;
    *)                      echo "$1" ;;
  esac
}

install_pkg() {
  _p=$(pkg_for "$1")
  [ -n "$PKG" ] || die "no supported package manager found; install '$_p' manually and retry"
  if [ -n "$PKG_REFRESH" ] && [ -z "${_refreshed:-}" ]; then
    info "refreshing package lists..."
    # shellcheck disable=SC2086
    $PKG_REFRESH >/dev/null 2>&1 || warn "could not refresh package lists, continuing"
    _refreshed=1
  fi
  info "installing: $_p"
  # shellcheck disable=SC2086
  $PKG_INSTALL $_p >/dev/null 2>&1 || die "failed to install '$_p' — install it manually and retry"
}

if command -v wg >/dev/null 2>&1 && command -v wg-quick >/dev/null 2>&1; then
  ok "wireguard-tools already present ($(wg --version 2>/dev/null | head -1))"
else
  install_pkg wireguard-tools
  command -v wg >/dev/null 2>&1 || die "'wg' still not found after installation"
  ok "wireguard-tools installed"
fi

# ----------------------------------------------------------- kernel module
if [ -d /sys/module/wireguard ]; then
  ok "wireguard kernel module loaded"
elif modprobe wireguard 2>/dev/null; then
  ok "wireguard kernel module loaded"
else
  # Built into kernels 5.6 and newer; older ones need dkms or the userspace build.
  if command -v wireguard-go >/dev/null 2>&1; then
    warn "no kernel module; falling back to wireguard-go (userspace)"
  else
    warn "could not load the wireguard kernel module (kernel: $(uname -r))"
    warn "kernels older than 5.6 need 'wireguard-dkms' or 'wireguard-go'"
  fi
fi

umask 077
mkdir -p "$WG_DIR"; chmod 700 "$WG_DIR"

# ------------------------------------------------------------ keygen mode
if [ "$KEYGEN" -eq 1 ]; then
  [ -n "$NAME" ] || die "--keygen requires --name"
  KEYDIR="$WG_DIR/$NAME.keys"
  mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
  if [ -s "$KEYDIR/private.key" ]; then
    warn "$KEYDIR/private.key already exists, keeping it"
  else
    wg genkey > "$KEYDIR/private.key"
    wg pubkey < "$KEYDIR/private.key" > "$KEYDIR/public.key"
    chmod 600 "$KEYDIR"/*
  fi
  ok "keypair ready (the private key never leaves this machine): $KEYDIR"
  echo
  info "register the peer from the admin machine:"
  echo
  printf '  ./wgctl.sh add-peer %s %s\n' "$NAME" "$(cat "$KEYDIR/public.key")"
  echo
  info "then finish here with the blob it prints:"
  printf '  sudo WG_CONF_B64=<blob> WG_IFACE=%s sh -c "$(curl -fsSL <url>/install.sh)"\n' "$NAME"
  exit 0
fi

# ------------------------------------------------------------- write config
[ -n "$CONF_B64" ] || {
  usage >&2
  echo >&2
  die "no config supplied: set WG_CONF_B64, or use --keygen"
}

CONF="$WG_DIR/$IFACE.conf"
TMP=$(mktemp "$WG_DIR/.$IFACE.XXXXXX") || die "could not create a temporary file"
trap 'rm -f "$TMP"' EXIT INT TERM
chmod 600 "$TMP"

printf '%s' "$CONF_B64" | tr -d ' \n\r\t' | base64 -d > "$TMP" 2>/dev/null \
  || die "could not decode the blob — is WG_CONF_B64 valid base64?"

grep -q '^\[Interface\]' "$TMP" || die "decoded content does not look like a WireGuard config"
grep -q '^\[Peer\]'      "$TMP" || die "no [Peer] section in the config"

# A blob from `add-peer` carries a placeholder instead of the private key,
# because that key was generated here by --keygen and never transmitted.
if grep -q "$KEY_PLACEHOLDER" "$TMP"; then
  KEYDIR="$WG_DIR/$IFACE.keys"
  [ -s "$KEYDIR/private.key" ] \
    || die "config expects a local private key but $KEYDIR/private.key is missing — run --keygen --name $IFACE first"
  PRIV=$(cat "$KEYDIR/private.key")
  sed "s|$KEY_PLACEHOLDER|$PRIV|" "$TMP" > "$TMP.k" && mv "$TMP.k" "$TMP"
  chmod 600 "$TMP"
  ok "local private key substituted into the config"
fi
grep -q '^PrivateKey' "$TMP" || die "no PrivateKey in the config"

# wg-quick needs resolvconf or resolvectl to honour a DNS line.
if grep -qi '^DNS' "$TMP"; then
  if ! command -v resolvconf >/dev/null 2>&1 && ! command -v resolvectl >/dev/null 2>&1; then
    warn "config sets DNS but neither resolvconf nor resolvectl is present"
    [ -n "$PKG" ] && install_pkg resolvconf || true
    if ! command -v resolvconf >/dev/null 2>&1 && ! command -v resolvectl >/dev/null 2>&1; then
      warn "dropping the DNS line; the tunnel will run without it"
      grep -vi '^DNS' "$TMP" > "$TMP.d" && mv "$TMP.d" "$TMP"
      chmod 600 "$TMP"
    fi
  fi
fi

if [ -f "$CONF" ] && ! cmp -s "$TMP" "$CONF"; then
  cp -a "$CONF" "$CONF.bak"
  warn "$CONF existed and differed; previous version saved as $CONF.bak"
fi
mv "$TMP" "$CONF"
chmod 600 "$CONF"
trap - EXIT INT TERM
ok "config written: $CONF"

# Ubuntu's AppArmor profile confines wg-quick to /etc/wireguard, which is where
# this config lives — so the confinement is satisfied.
[ -e /sys/module/apparmor ] && info "AppArmor active; config is under /etc/wireguard as required"

# ------------------------------------------------------------------- start
if [ "$DO_START" -eq 1 ]; then
  if ip link show "$IFACE" >/dev/null 2>&1; then
    info "$IFACE is already up, restarting it"
    wg-quick down "$IFACE" >/dev/null 2>&1 || true
  fi
  wg-quick up "$IFACE" || die "wg-quick up $IFACE failed"
  ok "$IFACE is up"

  info "waiting for a handshake..."
  i=0
  while [ "$i" -lt 10 ]; do
    HS=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -rn | head -1)
    [ -n "${HS:-}" ] && [ "$HS" -gt 0 ] && break
    i=$((i+1)); sleep 1
  done
  if [ -n "${HS:-}" ] && [ "$HS" -gt 0 ]; then
    ok "handshake complete — the tunnel is working"
    wg show "$IFACE" transfer | awk '{printf "  transfer: rx=%s tx=%s bytes\n", $2, $3}'
  else
    warn "no handshake within 10 seconds"
    warn "check that the peer is registered on the server, that the endpoint and"
    warn "port are correct, and that outbound UDP is not blocked here"
  fi
fi

if [ "$DO_ENABLE" -eq 1 ]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable "wg-quick@$IFACE" >/dev/null 2>&1 \
      && ok "enabled at boot" \
      || warn "systemctl enable failed"
  else
    warn "no systemd here; set up autostart yourself"
  fi
fi

echo
ok "done"
printf '  up     : sudo wg-quick up %s\n'   "$IFACE"
printf '  down   : sudo wg-quick down %s\n' "$IFACE"
printf '  status : sudo wg show %s\n'       "$IFACE"
