#!/usr/bin/env bash
# Create and start a Windows virtual machine with QEMU.
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VM_ROOT="$SCRIPT_DIR/.windows-vm"
VM_DIR=""
DISK_IMAGE=""
PID_FILE=""
SHARE_DIR="$HOME/VMShare"
SHARE_DIR_EXPLICIT=0
ANSWER_DISK=""
UEFI_VARS=""
SPICE_GUEST_TOOLS=""
SPICE_GUEST_TOOLS_URL="https://www.spice-space.org/download/windows/spice-guest-tools/spice-guest-tools-latest.exe"
QXL_DRIVER_DIR=""

RAM="8G"
CPUS="4"
DISK_SIZE="80G"
NETWORK="user"
BRIDGE="br0"
TAP=""
OS_TYPE="auto"
USERNAME="gumby"
PASSWORD="gumby"
PRODUCT_KEY=""
XP_DEFAULT_PRODUCT_KEY="CM3HY-26VYW-6JRYC-X66GX-JVY2D"
# This Microsoft-published generic key selects Windows 10 Pro during Setup; it
# does not activate Windows.  A key is required for a fully unattended setup
# because it selects the image index from multi-edition Windows media.
WIN10_DEFAULT_PRODUCT_KEY="VK7JG-NPHTM-C97JM-9MPGT-3V66T"

usage() {
  cat <<'EOF'
Usage: ./create.sh WINDOWS.iso [options]

Options:
  -m, --ram SIZE       Guest memory (default: 8G)
  -c, --cpus COUNT     Guest CPU threads (default: 4)
  -d, --disk-size SIZE Virtual disk size (default: 80G)
  -o, --os TYPE        auto, xp, win10, or win11 (default: auto from ISO name)
  -u, --username NAME  Local administrator name (default: gumby)
  -p, --password TEXT  Local administrator password (default: gumby)
      --share-dir PATH Host folder mapped as S: (default: ~/VMShare)
      --network MODE   bridge (LAN DHCP) or user (private NAT, default)
      --bridge NAME    Host bridge for --network bridge (default: br0)
      --tap NAME       TAP device for --network bridge (default: BRIDGE-tap)
      --product-key KEY Override the default XP product key
      --interactive     Do not attach an unattended-install answer disk
  -h, --help           Show this help

Examples:
  ./create.sh ~/Downloads/Win11.iso
  ./create.sh Win11.iso --ram 16G --cpus 8 --disk-size 120G

Each OS keeps its own disk and settings under .windows-vm/{xp,win10,win11}, so
the three VMs can run concurrently. The host folder ~/VMShare is created when
needed and is mapped as S: in Windows 10/11. Use --share-dir to select a
different host folder.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

ISO=""
UNATTENDED=1
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
    -d|--disk-size)
      (($# >= 2)) || die "$1 requires a value"
      DISK_SIZE=$2
      shift 2
      ;;
    -o|--os)
      (($# >= 2)) || die "$1 requires a value"
      OS_TYPE=${2,,}
      shift 2
      ;;
    -u|--username)
      (($# >= 2)) || die "$1 requires a value"
      USERNAME=$2
      shift 2
      ;;
    -p|--password)
      (($# >= 2)) || die "$1 requires a value"
      PASSWORD=$2
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
    --product-key)
      (($# >= 2)) || die "$1 requires a value"
      PRODUCT_KEY=$2
      shift 2
      ;;
    --interactive)
      UNATTENDED=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*) die "Unknown option: $1" ;;
    *)
      [[ -z "$ISO" ]] || die "Only one Windows ISO path may be supplied"
      ISO=$1
      shift
      ;;
  esac
done

[[ -n "$ISO" ]] || { usage >&2; exit 2; }
[[ -f "$ISO" ]] || die "ISO does not exist or is not a regular file: $ISO"
[[ "$CPUS" =~ ^[1-9][0-9]*$ ]] || die "CPU thread count must be a positive integer"
[[ "$RAM" =~ ^[1-9][0-9]*([MmGg])?$ ]] || die "RAM must look like 8G or 4096M"
[[ "$DISK_SIZE" =~ ^[1-9][0-9]*([MmGgTt])?$ ]] || die "Disk size must look like 80G"
[[ "$USERNAME" =~ ^[A-Za-z0-9._-]{1,20}$ ]] || die "Username may contain only letters, digits, ., _, and -"
[[ "$NETWORK" == bridge || "$NETWORK" == user ]] || die "--network must be bridge or user"
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Bridge name contains unsupported characters"
[[ -n "$TAP" ]] || TAP="${BRIDGE}-tap"
[[ "$TAP" =~ ^[A-Za-z0-9_.-]+$ ]] || die "TAP name contains unsupported characters"

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 is required"
command -v qemu-img >/dev/null || die "qemu-img is required"
command -v remote-viewer >/dev/null || die "remote-viewer is required (install the virt-viewer package for dynamic resolution)"
if ((UNATTENDED)); then
  command -v mkfs.vfat >/dev/null || die "mkfs.vfat is required for unattended setup"
  command -v mcopy >/dev/null || die "mcopy (mtools) is required for unattended setup"
fi

if [[ "$OS_TYPE" == auto ]]; then
  iso_name=${ISO##*/}
  case "${iso_name,,}" in
    *xp*|*windows2000*|*windows_2000*) OS_TYPE=xp ;;
    *win10*|*windows10*|*windows_10*) OS_TYPE=win10 ;;
    *win11*|*windows11*|*windows_11*) OS_TYPE=win11 ;;
    *) die "Cannot detect the Windows version from the ISO name; use --os xp, --os win10, or --os win11" ;;
  esac
