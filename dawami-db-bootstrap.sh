#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
BOOTSTRAP_VERSION="1.0.1"
INSTALLER_REPO="${INSTALLER_REPO:-scharfesicht/Dawami365-Installer}"
WORK_DIR="${WORK_DIR:-/tmp/dawami365-db-bootstrap}"
log(){ printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){ unset GH_TOKEN 2>/dev/null || true; }
trap cleanup EXIT
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run with sudo/root."
disable_stale_cdrom_sources(){
  local f tmp stamp
  stamp="$(date +%Y%m%d-%H%M%S)"
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    if grep -qiE '^[[:space:]]*deb([^#]*)(cdrom:|file:/+cdrom)' "$f"; then
      cp -a "$f" "${f}.bak.dawami365.${stamp}"
      sed -i -E '/^[[:space:]]*#/! {/cdrom:|file:\/+cdrom/I s|^|# disabled by Dawami365 bootstrap: |;}' "$f"
      log "Disabled stale CD-ROM APT source in $f"
    fi
  done
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if grep -qiE '(^|[[:space:]])(cdrom:|file:/+cdrom)' "$f"; then
      cp -a "$f" "${f}.bak.dawami365.${stamp}"
      tmp="$(mktemp)"
      awk 'BEGIN{RS=""; ORS="\n\n"} {x=tolower($0); if (x ~ /cdrom:/ || x ~ /file:\/\/\/+cdrom/ || x ~ /file:\/+cdrom/) next; print}' "$f" > "$tmp"
      cat "$tmp" > "$f"; rm -f "$tmp"
      log "Disabled stale CD-ROM APT stanza in $f"
    fi
  done
}

for cmd in curl jq sha256sum tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    disable_stale_cdrom_sources
    apt-get update -y
    apt-get install -y curl jq coreutils tar ca-certificates
    break
  fi
done
TAG="${1:-}"
[[ -n "$TAG" ]] || fail "Usage: sudo $0 <release-tag>"
echo
echo "A temporary GitHub read token is required to fetch the private installer."
read -r -s -p "Enter installation token: " GH_TOKEN
echo
[[ -n "$GH_TOKEN" ]] || fail "Installation token cannot be empty."
api(){ curl --fail --silent --show-error -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }
download_asset(){ curl --fail --location --silent --show-error -H "Accept: application/octet-stream" -H "Authorization: Bearer ${GH_TOKEN}" -H "X-GitHub-Api-Version: 2022-11-28" -o "$2" "$1"; }
rm -rf "$WORK_DIR"
install -d -m 0700 "$WORK_DIR"
log "Resolving private Dawami365 DB installer release ${TAG}..."
release_json="$(api "https://api.github.com/repos/${INSTALLER_REPO}/releases/tags/${TAG}")"
version="${TAG#v}"
bundle="dawami365-db-installer-${version}.tar.gz"
checksum="${bundle}.sha256"
bundle_url="$(jq -r --arg n "$bundle" '.assets[] | select(.name==$n) | .url' <<<"$release_json")"
checksum_url="$(jq -r --arg n "$checksum" '.assets[] | select(.name==$n) | .url' <<<"$release_json")"
[[ -n "$bundle_url" && "$bundle_url" != "null" ]] || fail "Release asset missing: $bundle"
[[ -n "$checksum_url" && "$checksum_url" != "null" ]] || fail "Release asset missing: $checksum"
log "Downloading private DB installer..."
download_asset "$bundle_url" "$WORK_DIR/$bundle"
download_asset "$checksum_url" "$WORK_DIR/$checksum"
log "Verifying SHA-256..."
(cd "$WORK_DIR" && sha256sum -c "$checksum") || fail "Checksum verification failed."
install -d -m 0700 "$WORK_DIR/extracted"
tar -xzf "$WORK_DIR/$bundle" -C "$WORK_DIR/extracted"
entry="$WORK_DIR/extracted/db-installer-entrypoint.sh"
[[ -f "$entry" ]] || fail "db-installer-entrypoint.sh missing from bundle."
chmod 0700 "$entry"
unset GH_TOKEN
log "Starting private Dawami365 DB installer..."
cd "$WORK_DIR/extracted"
exec "$entry"
