#!/usr/bin/env bash
set -euo pipefail

INCUS="${INCUS:-incus}"
INSTANCE="${INSTANCE:-osu}"
IMAGE="${IMAGE:-images:archlinux/cloud}"

command -v "$INCUS" >/dev/null 2>&1 || {
  printf 'error: could not find %s in PATH\n' "$INCUS" >&2
  exit 1
}

if "$INCUS" info "$INSTANCE" >/dev/null 2>&1; then
  printf 'error: instance already exists: %s\n' "$INSTANCE" >&2
  exit 1
fi

"$(dirname "$0")/apply-gui-profile.sh"
"$(dirname "$0")/apply-osu-profile.sh"

"$INCUS" launch "$IMAGE" "$INSTANCE" \
  --profile default \
  --profile gui \
  --profile osu

printf 'Launched %s from %s with profiles: default, gui, osu\n' "$INSTANCE" "$IMAGE"
