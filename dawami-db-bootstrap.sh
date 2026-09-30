#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
umask 077
BOOTSTRAP_VERSION="1.0.4"
INSTALLER_REPO="${INSTALLER_REPO:-scharfesicht/Dawami365-Installer}"
WORK_DIR="${WORK_DIR:-/tmp/dawami365-db-bootstrap}"
log(){ printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){ unset GH_TOKEN 2>/dev/null || true; [[ -n "${CURL_CONFIG:-}" ]] && rm -f "$CURL_CONFIG" 2>/dev/null || true; }
trap cleanup EXIT
apt_get(){ apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=4 "$@"; }
curl_retry(){ curl --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 15 --max-time 180 "$@"; }
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
    export NEEDRESTART_MODE=l
    disable_stale_cdrom_sources
    apt_get update -y
    apt_get install -y --no-upgrade curl jq coreutils tar ca-certificates
    break
  fi
done
TAG="${1:-}"
[[ -n "$TAG" ]] || fail "Usage: sudo $0 <release-tag>"
echo
echo "A temporary GitHub read token is required to fetch the private installer."
release_json=""
for attempt in 1 2 3; do
  read -r -s -p "Enter installation token: " GH_TOKEN
  echo
  [[ -n "$GH_TOKEN" ]] || { echo "Token cannot be empty." >&2; continue; }
  CURL_CONFIG="$(mktemp)"
  chmod 0600 "$CURL_CONFIG"
  cat > "$CURL_CONFIG" <<CFG
header = "Authorization: Bearer ${GH_TOKEN}"
header = "X-GitHub-Api-Version: 2022-11-28"
CFG
  if release_json="$(curl_retry --fail --silent --show-error --config "$CURL_CONFIG" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${INSTALLER_REPO}/releases/tags/${TAG}" 2>/tmp/dawami365-gh-error)"; then
    break
  fi
  rm -f "$CURL_CONFIG"; CURL_CONFIG=""
  unset GH_TOKEN
  if (( attempt < 3 )); then echo "Token rejected or GitHub request failed; try again." >&2; fi
done
[[ -n "$release_json" ]] || { cat /tmp/dawami365-gh-error >&2 2>/dev/null || true; fail "Unable to access private installer release after 3 attempts."; }
api_download(){
  local url="$1" out="$2"
  curl_retry --fail --location --silent --show-error --config "$CURL_CONFIG" -H "Accept: application/octet-stream" -o "$out" "$url"
}

rm -rf "$WORK_DIR"
install -d -m 0700 "$WORK_DIR"
log "Resolving private Dawami365 DB installer release ${TAG}..."
version="${TAG#v}"
bundle="dawami365-db-installer-${version}.tar.gz"
checksum="${bundle}.sha256"
bundle_url="$(jq -r --arg n "$bundle" '[.assets[] | select(.name==$n) | .url][0] // empty' <<<"$release_json")"
checksum_url="$(jq -r --arg n "$checksum" '[.assets[] | select(.name==$n) | .url][0] // empty' <<<"$release_json")"
[[ -n "$bundle_url" && "$bundle_url" != "null" ]] || fail "Release asset missing: $bundle"
[[ -n "$checksum_url" && "$checksum_url" != "null" ]] || fail "Release asset missing: $checksum"
log "Downloading private DB installer..."
api_download "$bundle_url" "$WORK_DIR/$bundle"
api_download "$checksum_url" "$WORK_DIR/$checksum"
log "Verifying SHA-256..."
(cd "$WORK_DIR" && sha256sum -c "$checksum") || fail "Checksum verification failed."
tar -tzf "$WORK_DIR/$bundle" > "$WORK_DIR/archive.list" || fail 'Unable to read installer archive.'
while IFS= read -r item; do
  case "$item" in /*|../*|*/../*|*'/..') fail "Unsafe path in installer archive: $item" ;; esac
done < "$WORK_DIR/archive.list"
install -d -m 0700 "$WORK_DIR/extracted"
tar -xzf "$WORK_DIR/$bundle" -C "$WORK_DIR/extracted" --no-same-owner
entry="$WORK_DIR/extracted/db-installer-entrypoint.sh"
installer="$WORK_DIR/extracted/dawami365-db-install-v2.sh"
preset="$WORK_DIR/extracted/installer-presets.env"
manifest="$WORK_DIR/extracted/RELEASE-MANIFEST.txt"
[[ -f "$entry" && ! -L "$entry" ]] || fail "db-installer-entrypoint.sh missing/invalid in bundle."
[[ -f "$installer" && ! -L "$installer" ]] || fail "dawami365-db-install-v2.sh missing/invalid in bundle."
[[ -f "$preset" && ! -L "$preset" ]] || fail "installer-presets.env missing/invalid in bundle."
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "RELEASE-MANIFEST.txt missing/invalid in bundle."
manifest_version=$(awk -F= '$1=="DAWAMI365_DB_INSTALLER_VERSION"{print $2;exit}' "$manifest")
[[ "$manifest_version" == "$version" ]] || fail "Release manifest version mismatch: expected $version, got ${manifest_version:-missing}."
chmod 0700 "$entry" "$installer"
chmod 0600 "$preset"
rm -f "$CURL_CONFIG" /tmp/dawami365-gh-error; CURL_CONFIG=""
unset GH_TOKEN
log "Starting private Dawami365 DB installer..."
cd "$WORK_DIR/extracted"
exec "$entry"
