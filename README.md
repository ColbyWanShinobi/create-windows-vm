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

The scripts require `qemu-system-x86_64`, `qemu-img`, `mkfs.vfat`, `mtools`,
and KVM access. Windows 10/11 also require OVMF/edk2 UEFI firmware, Samba's
`smbd`, `curl` (to fetch the SPICE Guest Tools installer), and `xorriso` (to
create the unattended setup CD). They keep
separate VM disks in `.windows-vm/xp`, `.windows-vm/win10`, and
`.windows-vm/win11`, so all three can run at the same time. Each shares
`~/VMShare` automatically.
Clipboard integration requires SPICE Guest Tools in Windows; the shared folder
is automatically mapped as `S:` using QEMU's built-in SMB share. Windows 10/11
unattended setup downloads and installs SPICE Guest Tools, so clipboard sharing
and the shared folder are ready after the first login.

Windows activation is not bypassed. XP uses its configured default product key.
Windows 10 uses Microsoft's generic Windows 10 Pro setup key to select an
edition during the unattended install; it does not activate Windows. Override
either with `--product-key` when installing another edition or using your own
key. Windows can be activated later.

Run `./destroy.sh` to select and remove a VM, or pass its name directly (for
example, `./destroy.sh win11`). It does not remove `~/VMShare`.