fi
[[ "$OS_TYPE" == xp || "$OS_TYPE" == win10 || "$OS_TYPE" == win11 ]] || die "--os must be auto, xp, win10, or win11"
if [[ "$OS_TYPE" == win10 || "$OS_TYPE" == win11 ]]; then
  command -v smbd >/dev/null || die "smbd (Samba) is required for the Windows shared folder"
  if ((UNATTENDED)) && ! command -v curl >/dev/null; then
    die "curl is required to download SPICE Guest Tools for unattended Windows setup"
  fi
  if ((UNATTENDED)) && ! command -v xorriso >/dev/null; then
    die "xorriso is required to create the unattended Windows setup CD"
  fi
fi
if [[ "$OS_TYPE" == xp && -z "$PRODUCT_KEY" ]]; then
  PRODUCT_KEY=$XP_DEFAULT_PRODUCT_KEY
fi
if [[ "$OS_TYPE" == win10 && -z "$PRODUCT_KEY" ]]; then
  PRODUCT_KEY=$WIN10_DEFAULT_PRODUCT_KEY
fi
[[ -z "$PRODUCT_KEY" || "$PRODUCT_KEY" =~ ^([A-Za-z0-9]{5}-){4}[A-Za-z0-9]{5}$ ]] || die "Product key must have the form XXXXX-XXXXX-XXXXX-XXXXX-XXXXX"

VM_DIR="$VM_ROOT/$OS_TYPE"
DISK_IMAGE="$VM_DIR/windows.qcow2"
PID_FILE="$VM_DIR/qemu.pid"
SPICE_SOCKET="$VM_DIR/spice.sock"
ANSWER_DISK="$VM_DIR/unattended.img"
PROVISION_ISO="$VM_DIR/provisioning.iso"
UEFI_VARS="$VM_DIR/OVMF_VARS.fd"
SPICE_GUEST_TOOLS="$VM_ROOT/guest-tools/spice-guest-tools-latest.exe"
QXL_DRIVER_DIR="$VM_ROOT/guest-tools/qxldod-w10-amd64"
SHARE_DIR_FILE="$VM_DIR/share-dir"
if [[ "$NETWORK" == bridge ]]; then
  [[ -d "/sys/class/net/$BRIDGE" ]] || die "Bridge $BRIDGE does not exist. Create it once with: sudo ./setup-lan-bridge.sh --bridge $BRIDGE"
  [[ -e "/sys/class/net/$TAP" ]] || die "TAP $TAP does not exist. Run: sudo ./setup-lan-bridge.sh --bridge $BRIDGE --tap $TAP"
fi
mkdir -p "$VM_ROOT" "$SHARE_DIR"

