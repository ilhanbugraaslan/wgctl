# wgctl

A small WireGuard server toolkit: manage peers on a Linux/Proxmox host over SSH,
and bring up a new client on any distribution with one command.

```sh
# one-time setup — probes the server and asks about anything it cannot detect
./wgctl.sh init
./wgctl.sh apply

# create a peer and print its installer
./wgctl.sh add laptop
./wgctl.sh bootstrap laptop

# on the new machine — install, configure and connect
sudo WG_CONF_B64='<blob>' WG_IFACE=laptop sh -c "$(curl -fsSL https://raw.githubusercontent.com/ilhanbugraaslan/wgctl/main/install.sh)"
```

`install.sh` contains no server-specific data. The endpoint, keys and addresses
all travel inside the blob that `bootstrap` generates locally, so the published
script stays generic.

## Design

The `clients/` directory on the server is the single source of truth.
`wg0.conf` and `/etc/iptables/rules.v4` are **generated** from it — never
hand-edited.

```
/etc/wireguard/clients/<name>/{private,public,preshared}.key + <name>.conf
        │
        └── apply ──► /etc/wireguard/wg0.conf     (peer list)
                  └► /etc/iptables/rules.v4       (NAT + filter)
```

Firewall rules live in `rules.v4`, not in a `wg-quick` `PostUp` hook. That keeps
them from being appended again on every restart, and makes the state after a
reboot identical to the state before it.

## Setup

```sh
./wgctl.sh init
```

The wizard connects to the server, detects what it can, and asks about the rest:

| Detected automatically | Asked, with the detection as the default |
|---|---|
| egress interface, LAN subnet, server LAN address | VPN subnet and server VPN address |
| public IP | endpoint clients dial (public IP or DDNS name) |
| package manager, distribution, kernel | UDP listen port, interface name |
| whether the host is Proxmox | host TCP ports to open, client DNS, AllowedIPs |

It writes `wg.env`, which is gitignored. `apply` then installs anything missing
on the server — `wireguard-tools`, `iptables`, and rule persistence — using
whichever package manager it found, and falls back to a small systemd unit on
distributions without `iptables-persistent`.

Requirements on your side: key-based SSH to the server **as root**.

## Server commands

```sh
./wgctl.sh init                # interactive setup, writes wg.env
./wgctl.sh status              # interface, peers, handshakes, rule drift, permissions
./wgctl.sh list                # client table
./wgctl.sh add <name> [ip]     # new client (server generates the keys)
./wgctl.sh add-peer <name> <pubkey> [ip]
                               # register a client that generated its own key
./wgctl.sh rm <name>           # retire a client (kept as a backup)
./wgctl.sh bootstrap <name>    # print the one-line installer for a new machine
./wgctl.sh show <name>         # print a config
./wgctl.sh qr <name>           # QR code for phones
./wgctl.sh fetch <name>        # download a config into ./clients/
./wgctl.sh install <name>      # print the commands to install a client here
./wgctl.sh home-profile <name> # LAN-safe variant of an existing client
./wgctl.sh apply               # regenerate config + firewall
./wgctl.sh backups             # list server-side backups
./wgctl.sh rollback <ts>       # restore a backup
```

Settings live in `wg.env`, created by `init` (or copy `wg.env.example`). It is
gitignored, since it holds your endpoint and host details.

## Client installer

```sh
sudo WG_CONF_B64='<blob>' WG_IFACE=<name> sh -c "$(curl -fsSL <url>/install.sh)"
```

It detects the distribution, installs `wireguard-tools` through whichever
package manager is present (apt, dnf, yum, pacman, apk, zypper, xbps, emerge),
checks the kernel module, writes the config to `/etc/wireguard/`, brings the
tunnel up and waits for a handshake.

Options: `--enable` (start at boot), `--no-start`, `--iface <name>`.

### Keeping the private key on the client

If you would rather the private key never travel, generate it on the target
machine instead:

```sh
# on the new machine
sudo sh -c "$(curl -fsSL <url>/install.sh)" -- --keygen --name laptop2

# on the admin machine, with the public key it printed
./wgctl.sh add-peer laptop2 <pubkey>

# back on the new machine, with the blob that printed
sudo WG_CONF_B64='<blob>' WG_IFACE=laptop2 sh -c "$(curl -fsSL <url>/install.sh)"
```

The blob carries a `__PRIVATE_KEY__` placeholder that the installer replaces
with the key already stored locally.

## Locking yourself out

`apply` arms a rollback timer on the server before touching the firewall. The
local script then opens a **fresh** SSH connection to prove access still works
and only then sends `commit` to cancel the timer. If it cannot reconnect, the
server restores the previous ruleset within 90 seconds by itself.

Disable with `ROLLBACK_SECS=0 ./wgctl.sh apply` (not recommended).

## Backups

Every `apply` writes a full backup to `/root/wgctl-backups/<timestamp>/`:
`iptables.live`, `rules.v4`, `wg0.conf`, `clients.tar.gz`. Removed clients are
moved to `/root/wgctl-backups/removed/` rather than deleted.

## Requirements

Server: `systemd` and root SSH access. `apply` installs `wireguard-tools`,
`iptables` and rule persistence itself; `qrencode` is only needed for QR codes.
Admin machine: `ssh` and `scp`. Client: none — the installer handles it.

## Gotcha: AppArmor on Ubuntu

`/etc/apparmor.d/wg-quick` restricts `wg-quick` to reading `/etc/wireguard/`:

```
file rw @{etc_rw}/wireguard/{,**},
```

So `sudo wg-quick up ./some/path/x.conf` fails with **Permission denied** even
as root. Copy the config into `/etc/wireguard/` first and use the short name:

```sh
sudo install -D -m 600 clients/<name>.conf /etc/wireguard/<name>.conf
sudo wg-quick up <name>
```

`install.sh` and `wgctl.sh install` already do this.

## Two profiles for a client on the server's own LAN

A machine sitting on the same LAN as the server cannot use a split-tunnel
profile that includes that LAN: `wg-quick` would add a second route for it, the
default gateway would resolve through the tunnel, and routing would loop.

`./wgctl.sh home-profile <name>` writes a second file using the same peer key:

| Profile | AllowedIPs | Endpoint | Use |
|---|---|---|---|
| `<name>` | VPN subnet + server LAN | public IP | away from home |
| `<name>-home` | VPN subnet only | server LAN IP | on the server's LAN |

Both use the same peer address, so only one can be up at a time.
