#!/usr/bin/env bash
# NixOS counterpart to apply-gui-profile.sh.
#
# Same host-session discovery, different guest contract. NixOS container images
# do not ship cloud-init, so the vendor-data apply-gui-profile.sh relies on --
# the user, the runtime directory, the socket symlinks, the profile.d exports --
# is silently ignored there and only `devices:` takes effect. This script emits
# no cloud-init and puts session variables in `environment.*` instance keys
# instead, which a non-login `incus exec` also sees.
#
# What this script provides:
#
#   * a GPU device owned by GUEST_UID/GUEST_GID
#   * the host's sockets mounted at normalized paths, with no host display
#     numbers in them: /mnt/.sockets/{wayland,x11,pipewire,pulse-native}
#   * session variables describing those paths
#
# What the guest must do for itself, however it likes to declare such things:
#
#   * define the guest user with uid GUEST_UID
#   * create /run/user/GUEST_UID owned by that user
#   * link the mounted sockets to the names clients expect there --
#     wayland-0, pipewire-0, and /tmp/.X11-unix/X0
#   * install GPU userspace (Mesa) and fonts
#
# Because the mounted names are normalized, the guest's half is identical no
# matter whether this host session used wayland-0 or wayland-1, X0 or X1.
set -euo pipefail

INCUS="${INCUS:-incus}"
PROFILE="${NIXOS_GUI_PROFILE:-nixos-gui}"
GUEST_USER="${GUEST_USER:-chicken}"
GUEST_UID="${GUEST_UID:-1000}"
GUEST_GID="${GUEST_GID:-1000}"
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
require_simple_value QT_QPA_PLATFORM "$QT_QPA_PLATFORM"
require_no_single_quote QT_QPA_PLATFORM "$QT_QPA_PLATFORM"
[[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "GUEST_USER must be a valid Linux user name"
require_numeric GUEST_UID "$GUEST_UID"
require_numeric GUEST_GID "$GUEST_GID"
require_path_value XDG_RUNTIME_DIR "$RUNTIME_DIR"

# The compositor may have taken any number; find whichever socket is really there.
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
X_SOCKET="/tmp/.X11-unix/X$X_DISPLAY_NUM"

# Left empty when discovery found nothing at all, so the report below can say
# which glob came up dry rather than blaming the wayland-0 fallback name.
WAYLAND_SOCKET=""
if [[ -S "$RUNTIME_DIR/$WAYLAND_NAME" ]]; then
  WAYLAND_SOCKET="$RUNTIME_DIR/$WAYLAND_NAME"
fi
PIPEWIRE_SOCKET="${PIPEWIRE_SOCKET:-$RUNTIME_DIR/pipewire-0}"
PULSE_SOCKET="${PULSE_SOCKET:-$RUNTIME_DIR/pulse/native}"
require_path_value X11_SOCKET "$X_SOCKET"
require_path_value PIPEWIRE_SOCKET "$PIPEWIRE_SOCKET"
require_path_value PULSE_SOCKET "$PULSE_SOCKET"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Guest-side values only. The guest always sees wayland-0 and :0 because the
# device paths below normalize whatever the host called them.
cat > "$tmp" <<YAML
config:
  boot.autostart: "$BOOT_AUTOSTART"
  environment.DISPLAY: ":0"
  environment.PULSE_SERVER: unix:/mnt/.sockets/pulse-native
  environment.QT_QPA_PLATFORM: '$QT_QPA_PLATFORM'
  environment.WAYLAND_DISPLAY: wayland-0
  environment.XDG_RUNTIME_DIR: /run/user/$GUEST_UID
  environment.XDG_SESSION_TYPE: wayland
  environment._JAVA_AWT_WM_NONREPARENTING: "1"
description: Generated NixOS GUI profile for the current host session.
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
add_disk_socket x11 "$X_SOCKET" /mnt/.sockets/x11
add_disk_socket pipewire "$PIPEWIRE_SOCKET" /mnt/.sockets/pipewire
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
printf 'Host session: uid=%s runtime=%s wayland=%s display=%s\n' \
  "$HOST_UID" "$RUNTIME_DIR" "$WAYLAND_NAME" "$DISPLAY_NAME"
printf 'Included devices:\n'
printf '  %s\n' "${included[@]}"

if ((${#missing[@]})); then
  printf 'Skipped missing sockets/devices:\n'
  printf '  %s\n' "${missing[@]}"
fi

# A GUI profile without a compositor socket applies cleanly and then fails at
# the only thing it exists for, so say so rather than leaving it in the list.
if [[ -z "$WAYLAND_SOCKET" ]]; then
  printf 'warning: no Wayland socket found under %s -- GUI apps will not start\n' \
    "$RUNTIME_DIR" >&2
fi

printf 'This profile only passes things in. The guest still has to create\n'
printf '/run/user/%s, link the mounted sockets to wayland-0 / pipewire-0 /\n' "$GUEST_UID"
printf '/tmp/.X11-unix/X0, and install Mesa and fonts.\n'