# Preserve VMs made by the earlier single-VM version of this script. That
# layout was used for XP, so migrate it only when XP is selected.
if [[ -f "$VM_ROOT/windows.qcow2" && ! -e "$DISK_IMAGE" ]]; then
  [[ "$OS_TYPE" == xp ]] || die "A legacy VM exists in $VM_ROOT; run this once with --os xp to migrate it first"
  if [[ -f "$VM_ROOT/qemu.pid" ]] && old_pid=$(<"$VM_ROOT/qemu.pid") && [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "The legacy XP VM is running (PID $old_pid); stop it before migrating"
  fi
  mkdir -p "$VM_DIR"
  for legacy_file in windows.qcow2 qemu.pid unattended.img OVMF_VARS.fd; do
    [[ -e "$VM_ROOT/$legacy_file" ]] && mv "$VM_ROOT/$legacy_file" "$VM_DIR/$legacy_file"
  done
fi
mkdir -p "$VM_DIR"

# A custom share directory must survive later starts via run.sh.  Preserve an
# existing selection unless this invocation explicitly supplies --share-dir.
if [[ -s "$SHARE_DIR_FILE" && $SHARE_DIR_EXPLICIT -eq 0 ]]; then
  IFS= read -r SHARE_DIR < "$SHARE_DIR_FILE"
fi
mkdir -p "$SHARE_DIR"
if [[ ! -s "$SHARE_DIR_FILE" || $SHARE_DIR_EXPLICIT -eq 1 ]]; then
  printf '%s\n' "$SHARE_DIR" > "$SHARE_DIR_FILE"
fi

xml_escape() {
  local value=$1
  value=${value//&/\&amp;}
  value=${value//</\&lt;}
  value=${value//>/\&gt;}
  value=${value//\"/\&quot;}
  value=${value//\'/\&apos;}
  printf '%s' "$value"
}

create_answer_disk() {
  local answer_file="$VM_DIR/Autounattend.xml" provision_file="$VM_DIR/provision.cmd" provision_dir="" provision_tmp="" key_xml="" user_xml password_xml
  if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(LC_ALL=C od -An -N 12 -tx1 /dev/urandom | tr -d ' \n')
  fi
  user_xml=$(xml_escape "$USERNAME")
  password_xml=$(xml_escape "$PASSWORD")
  [[ -z "$PRODUCT_KEY" ]] || key_xml="<ProductKey><Key>$(xml_escape "$PRODUCT_KEY")</Key><WillShowUI>Never</WillShowUI></ProductKey>"

  truncate -s 1440K "$ANSWER_DISK"
  mkfs.vfat -F 12 -n UNATTEND "$ANSWER_DISK" >/dev/null
  chmod 600 "$ANSWER_DISK"
  if [[ "$OS_TYPE" == xp ]]; then
    cat > "$answer_file" <<EOF
[Data]
AutoPartition=1
MsDosInitiated="0"
UnattendedInstall="Yes"
[Unattended]
UnattendMode=FullUnattended
OemSkipEula=Yes
OemPreinstall=No
TargetPath=\\WINDOWS
FileSystem=NTFS
Repartition=Yes
[GuiUnattended]
AdminPassword=$PASSWORD
OEMSkipRegional=1
TimeZone=35
OemSkipWelcome=1
[UserData]
FullName="$USERNAME"
OrgName="Windows VM"
ComputerName=WINDOWSVM
EOF
    [[ -z "$PRODUCT_KEY" ]] || printf 'ProductKey=%s\n' "$PRODUCT_KEY" >> "$answer_file"
    mcopy -o -i "$ANSWER_DISK" "$answer_file" ::/WINNT.SIF
  else
    cat > "$answer_file" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UILanguageFallback>en-US</UILanguageFallback><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <UserData><AcceptEula>true</AcceptEula>$key_xml</UserData>
      <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk><CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>100</Size></CreatePartition><CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition><CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions><ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition><ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition></ModifyPartitions></Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>
      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key><Value>Windows 10 Pro</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>cmd /c reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f &amp; reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f &amp; reg add HKLM\\SYSTEM\\Setup\\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand></RunSynchronous>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous><RunSynchronousCommand wcm:action="add"><Order>1</Order><Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLinkedConnections /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand><RunSynchronousCommand wcm:action="add"><Order>2</Order><Path>cmd /c for %D in (D E F G H I J K L M N O P Q R T U V W X Y Z) do @if exist "%D:\provision.cmd" call "%D:\provision.cmd"</Path></RunSynchronousCommand></RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE><HideEULAPage>true</HideEULAPage><HideOnlineAccountScreens>true</HideOnlineAccountScreens><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>$user_xml</Name><Group>Administrators</Group><Password><Value>$password_xml</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>$user_xml</Username><LogonCount>1</LogonCount><Password><Value>$password_xml</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c net use S: \\\\10.0.2.4\\qemu /persistent:yes</CommandLine></SynchronousCommand></FirstLogonCommands>
      <TimeZone>UTC</TimeZone>
    </component>
  </settings>
</unattend>
EOF
    cat > "$provision_file" <<'EOF'
@echo off
setlocal
set "LOG=%SystemDrive%\spice-guest-tools-install.log"
echo Installing SPICE Guest Tools > "%LOG%"
start "" /wait "%~dp0spice-guest-tools-latest.exe" /S
echo SPICE Guest Tools exit code: %errorlevel% >> "%LOG%"
echo Installing the Red Hat QXL display driver >> "%LOG%"
pnputil /add-driver "%~dp0qxl-driver\qxldod.inf" /install >> "%LOG%" 2>&1
echo QXL driver install exit code: %errorlevel% >> "%LOG%"
echo Enabling WinRM and OpenSSH Server >> "%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable-remote.ps1" >> "%LOG%" 2>&1
echo Remote access setup exit code: %errorlevel% >> "%LOG%"
EOF
    mcopy -o -i "$ANSWER_DISK" "$answer_file" ::/Autounattend.xml
    provision_dir=$(mktemp -d "$VM_DIR/provisioning.XXXXXX")
    cp -- "$provision_file" "$provision_dir/provision.cmd"
    cp -- "$SCRIPT_DIR/enable-remote.ps1" "$provision_dir/enable-remote.ps1"
    cp -- "$SPICE_GUEST_TOOLS" "$provision_dir/spice-guest-tools-latest.exe"
    mkdir -p "$provision_dir/qxl-driver"
    cp -- "$QXL_DRIVER_DIR"/qxldod.{cat,inf,sys} "$provision_dir/qxl-driver/"
    provision_tmp=$(mktemp "$VM_DIR/provisioning.XXXXXX.iso")
    xorriso -overwrite on -as mkisofs -quiet -V PROVISION -o "$provision_tmp" "$provision_dir"
    mv -f -- "$provision_tmp" "$PROVISION_ISO"
    chmod 600 "$PROVISION_ISO"
    rm -rf -- "$provision_dir"
    rm -f "$provision_file"
  fi
  rm -f "$answer_file"
}

prepare_spice_guest_tools() {
  [[ "$OS_TYPE" == win10 || "$OS_TYPE" == win11 ]] || return
  if [[ -s "$SPICE_GUEST_TOOLS" ]]; then
    printf 'Using cached SPICE Guest Tools: %s\n' "$SPICE_GUEST_TOOLS"
    return
  fi
  mkdir -p "${SPICE_GUEST_TOOLS%/*}"
  printf 'Downloading SPICE Guest Tools for automatic clipboard integration...\n'
  curl --fail --location --retry 3 --output "$SPICE_GUEST_TOOLS.tmp" "$SPICE_GUEST_TOOLS_URL"
  mv "$SPICE_GUEST_TOOLS.tmp" "$SPICE_GUEST_TOOLS"
}

prepare_qxl_driver() {
  [[ "$OS_TYPE" == win10 || "$OS_TYPE" == win11 ]] || return
  if [[ -s "$QXL_DRIVER_DIR/qxldod.inf" && -s "$QXL_DRIVER_DIR/qxldod.sys" && -s "$QXL_DRIVER_DIR/qxldod.cat" ]]; then
    return
  fi
  command -v 7z >/dev/null || die "7z is required to extract the QXL display driver from SPICE Guest Tools"
  local qxl_tmp
  qxl_tmp=$(mktemp -d "$VM_ROOT/guest-tools/qxldod.XXXXXX")
  if ! 7z e -y -o"$qxl_tmp" "$SPICE_GUEST_TOOLS" \
    'drivers/qxldod/w10/amd64/qxldod.inf' \
    'drivers/qxldod/w10/amd64/qxldod.sys' \
    'drivers/qxldod/w10/amd64/qxldod.cat' >/dev/null; then
    rm -rf -- "$qxl_tmp"
    die "Could not extract the QXL display driver from SPICE Guest Tools"
  fi
  [[ -s "$qxl_tmp/qxldod.inf" && -s "$qxl_tmp/qxldod.sys" && -s "$qxl_tmp/qxldod.cat" ]] || {
    rm -rf -- "$qxl_tmp"
    die "SPICE Guest Tools does not contain the Windows QXL display driver"
  }
  rm -rf -- "$QXL_DRIVER_DIR"
  mv -- "$qxl_tmp" "$QXL_DRIVER_DIR"
}

if [[ -e "$PID_FILE" ]]; then
  old_pid=$(<"$PID_FILE")
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    die "The VM is already running (PID $old_pid)"
  fi
  rm -f "$PID_FILE"
fi
rm -f -- "$SPICE_SOCKET"

if [[ ! -e "$DISK_IMAGE" ]]; then
  qemu-img create -f qcow2 "$DISK_IMAGE" "$DISK_SIZE"
elif [[ ! -f "$DISK_IMAGE" ]]; then
  die "VM disk path exists but is not a regular file: $DISK_IMAGE"
fi

if ((UNATTENDED)); then
  if [[ "$OS_TYPE" == xp && "$PASSWORD" =~ [[:space:]] ]]; then
    die "XP unattended passwords cannot contain whitespace"
  fi
  prepare_spice_guest_tools
  prepare_qxl_driver
  create_answer_disk
fi

QEMU_ARGS=(
  -name "Windows $OS_TYPE"
  -enable-kvm
  -cpu host
  -smp "$CPUS"
  -m "$RAM"
  -boot order=dc
  -drive "file=$DISK_IMAGE,format=qcow2,if=ide"
  -drive "file=$ISO,media=cdrom,readonly=on"
  -display none
  -spice "unix=on,addr=$SPICE_SOCKET,disable-ticketing=on,disable-copy-paste=off"
  -device virtio-serial-pci
  -chardev spicevmc,id=vdagent,name=vdagent
  -device virtserialport,chardev=vdagent,name=com.redhat.spice.0
)

if [[ "$OS_TYPE" == xp ]]; then
  # Split IRQ-chip mode avoids a QEMU/KVM AMD-IOMMU assertion seen with XP on
  # recent QEMU builds, while retaining hardware CPU virtualization.
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
  [[ -n "$OVMF_CODE" ]] || die "OVMF firmware is required for Windows 10/11 (install an edk2-ovmf or ovmf package)"
  if [[ ! -f "$UEFI_VARS" ]]; then
    for candidate in /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/OVMF/OVMF_VARS.fd; do
      [[ -r "$candidate" ]] && cp "$candidate" "$UEFI_VARS" && break
    done
  fi
  [[ -f "$UEFI_VARS" ]] || die "OVMF variable store is required for Windows 10/11"
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
  QEMU_ARGS+=( -netdev "tap,id=lan0,ifname=$TAP,script=no,downscript=no" )
  [[ "$OS_TYPE" == xp ]] && QEMU_ARGS+=( -device rtl8139,netdev=lan0 ) || QEMU_ARGS+=( -device e1000e,netdev=lan0 )
  [[ "$OS_TYPE" == xp ]] || QEMU_ARGS+=( -netdev "user,id=share0,smb=$SHARE_DIR" -device e1000e,netdev=share0 )
else
  [[ "$OS_TYPE" == xp ]] && QEMU_ARGS+=( -nic user,model=rtl8139 ) || QEMU_ARGS+=( -nic "user,model=e1000e,smb=$SHARE_DIR" )
fi

if ((UNATTENDED)); then
  QEMU_ARGS+=( -drive "file=$ANSWER_DISK,format=raw,if=floppy,readonly=on" )
  [[ "$OS_TYPE" == xp ]] || QEMU_ARGS+=( -drive "file=$PROVISION_ISO,media=cdrom,readonly=on" )
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

printf 'Starting Windows VM. Network: %s; host share: %s\n' "$NETWORK" "$SHARE_DIR"
if [[ "$NETWORK" == bridge ]]; then
  printf 'The guest will request its own DHCP address from the LAN through %s.\n' "$BRIDGE"
fi
printf 'Resize the Remote Viewer window to change the Windows display resolution.\n'
printf 'Windows 10/11 setup installs SPICE Guest Tools for clipboard sharing and maps the host share as S:.\n'
if ((UNATTENDED)); then
  printf 'Unattended %s setup is enabled; local administrator: %s; password: %s\n' "$OS_TYPE" "$USERNAME" "$PASSWORD"
fi

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
