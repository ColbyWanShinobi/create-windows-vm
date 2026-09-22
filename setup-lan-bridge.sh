#!/usr/bin/env bash
# Create a persistent NetworkManager bridge for QEMU guests.  This preserves
# the current connection profile; it only activates a new bridge profile.
set -euo pipefail

BRIDGE=br0
UPLINK=""
TAP=""

usage() {
  cat <<'EOF'
Usage: sudo ./setup-lan-bridge.sh [--bridge NAME] [--uplink IFACE] [--tap NAME]

Creates a persistent NetworkManager bridge and permits QEMU's bridge helper to
attach guests. With no options, the uplink is inferred from the default route
and the bridge name is br0. The TAP name defaults to BRIDGE-tap. The host may
briefly renew its DHCP lease while the
bridge is activated. The previous NetworkManager connection is retained and
can be restored with: nmcli connection up "Wired connection 1"
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --bridge) (($# >= 2)) || die "$1 requires a value"; BRIDGE=$2; shift 2 ;;
    --uplink) (($# >= 2)) || die "$1 requires a value"; UPLINK=$2; shift 2 ;;
    --tap) (($# >= 2)) || die "$1 requires a value"; TAP=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die 'Run this helper with sudo.'
command -v nmcli >/dev/null || die 'NetworkManager (nmcli) is required.'
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Bridge name contains unsupported characters.'
[[ -n "$TAP" ]] || TAP="${BRIDGE}-tap"
[[ "$TAP" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'TAP name contains unsupported characters.'
TAP_OWNER=${SUDO_USER:-}
[[ -n "$TAP_OWNER" ]] || die 'Run this helper through sudo from the user who starts the VM.'
id -u "$TAP_OWNER" >/dev/null || die "Cannot identify TAP owner: $TAP_OWNER"

if [[ -z "$UPLINK" ]]; then
  UPLINK=$(ip route show default | awk '/default/ {print $5; exit}')
fi
if [[ "$UPLINK" == "$BRIDGE" ]]; then
  # Once the bridge is active, the default route belongs to br0. Re-running
  # this helper must use its physical port rather than rejecting that route.
  UPLINK=$(ip -o link show master "$BRIDGE" | awk -F': ' 'NR == 1 { sub(/@.*/, "", $2); print $2 }')
fi
[[ -n "$UPLINK" ]] || die 'Could not identify an uplink; pass --uplink IFACE.'
[[ -d "/sys/class/net/$UPLINK" ]] || die "No such network interface: $UPLINK"
[[ "$UPLINK" != "$BRIDGE" ]] || die 'The uplink and bridge must differ.'

BRIDGE_CONNECTION="Windows VM bridge ($BRIDGE)"
UPLINK_CONNECTION="Windows VM uplink ($UPLINK -> $BRIDGE)"

if ! nmcli -t -f NAME,TYPE connection show | awk -F: -v name="$BRIDGE_CONNECTION" '$1 == name && $2 == "bridge" { found=1 } END { exit !found }'; then
  nmcli connection add type bridge ifname "$BRIDGE" con-name "$BRIDGE_CONNECTION" \
    ipv4.method auto ipv6.method auto bridge.stp no
fi
if ! nmcli connection show "$UPLINK_CONNECTION" >/dev/null 2>&1; then
  nmcli connection add type ethernet ifname "$UPLINK" con-name "$UPLINK_CONNECTION" master "$BRIDGE"
fi

install -d -m 755 /etc/qemu
touch /etc/qemu/bridge.conf
grep -Fqx "allow $BRIDGE" /etc/qemu/bridge.conf || printf 'allow %s\n' "$BRIDGE" >> /etc/qemu/bridge.conf
chmod 644 /etc/qemu/bridge.conf

printf 'Moving %s onto %s. The host network will reconnect briefly...\n' "$UPLINK" "$BRIDGE"
# Explicitly activate the slave profile.  Merely activating the bridge leaves
# an already-active Ethernet profile attached to the physical NIC, which gives
# br0 no uplink and prevents both host and guest DHCP.
active_connection=$(nmcli -g GENERAL.CONNECTION device show "$UPLINK" 2>/dev/null || true)
if [[ -n "$active_connection" && "$active_connection" != "$UPLINK_CONNECTION" ]]; then
  nmcli connection down "$active_connection" || true
fi
nmcli connection up "$UPLINK_CONNECTION" ifname "$UPLINK"
nmcli connection up "$BRIDGE_CONNECTION"

# Use a persistent TAP rather than relying on qemu-bridge-helper to create and
# attach a transient one.  The latter can leave a TAP outside the bridge when
# QEMU starts during a NetworkManager bridge transition.
if ! ip link show dev "$TAP" >/dev/null 2>&1; then
  ip tuntap add dev "$TAP" mode tap user "$TAP_OWNER"
fi
ip link set dev "$TAP" master "$BRIDGE"
ip link set dev "$TAP" up
printf 'Bridge %s and TAP %s are active. Start the VM with ./run.sh --network bridge --bridge %s\n' "$BRIDGE" "$TAP" "$BRIDGE"
