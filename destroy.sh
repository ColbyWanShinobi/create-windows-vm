#!/usr/bin/env bash
# Stop and remove a QEMU Windows VM created by create.sh.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VM_ROOT="$SCRIPT_DIR/.windows-vm"

usage() {
  printf 'Usage: ./destroy.sh [xp|win10|win11]\n'
}

requested=${1:-}
[[ $# -le 1 ]] || { usage >&2; exit 2; }
if [[ -n "$requested" && "$requested" != xp && "$requested" != win10 && "$requested" != win11 ]]; then
  usage >&2
  exit 2
fi

available=()
for os_type in xp win10 win11; do
  [[ -d "$VM_ROOT/$os_type" ]] && available+=("$os_type")
done

# Keep the old flat layout removable during the one-time migration period.
[[ -f "$VM_ROOT/windows.qcow2" ]] && available+=(legacy)

if [[ -n "$requested" ]]; then
  [[ -d "$VM_ROOT/$requested" ]] || { printf 'No %s VM exists.\n' "$requested" >&2; exit 1; }
  selected=$requested
elif ((${#available[@]} == 0)); then
  printf 'No VM files found in %s\n' "$VM_ROOT"
  exit 0
elif ((${#available[@]} == 1)); then
  selected=${available[0]}
else
  [[ -t 0 ]] || { printf 'More than one VM exists; specify xp, win10, or win11.\n' >&2; exit 2; }
  PS3='Choose a VM to destroy (or cancel): '
  select choice in "${available[@]}" Cancel; do
    [[ -n "$choice" ]] || { printf 'Invalid selection.\n' >&2; continue; }
    [[ "$choice" != Cancel ]] || exit 0
    selected=$choice
    break
  done
fi

if [[ "$selected" == legacy ]]; then
  VM_DIR=$VM_ROOT
  legacy=1
else
  VM_DIR="$VM_ROOT/$selected"
  legacy=0
fi
PID_FILE="$VM_DIR/qemu.pid"

if [[ -f "$PID_FILE" ]]; then
  pid=$(<"$PID_FILE")
  process_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
  if [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$process_args" == *qemu-system-x86_64* ]] && [[ "$process_args" == *"$VM_DIR"* ]] && kill -0 "$pid" 2>/dev/null; then
    printf 'Stopping %s VM (PID %s)...\n' "$selected" "$pid"
    kill "$pid"
    for _ in {1..50}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
fi

if ((legacy)); then
  rm -f -- "$VM_ROOT/windows.qcow2" "$VM_ROOT/qemu.pid" "$VM_ROOT/unattended.img" "$VM_ROOT/OVMF_VARS.fd"
  printf 'Removed legacy VM disk and runtime files from %s\n' "$VM_ROOT"
elif [[ -d "$VM_DIR" ]]; then
  rm -rf -- "$VM_DIR"
  printf 'Removed %s VM disk and runtime files from %s\n' "$selected" "$VM_DIR"
else
  printf 'No VM files found at %s\n' "$VM_DIR"
fi

printf 'The shared host folder ~/VMShare was kept.\n'
