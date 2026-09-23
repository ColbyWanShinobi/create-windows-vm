#!/usr/bin/env bash
# Restore the host connection after setup-lan-bridge.sh and remove only the
# NetworkManager profiles and TAP device this project created.
set -euo pipefail

BRIDGE=br0
UPLINK=""
TAP=""
RESTORE_CONNECTION=""
STATE_DIR=/etc/qemu

usage() {
  cat <<'EOF'
Usage: sudo ./teardown-lan-bridge.sh [--bridge NAME] [--uplink IFACE] [--tap NAME] [--restore CONNECTION]

Restores the host connection that setup-lan-bridge.sh displaced, then removes
the project's bridge, bridge-port profile, and TAP interface.  With no
options, the recorded setup state for br0 is used.

Use --restore only when the recorded state is unavailable and more than one
normal connection profile could use the uplink.
EOF
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case "$1" in
    --bridge) (($# >= 2)) || die "$1 requires a value"; BRIDGE=$2; shift 2 ;;
    --uplink) (($# >= 2)) || die "$1 requires a value"; UPLINK=$2; shift 2 ;;
    --tap) (($# >= 2)) || die "$1 requires a value"; TAP=$2; shift 2 ;;
    --restore) (($# >= 2)) || die "$1 requires a value"; RESTORE_CONNECTION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die 'Run this helper with sudo.'
command -v nmcli >/dev/null || die 'NetworkManager (nmcli) is required.'
[[ "$BRIDGE" =~ ^[A-Za-z0-9_.-]+$ ]] || die 'Bridge name contains unsupported characters.'

STATE_FILE="$STATE_DIR/windows-vm-bridge-$BRIDGE.env"
if [[ -r "$STATE_FILE" ]]; then
  # The state file is created by setup-lan-bridge.sh with shell-quoted values.
  # It is root-owned under /etc/qemu; do not source an untrusted replacement.
  source "$STATE_FILE"
fi

[[ -n "$UPLINK" ]] || UPLINK=$(ip -o link show master "$BRIDGE" | awk -F': ' 'NR == 1 { sub(/@.*/, "", $2); print $2 }')
[[ -n "$UPLINK" ]] || die "Could not identify $BRIDGE's physical uplink; pass --uplink IFACE."
[[ -n "$TAP" ]] || TAP="${BRIDGE}-tap"

BRIDGE_CONNECTION="Windows VM bridge ($BRIDGE)"
UPLINK_CONNECTION="Windows VM uplink ($UPLINK -> $BRIDGE)"

if [[ -z "$RESTORE_CONNECTION" ]]; then
  mapfile -t candidates < <(
    while IFS=: read -r name type; do
      [[ "$type" == "802-3-ethernet" && "$name" != "$UPLINK_CONNECTION" ]] || continue
      profile_interface=$(nmcli -g connection.interface-name connection show "$name")
      [[ -z "$profile_interface" || "$profile_interface" == "$UPLINK" ]] && printf '%s\n' "$name"
    done < <(nmcli -t -f NAME,TYPE connection show)
  )
  if ((${#candidates[@]} == 1)); then
    RESTORE_CONNECTION=${candidates[0]}
  else
    die "Cannot safely choose the original connection profile; pass --restore CONNECTION."
  fi
fi

nmcli connection show "$RESTORE_CONNECTION" >/dev/null || die "No such restore profile: $RESTORE_CONNECTION"
profile_interface=$(nmcli -g connection.interface-name connection show "$RESTORE_CONNECTION")
if [[ -n "$profile_interface" && "$profile_interface" != "$UPLINK" ]]; then
  die "Restore profile $RESTORE_CONNECTION is bound to $profile_interface, not $UPLINK; choose or create a profile for $UPLINK."
fi
printf 'Restoring host connection %q on %s...\n' "$RESTORE_CONNECTION" "$UPLINK"
nmcli connection up "$RESTORE_CONNECTION" ifname "$UPLINK"

active_connection=$(nmcli -g GENERAL.CONNECTION device show "$UPLINK" 2>/dev/null || true)
[[ "$active_connection" == "$RESTORE_CONNECTION" ]] || die "Restore profile did not become active; bridge profiles were left in place."

# Removal begins only after the primary connection is restored.  Each target is
# named by setup-lan-bridge.sh, so unrelated NetworkManager profiles remain.
if ip link show dev "$TAP" >/dev/null 2>&1; then
  ip link set dev "$TAP" down
  ip link delete dev "$TAP"
fi
nmcli connection delete "$UPLINK_CONNECTION" 2>/dev/null || true
nmcli connection delete "$BRIDGE_CONNECTION" 2>/dev/null || true
rm -f -- "$STATE_FILE"

printf 'Host networking is back on %q; removed %s, %s, and %s. Proton VPN can now use the original connection.\n' \
  "$RESTORE_CONNECTION" "$BRIDGE_CONNECTION" "$UPLINK_CONNECTION" "$TAP"
