#!/usr/bin/env bash
# Start an existing Windows VM created by create.sh.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VM_ROOT="$SCRIPT_DIR/.windows-vm"
SHARE_DIR="$HOME/VMShare"
SHARE_DIR_EXPLICIT=0
RAM="8G"
CPUS="4"
NETWORK="user"
BRIDGE="br0"
TAP=""
REMOTE_ACCESS=0

usage() {
  cat <<'EOF'
Usage: ./run.sh [xp|win10|win11] [options]

Options:
  -m, --ram SIZE       Guest memory (default: 8G)
  -c, --cpus COUNT     Guest CPU threads (default: 4)
      --share-dir PATH Host folder mapped as S: (default: ~/VMShare)
      --network MODE   bridge (LAN DHCP) or user (private NAT, default)
      --bridge NAME    Host bridge for --network bridge (default: br0)
      --tap NAME       TAP device for --network bridge (default: BRIDGE-tap)
      --remote-access  Mount a CD containing enable-remote.ps1
  -h, --help           Show this help

When no OS is supplied, the only existing VM is started automatically. If
multiple VMs exist, choose one interactively or specify xp, win10, or win11.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

requested=""
while (($#)); do
  case "$1" in
    -m|--ram)
      (($# >= 2)) || die "$1 requires a value"
      RAM=$2
      shift 2
      ;;
    -c|--cpus|--threads)
      (($# >= 2)) || die "$1 requires a value"
      CPUS=$2
      shift 2
      ;;
    --share-dir)
      (($# >= 2)) || die "$1 requires a value"
      SHARE_DIR=$2
      SHARE_DIR_EXPLICIT=1
      shift 2
      ;;
    --network)
      (($# >= 2)) || die "$1 requires a value"
      NETWORK=${2,,}
      shift 2
      ;;
    --bridge)
      (($# >= 2)) || die "$1 requires a value"
      BRIDGE=$2
      shift 2
      ;;
    --tap)
      (($# >= 2)) || die "$1 requires a value"
      TAP=$2
      shift 2
      ;;
    --remote-access)
      REMOTE_ACCESS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) die "Unknown option: $1" ;;
    xp|win10|win11)
      [[ -z "$requested" ]] || die "Only one OS may be supplied"
      requested=$1
      shift
      ;;
    *) die "Unknown OS or option: $1" ;;
  esac
done

[[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || die "CPU thread count must be a positive integer"
[[ "$RAM" =~ ^[1-9][0-9]*([MmGg])?$ ]] || die "RAM must look like 8G or 4096M"
[[ "$NETWORK" == bridge || "$NETWORK" == user ]] || die "--network must be bridge or user"
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Bridge name contains unsupported characters"
[[ -n "$TAP" ]] || TAP="${BRIDGE}-tap"
[[ "$TAP" =~ ^[A-Za-z0-9_.-]+$ ]] || die "TAP name contains unsupported characters"
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 is required"
command -v remote-viewer >/dev/null || die "remote-viewer is required (install the virt-viewer package for dynamic resolution)"

available=()
for os_type in xp win10 win11; do
  [[ -f "$VM_ROOT/$os_type/windows.qcow2" ]] && available+=("$os_type")
done

if [[ -n "$requested" ]]; then
  [[ -f "$VM_ROOT/$requested/windows.qcow2" ]] || die "No existing $requested VM found"
  OS_TYPE=$requested
elif ((${#available[@]} == 0)); then
  die "No existing VM disks found in $VM_ROOT; create one first with create.sh"
elif ((${#available[@]} == 1)); then
  OS_TYPE=${available[0]}
elif [[ -t 0 ]]; then
  PS3='Choose a VM to start (or cancel): '
  select choice in "${available[@]}" Cancel; do
    [[ -n "$choice" ]] || { printf 'Invalid selection.\n' >&2; continue; }
    [[ "$choice" != Cancel ]] || exit 0
    OS_TYPE=$choice
    break
  done
else
  die "More than one VM exists; specify xp, win10, or win11"
fi

VM_DIR="$VM_ROOT/$OS_TYPE"
DISK_IMAGE="$VM_DIR/windows.qcow2"
PID_FILE="$VM_DIR/qemu.pid"
SPICE_SOCKET="$VM_DIR/spice.sock"
UEFI_VARS="$VM_DIR/OVMF_VARS.fd"
SHARE_DIR_FILE="$VM_DIR/share-dir"
REMOTE_ACCESS_ISO="$VM_DIR/remote-access.iso"

if [[ -f "$PID_FILE" ]]; then
  old_pid=$(<"$PID_FILE")
  process_args=$(ps -p "$old_pid" -o args= 2>/dev/null || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && [[ "$process_args" == *qemu-system-x86_64* ]] && [[ "$process_args" == *"$VM_DIR"* ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "The $OS_TYPE VM is already running (PID $old_pid)"
  fi
  rm -f "$PID_FILE"
fi
rm -f -- "$SPICE_SOCKET"

if [[ -s "$SHARE_DIR_FILE" && $SHARE_DIR_EXPLICIT -eq 0 ]]; then
  IFS= read -r SHARE_DIR < "$SHARE_DIR_FILE"
fi
if [[ ! -s "$SHARE_DIR_FILE" || $SHARE_DIR_EXPLICIT -eq 1 ]]; then
  printf '%s\n' "$SHARE_DIR" > "$SHARE_DIR_FILE"
fi

mkdir -p "$SHARE_DIR"
if [[ "$NETWORK" == bridge ]]; then
  [[ -d "/sys/class/net/$BRIDGE" ]] || die "Bridge $BRIDGE does not exist. Create it once with: sudo ./setup-lan-bridge.sh --bridge $BRIDGE"
  [[ -e "/sys/class/net/$TAP" ]] || die "TAP $TAP does not exist. Run: sudo ./setup-lan-bridge.sh --bridge $BRIDGE --tap $TAP"
fi
if ((REMOTE_ACCESS)); then
  [[ "$OS_TYPE" != xp ]] || die "--remote-access supports Windows 10/11 only"
  command -v xorriso >/dev/null || die "xorriso is required for --remote-access"
  remote_tmp=$(mktemp -d "$VM_DIR/remote-access.XXXXXX")
  cp "$SCRIPT_DIR/enable-remote.ps1" "$remote_tmp/enable-remote.ps1"
  xorriso -overwrite on -as mkisofs -quiet -V REMOTE_ACCESS -o "$REMOTE_ACCESS_ISO" "$remote_tmp"
  rm -rf -- "$remote_tmp"
fi
QEMU_ARGS=(
  -name "Windows $OS_TYPE"
  -enable-kvm
  -cpu host
  -smp "$CPUS"
  -m "$RAM"
  -boot order=c
  -drive "file=$DISK_IMAGE,format=qcow2,if=ide"
  -display none
  -spice "unix=on,addr=$SPICE_SOCKET,disable-ticketing=on,disable-copy-paste=off"
  -device virtio-serial-pci
  -chardev spicevmc,id=vdagent,name=vdagent
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
)

if [[ "$OS_TYPE" == xp ]]; then
  QEMU_ARGS+=(
    -machine pc,accel=kvm,kernel-irqchip=split
    -usb
    -device usb-tablet
  )
else
  OVMF_CODE=""
  for candidate in /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/OVMF/OVMF_CODE.fd; do
    [[ -r "$candidate" ]] && OVMF_CODE=$candidate && break
  done
  [[ -n "$OVMF_CODE" ]] || die "OVMF firmware is required for Windows 10/11"
  [[ -f "$UEFI_VARS" ]] || die "No OVMF variable store found for $OS_TYPE; create the VM again with create.sh"
  QEMU_ARGS+=(
    -machine q35,accel=kvm
    -vga qxl
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$UEFI_VARS"
    -device qemu-xhci,id=xhci
    -device usb-tablet,bus=xhci.0
  )
fi

if [[ "$NETWORK" == bridge ]]; then
  QEMU_ARGS+=(
    -netdev "tap,id=lan0,ifname=$TAP,script=no,downscript=no"
  )
  [[ "$OS_TYPE" == xp ]] && QEMU_ARGS+=( -device rtl8139,netdev=lan0 ) || QEMU_ARGS+=( -device e1000e,netdev=lan0 )
  # Keep the existing SMB share reachable at 10.0.2.4 while the first NIC
  # receives its own DHCP lease from the physical LAN.
  [[ "$OS_TYPE" == xp ]] || QEMU_ARGS+=( -netdev "user,id=share0,smb=$SHARE_DIR" -device e1000e,netdev=share0 )
else
  [[ "$OS_TYPE" == xp ]] && QEMU_ARGS+=( -nic user,model=rtl8139 ) || QEMU_ARGS+=( -nic "user,model=e1000e,smb=$SHARE_DIR" )
fi

if ((REMOTE_ACCESS)); then
  QEMU_ARGS+=( -drive "file=$REMOTE_ACCESS_ISO,media=cdrom,readonly=on" )
fi

cleanup() {
  if [[ -n ${qemu_pid:-} ]] && kill -0 "$qemu_pid" 2>/dev/null; then
    kill "$qemu_pid" 2>/dev/null || true
    wait "$qemu_pid" 2>/dev/null || true
  fi
  rm -f -- "$SPICE_SOCKET"
  rm -f "$PID_FILE"
}
trap cleanup EXIT INT TERM

printf 'Starting existing %s VM. Network: %s; host share: %s\n' "$OS_TYPE" "$NETWORK" "$SHARE_DIR"
if [[ "$NETWORK" == bridge ]]; then
  printf 'The guest will request its own DHCP address from the LAN through %s.\n' "$BRIDGE"
fi
if ((REMOTE_ACCESS)); then
  printf 'In Windows, open the REMOTE_ACCESS CD and run enable-remote.ps1 as Administrator.\n'
fi
printf 'Resize the Remote Viewer window to change the Windows display resolution.\n'
qemu-system-x86_64 "${QEMU_ARGS[@]}" &
qemu_pid=$!
printf '%s\n' "$qemu_pid" > "$PID_FILE"

for _ in {1..100}; do
  [[ -S "$SPICE_SOCKET" ]] && break
  if ! kill -0 "$qemu_pid" 2>/dev/null; then
    wait "$qemu_pid"
    die "QEMU exited before its SPICE display became available"
  fi
  sleep 0.1
done
[[ -S "$SPICE_SOCKET" ]] || die "Timed out waiting for QEMU's SPICE display"

remote-viewer --title "Windows $OS_TYPE" --auto-resize=always "spice+unix://$SPICE_SOCKET"
