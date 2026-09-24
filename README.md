# OpenVPN Access Server LXC for Proxmox VE

A community script that creates an **unprivileged Debian 13 LXC container** on
Proxmox VE and installs a working, pre-configured
[OpenVPN Access Server](https://openvpn.net/access-server/) in it. Every setting
is asked through interactive `whiptail` dialogs.

> [!IMPORTANT]
> This is an independent open-source project. It is **not affiliated with,
> endorsed or supported by OpenVPN Inc.** or Proxmox Server Solutions GmbH.
> "OpenVPN" and "Access Server" are trademarks of OpenVPN Inc.; "Proxmox" is a
> trademark of Proxmox Server Solutions GmbH. OpenVPN Access Server is
> commercial software under its own license: without a subscription it allows
> a limited number of concurrent VPN connections.

## Quick start

Run this in the **Proxmox VE node shell** as `root`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cocardoso/proxmox-lxc-openvpn-as/main/openvpn-as-lxc.sh)"
```

To see every command without changing anything, add `--dry-run`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/cocardoso/proxmox-lxc-openvpn-as/main/openvpn-as-lxc.sh)" _ --dry-run
```

As always, read a script before piping it into a root shell.

## Requirements

- Proxmox VE **8.4 or newer**. Older `pct` versions reject Debian 13 containers.
- An **amd64** host. The `openvpn-as` package is only published for amd64 on Debian.
- Internet access from the container to `packages.openvpn.net` and `deb.debian.org`.
- A free **static IPv4 address** on the bridge you choose.

## What it asks

| Setting | Default |
|---------|---------|
| Container ID | next free ID |
| Hostname | `openvpn-as` |
| Container root password | — (min. 8 characters) |
| Template / disk storage | menu (auto-selected when there is only one) |
| Disk / CPU cores / memory | 8 GiB / 2 / 2048 MiB |
| Bridge | menu with the `vmbr*` bridges |
| VLAN tag | empty = no VLAN |
| IPv4/CIDR and gateway | required (static IP) |
| DNS servers | the gateway |
| Admin (`openvpn` user) password | — (min. 8 characters) |
| Public hostname or IP | the container IP (change it to your public DNS name) |
| VPN daemon TCP / UDP port | 443 / 1194 |

A summary screen asks for confirmation before anything is created.

## What it does

On the **host**:

- Adds `tun` to `/etc/modules-load.d/tun.conf`, unless `tun` is already listed in
  `/etc/modules` or `/etc/modules-load.d/`.
- Downloads the Debian 13 template for the host architecture if it is missing.
- Creates the container with `unprivileged: 1`, `features: nesting=1`,
  `onboot: 1` and `dev0: /dev/net/tun`. The TUN device passthrough is native
  since Proxmox VE 8.1, so there is no manual `lxc.cgroup2` or `mknod` setup.

Inside the **container**:

- Upgrades the base system.
- Adds the official repository (`http://packages.openvpn.net/as/debian trixie main`)
  and installs `openvpn-as`.
- Configures it with `sacli`: `host.name`, the TCP/UDP daemon ports and the
  `openvpn` user password.
- **Turns off DCO** (`vpn.server.daemon.ovpndco=false`). Access Server 3.x enables
  Data Channel Offload by default. The kernel `ovpn` module needs `CAP_NET_ADMIN`
  in the host namespace, so in an unprivileged container its netlink calls fail
  with `Operation not permitted` and the VPN daemons stop. Without DCO, the
  daemons use `/dev/net/tun`.
- Checks that every VPN daemon is running and the web UI is listening.

When it finishes, the script prints the URLs:

- Admin UI: `https://<container-ip>:943/admin` (user `openvpn`)
- Client UI: `https://<container-ip>:943/`, also served on the VPN TCP port

## Ports

| Port | Purpose | Expose to the internet? |
|------|---------|-------------------------|
| UDP 1194 (or your choice) | VPN over UDP (preferred) | Yes — port forward |
| TCP 443 (or your choice) | VPN over TCP + Client UI | Yes — port forward |
| TCP 943 | Admin UI and Client UI | No — keep it internal |

## Security notes

- Passwords are never shown, logged or passed on the host command line. They
  travel in a `0600` file copied with `pct push`, which the installer reads and
  deletes right away.
- One exception: `sacli SetLocalPassword` has no stdin option, so the admin
  password is briefly visible to root **inside** the container.
- The Access Server web certificate is self-signed. Replace it (for example,
  with Let's Encrypt from the Admin UI) before exposing the Client UI directly.

## Logs and troubleshooting

- Full log on the host: `/var/log/openvpn-as-lxc-<CTID>.log`.
- If anything fails after the container is created, the script offers to
  destroy it or keep it for inspection.

| Symptom | Check |
|---------|-------|
| `cannot resolve packages.openvpn.net` | Wrong IP, gateway, VLAN or DNS. Try `pct enter <id>` and `ping`. |
| VPN daemons `openvpn_N` are `off` | `sacli ConfigQuery \| grep ovpndco` must be `false`. See `/var/log/openvpnas.log` in the container. |
| Container does not start after a host reboot | `lsmod \| grep tun` and `cat /etc/modules-load.d/tun.conf` on the host. |
| Clients connect but no traffic passes | `pct config <id>` must show `dev0: /dev/net/tun`. |
| Admin UI does not load | `pct exec <id> -- /usr/local/openvpn_as/scripts/sacli status` |

## Tested on

- Proxmox VE 9.2.11 (kernel 7.0.14-14-pve), Debian 13.6 template, OpenVPN Access Server 3.2.2.

## Development

```bash
bash tests/run.sh             # runs the test suite in a debian:trixie Docker container
shellcheck openvpn-as-lxc.sh
```

The tests replace `pct`, `pveam`, `pvesm`, `pvesh`, `whiptail` and friends with
stubs in `tests/stubs`. They cover:

- input validation, cancellation and retries;
- passwords with special characters;
- a missing template, storage or bridge, and too-old Proxmox VE versions;
- rollback after a failure, and that no password reaches the logs;
- the `bash -c "$(curl …)"` entry point.

They do not replace a run on a real node.

## License

[MIT](LICENSE)
