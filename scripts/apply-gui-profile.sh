#!/usr/bin/env bash
set -euo pipefail

INCUS="${INCUS:-incus}"
PROFILE="${GUI_PROFILE:-gui}"
GUEST_USER="${GUEST_USER:-chicken}"
GUEST_UID="${GUEST_UID:-1000}"
GUEST_GID="${GUEST_GID:-1000}"
CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-${DESKTOP:-Hyprland}}"
QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"
BOOT_AUTOSTART="${BOOT_AUTOSTART:-false}"

HOST_UID="$(id -u)"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$HOST_UID}"
WAYLAND_NAME="${WAYLAND_DISPLAY:-}"
DISPLAY_NAME="${DISPLAY:-:0}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_simple_value() {
  local name="$1"
  local value="$2"

  case "$value" in
    *$'\n'*|*$'\r'*)
      die "$name must not contain newlines"
      ;;
  esac
}

require_no_single_quote() {
  local name="$1"
  local value="$2"

  [[ "$value" != *"'"* ]] || die "$name must not contain single quotes"
}

require_path_value() {
  local name="$1"
  local value="$2"

  require_simple_value "$name" "$value"
  require_no_single_quote "$name" "$value"
}

require_numeric() {
  local name="$1"
  local value="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be numeric"
}

