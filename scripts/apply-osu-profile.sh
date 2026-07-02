#!/usr/bin/env bash
set -euo pipefail

INCUS="${INCUS:-incus}"
PROFILE="${OSU_PROFILE:-osu}"
GUEST_USER="${GUEST_USER:-chicken}"
OSU_SOURCE="${OSU_SOURCE:-${OSU_DIR:-$HOME/osu}}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

case "$GUEST_USER" in
  *$'\n'*|*$'\r'*)
    die "GUEST_USER must not contain newlines"
    ;;
esac
[[ "$GUEST_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "GUEST_USER must be a valid Linux user name"

case "$OSU_SOURCE" in
  *$'\n'*|*$'\r'*)
    die "OSU_SOURCE must not contain newlines"
    ;;
  *"'"*)
    die "OSU_SOURCE must not contain single quotes"
    ;;
esac

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

cat > "$tmp" <<YAML
config:
  cloud-init.user-data: |
    #cloud-config
    packages:
      - foot
      - neovim
      - fish
      - glxgears
      - ttf-bitstream-vera
      - ttf-dejavu
      - ttf-liberation
      - ttf-meslo-nerd
      - ttf-opensans
      - freetype2
      - cantarell-fonts
      - opendesktop-fonts
      - adobe-source-han-sans-cn-fonts
      - adobe-source-han-sans-jp-fonts
      - adobe-source-han-sans-kr-fonts
      - awesome-terminal-fonts
      - noto-fonts
      - noto-fonts-cjk
      - noto-fonts-emoji
      - xdg-desktop-portal-hyprland
      - xdg-desktop-portal
      - dbus-glib
      - kdbusaddons
      - libdbusmenu-glib
      - libdbusmenu-gtk3
      - sdbus-cpp
    runcmd:
      - mkdir -p /home/$GUEST_USER/.local/share/osu
      - chown -R $GUEST_USER:$GUEST_USER /home/$GUEST_USER/.local
description: Generated osu! profile.
YAML

if [[ -d "$OSU_SOURCE" ]]; then
  cat >> "$tmp" <<YAML
devices:
  osu:
    type: disk
    source: '$OSU_SOURCE'
    path: /home/$GUEST_USER/.local/share/osu
    shift: "true"
YAML
else
  cat >> "$tmp" <<'YAML'
devices: {}
YAML
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
if [[ -d "$OSU_SOURCE" ]]; then
  printf 'Mounted osu data: %s\n' "$OSU_SOURCE"
else
  printf 'No osu data mount added because this directory does not exist: %s\n' "$OSU_SOURCE"
  printf 'Set OSU_SOURCE=/path/to/osu and rerun this script to add the mount.\n'
fi
