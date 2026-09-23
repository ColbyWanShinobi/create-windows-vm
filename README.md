# create-windows-vm

Start a Windows VM from an ISO:

```bash
./create.sh /path/to/Windows.iso
```

By default, setup is unattended. The script detects XP, Windows 10, or Windows
11 from the ISO filename; use `--os xp`, `--os win10`, or `--os win11` when the
filename is ambiguous. It creates a local administrator account with username
`gumby` and password `gumby`. Use `--username` and `--password`
to choose your own credentials, or `--interactive` to use the normal Windows
setup UI.

Optional settings are `--ram`, `--cpus` (or `--threads`), and `--disk-size`:

```bash
./create.sh Windows.iso --ram 16G --cpus 8 --disk-size 120G
```

The scripts require `qemu-system-x86_64`, `qemu-img`, `remote-viewer` (from
the `virt-viewer` package), `mkfs.vfat`, `mtools`, and KVM access. Windows
10/11 also require OVMF/edk2 UEFI firmware, Samba's `smbd`, `curl` (to fetch
the SPICE Guest Tools installer), `7z` (to stage the QXL driver), and `xorriso`
(to create the unattended setup CD). They keep
separate VM disks in `.windows-vm/xp`, `.windows-vm/win10`, and
`.windows-vm/win11`, so all three can run at the same time. Each shares
`~/VMShare` automatically.
Clipboard integration requires SPICE Guest Tools in Windows; the shared folder
is automatically mapped as `S:` using QEMU's built-in SMB share. Use
`--share-dir /path/to/folder` to choose a different host folder; that selection
is saved per VM and used on later `run.sh` starts. Windows 10/11
unattended setup downloads and installs SPICE Guest Tools, so clipboard sharing
and the shared folder are ready after the first login. It also installs the
bundled QXL display driver explicitly; installer output is saved in
`C:\spice-guest-tools-install.log`.

The VM opens in Remote Viewer over a local SPICE socket. For Windows 10/11,
SPICE Guest Tools includes the QXL display driver; resize the Remote Viewer
window to change the guest's display resolution. Closing Remote Viewer stops
the VM, just as closing the previous QEMU display window did.

Windows activation is not bypassed. XP uses its configured default product key.
Windows 10 uses Microsoft's generic Windows 10 Pro setup key to select an
edition during the unattended install; it does not activate Windows. Override
either with `--product-key` when installing another edition or using your own
key. Windows can be activated later.

Run `./destroy.sh` to select and remove a VM, or pass its name directly (for
example, `./destroy.sh win11`). It does not remove `~/VMShare`.

## Network modes

`create.sh` and `run.sh` default to QEMU's private NAT network. It provides
outbound Internet access and the `S:` host share without changing the host's
NetworkManager connection. The guest is not a direct LAN peer and cannot accept
unsolicited inbound connections from other LAN devices in this mode.

```bash
./run.sh
./run.sh win11 --remote-access
```

For a guest with its own LAN DHCP address, direct access to local-network
devices, and direct inbound LAN connectivity (for example, SSH or WinRM), use
the bridged mode. This moves the host's IP configuration from its physical
uplink onto `br0`, so set it up only while bridged networking is needed:

```bash
sudo ./setup-lan-bridge.sh
./run_with_bridging.sh
./run_with_bridging.sh win11 --remote-access
```

This auto-detects the current physical uplink and creates `br0` plus the
persistent, user-owned `br0-tap` interface. Use `--bridge`, `--uplink`, or
`--tap` to override those defaults. The launcher verifies both before it starts
QEMU, so it cannot create a partially configured VM disk when bridge setup is
missing. The guest's LAN interface is primary and receives its own DHCP lease;
find it in Windows with `ipconfig`.

### Routine switching commands

To return to bridged LAN mode after using Proton VPN, run these commands from
this repository. The setup helper reconnects the host briefly while moving its
network configuration onto `br0`.

```bash
sudo ./setup-lan-bridge.sh
./run_with_bridging.sh
```

To return to the normal, non-bridged host connection for Proton VPN, close the
VM first, then run:

```bash
sudo ./teardown-lan-bridge.sh
./run.sh
```

`run.sh` does not require bridge setup. Its VM has Internet access and the `S:`
share through private NAT, but it will not have a directly reachable LAN IP.

### Switching back for Proton VPN

Bridging changes the host's active NetworkManager connection. Some Proton VPN
WireGuard/NetworkManager versions cannot create their temporary VPN route while
the host is using that bridge. Before using Proton VPN, stop the VM, then
restore normal host networking:

```bash
sudo ./teardown-lan-bridge.sh
```

The setup helper records the exact connection profile it replaced. The teardown
helper activates that profile and verifies it is active before removing only the
`Windows VM bridge (...)`, `Windows VM uplink (...)`, and `br0-tap` resources.
Run `sudo ./setup-lan-bridge.sh` again whenever you need bridged LAN access for
the VM.

If the bridge was created before this recording feature existed, teardown may
not find a compatible original profile. It deliberately stops without removing
anything. Confirm the intended physical uplink, create/activate a normal DHCP
profile for it, then rerun teardown with that profile explicitly. For this
machine's current uplink, the recovery commands are:

```bash
nmcli connection add type ethernet ifname enp9s0 \
  con-name 'Wired connection (enp9s0)' ipv4.method auto ipv6.method auto
nmcli connection up 'Wired connection (enp9s0)' ifname enp9s0
sudo ./teardown-lan-bridge.sh --bridge br0 --uplink enp9s0 \
  --restore 'Wired connection (enp9s0)'
```

Do not use these recovery commands on a network that requires static addresses,
custom DNS, 802.1X, or VLAN settings; create a replacement profile with those
same settings instead.

New unattended Windows 10/11 VMs automatically enable WinRM (TCP 5985). They
also install and start OpenSSH Server (TCP 22) when Windows can obtain the
optional OpenSSH capability. In bridged mode, find the guest address with
`ipconfig` and connect from the host or another LAN device with
`ssh USERNAME@GUEST_LAN_ADDRESS`.

Then start the existing VM and mount its remote-access CD:

```bash
./run_with_bridging.sh win10 --remote-access
```

In the Windows console, open the `REMOTE_ACCESS` CD and run the script from an
elevated PowerShell window. A process-only execution-policy bypass avoids
changing Windows policy permanently:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\enable-remote.ps1
```

It enables authenticated WinRM and installs/enables OpenSSH Server when the
Windows OpenSSH capability is available. If Windows Update was unavailable
during unattended setup, this is also how to retry the OpenSSH installation.
In bridged mode, the LAN NIC is primary; a second private NIC retains the `S:`
SMB share for Windows 10/11.

To start an existing VM without its installer ISO, run `./run.sh`. If more
than one exists, choose one interactively or pass its name, for example
`./run.sh win11`. Use `--ram`, `--cpus`, or `--share-dir` to override the
runtime defaults.