require_simple_value GUEST_USER "$GUEST_USER"
require_simple_value CURRENT_DESKTOP "$CURRENT_DESKTOP"
require_simple_value QT_QPA_PLATFORM "$QT_QPA_PLATFORM"
require_no_single_quote CURRENT_DESKTOP "$CURRENT_DESKTOP"
require_no_single_quote QT_QPA_PLATFORM "$QT_QPA_PLATFORM"
[[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "GUEST_USER must be a valid Linux user name"
require_numeric GUEST_UID "$GUEST_UID"
require_numeric GUEST_GID "$GUEST_GID"
require_path_value XDG_RUNTIME_DIR "$RUNTIME_DIR"

if [[ -z "$WAYLAND_NAME" || ! -S "$RUNTIME_DIR/$WAYLAND_NAME" ]]; then
  for candidate in "$RUNTIME_DIR"/wayland-*; do
    if [[ -S "$candidate" ]]; then
      WAYLAND_NAME="$(basename "$candidate")"
      break
    fi
  done
fi
WAYLAND_NAME="${WAYLAND_NAME:-wayland-0}"
require_simple_value WAYLAND_DISPLAY "$WAYLAND_NAME"
require_simple_value DISPLAY "$DISPLAY_NAME"
require_no_single_quote WAYLAND_DISPLAY "$WAYLAND_NAME"
require_no_single_quote DISPLAY "$DISPLAY_NAME"

X_DISPLAY_NUM="0"
if [[ "$DISPLAY_NAME" =~ :([0-9]+) ]]; then
  X_DISPLAY_NUM="${BASH_REMATCH[1]}"
fi
X_SOCKET_NAME="X$X_DISPLAY_NUM"
X_SOCKET="/tmp/.X11-unix/$X_SOCKET_NAME"

WAYLAND_SOCKET=""
if [[ -n "$WAYLAND_NAME" ]]; then
  WAYLAND_SOCKET="$RUNTIME_DIR/$WAYLAND_NAME"
fi
SESSION_BUS="$RUNTIME_DIR/bus"
PIPEWIRE_SOCKET="${PIPEWIRE_SOCKET:-$RUNTIME_DIR/pipewire-0}"
PULSE_SOCKET="${PULSE_SOCKET:-$RUNTIME_DIR/pulse/native}"
require_path_value X11_SOCKET "$X_SOCKET"
require_path_value DBUS_SESSION_SOCKET "$SESSION_BUS"
require_path_value PIPEWIRE_SOCKET "$PIPEWIRE_SOCKET"
require_path_value PULSE_SOCKET "$PULSE_SOCKET"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<YAML
config:
  boot.autostart: "$BOOT_AUTOSTART"
  cloud-init.vendor-data: |
    #cloud-config
    users:
      - name: $GUEST_USER
        uid: $GUEST_UID
        groups: wheel, video, audio, input
        sudo: ['ALL=(ALL) NOPASSWD:ALL']
    write_files:
      - path: /usr/local/bin/incus-gui-runtime
        permissions: '0755'
        content: |
          #!/bin/sh
          set -eu

          user="$GUEST_USER"
          runtime="/run/user/$GUEST_UID"

          install -d -m 0700 -o "\$user" -g "\$user" "\$runtime"
          install -d -m 0755 -o "\$user" -g "\$user" "\$runtime/pulse"
          install -d -m 1777 /tmp/.X11-unix

          [ -S /mnt/.sockets/wayland ] && ln -sf /mnt/.sockets/wayland "\$runtime/$WAYLAND_NAME"
          [ -S /mnt/.sockets/$X_SOCKET_NAME ] && ln -sf /mnt/.sockets/$X_SOCKET_NAME /tmp/.X11-unix/$X_SOCKET_NAME
          [ -S /mnt/.sockets/bus ] && ln -sf /mnt/.sockets/bus "\$runtime/bus"
          [ -S /mnt/.sockets/pipewire-0 ] && ln -sf /mnt/.sockets/pipewire-0 "\$runtime/pipewire-0"
          [ -S /mnt/.sockets/pulse-native ] && ln -sf /mnt/.sockets/pulse-native "\$runtime/pulse/native"
      - path: /etc/profile.d/incus-gui.sh
        permissions: '0644'
        content: |
          /usr/local/bin/incus-gui-runtime >/dev/null 2>&1 || true

          export XDG_RUNTIME_DIR=/run/user/$GUEST_UID
          export WAYLAND_DISPLAY='$WAYLAND_NAME'
          export DISPLAY='$DISPLAY_NAME'
          export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$GUEST_UID/bus
          export PULSE_SERVER=unix:/run/user/$GUEST_UID/pulse/native
          export PIPEWIRE_REMOTE=pipewire-0
          export XDG_SESSION_TYPE=wayland
          export XDG_CURRENT_DESKTOP='$CURRENT_DESKTOP'
          export QT_QPA_PLATFORM='$QT_QPA_PLATFORM'
    runcmd:
      - /usr/local/bin/incus-gui-runtime
description: Generated GUI profile for the current host session.
devices:
  graphics:
    type: gpu
    uid: "$GUEST_UID"
    gid: "$GUEST_GID"
YAML

included=("graphics=gpu")
missing=()

add_disk_socket() {
  local name="$1"
  local source="$2"
  local path="$3"

  if [[ -S "$source" ]]; then
    cat >> "$tmp" <<YAML
  $name:
    type: disk
    source: '$source'
    path: '$path'
    shift: "true"
YAML
    included+=("$name=$source")
  else
    missing+=("$name=$source")
  fi
}

add_proxy_socket() {
  local name="$1"
  local source="$2"
  local path="$3"

  if [[ -S "$source" ]]; then
    cat >> "$tmp" <<YAML
  $name:
    type: proxy
    bind: container
    connect: 'unix:$source'
    listen: 'unix:$path'
    mode: "0777"
YAML
    included+=("$name=$source")
  else
    missing+=("$name=$source")
  fi
}

if [[ -n "$WAYLAND_SOCKET" ]]; then
  add_disk_socket wayland "$WAYLAND_SOCKET" /mnt/.sockets/wayland
else
  missing+=("wayland=$RUNTIME_DIR/wayland-*")
fi
add_disk_socket xwayland "$X_SOCKET" "/mnt/.sockets/$X_SOCKET_NAME"
add_disk_socket dbus_session "$SESSION_BUS" /mnt/.sockets/bus
add_disk_socket pipewire "$PIPEWIRE_SOCKET" /mnt/.sockets/pipewire-0
add_proxy_socket pulse "$PULSE_SOCKET" /mnt/.sockets/pulse-native

if [[ "${INCLUDE_CAMERA:-0}" == "1" ]]; then
  CAMERA_DEVICE="${CAMERA_DEVICE:-/dev/video0}"
  require_path_value CAMERA_DEVICE "$CAMERA_DEVICE"
  if [[ -e "$CAMERA_DEVICE" ]]; then
    cat >> "$tmp" <<YAML
  webcam:
    type: unix-char
    source: '$CAMERA_DEVICE'
    path: '$CAMERA_DEVICE'
YAML
    included+=("webcam=$CAMERA_DEVICE")
  else
    missing+=("webcam=$CAMERA_DEVICE")
  fi
fi

if [[ "${INCLUDE_SYSTEM_DBUS:-0}" == "1" ]]; then
  SYSTEM_BUS="${SYSTEM_BUS:-/run/dbus/system_bus_socket}"
  require_path_value SYSTEM_BUS "$SYSTEM_BUS"
  add_disk_socket dbus_system "$SYSTEM_BUS" /run/dbus/system_bus_socket
fi

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  cat "$tmp"
  exit 0
fi

command -v "$INCUS" >/dev/null 2>&1 || die "could not find '$INCUS' in PATH"

if ! "$INCUS" profile show "$PROFILE" >/dev/null 2>&1; then
  "$INCUS" profile create "$PROFILE" >/dev/null
fi
"$INCUS" profile edit "$PROFILE" < "$tmp"

printf 'Applied Incus profile: %s\n' "$PROFILE"
printf 'Included devices:\n'
printf '  %s\n' "${included[@]}"

if ((${#missing[@]})); then
  printf 'Skipped missing sockets/devices:\n'
  printf '  %s\n' "${missing[@]}"
fi
