#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
export LC_ALL=C
umask 077

BOOTSTRAP_VERSION="1.0.6"
INSTALLER_REPO="${INSTALLER_REPO:-scharfesicht/Dawami365-Installer}"
WORK_DIR="${WORK_DIR:-/tmp/dawami365-app-bootstrap}"

log(){ printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){
  unset GH_TOKEN 2>/dev/null || true
  [[ -n "${CURL_CONFIG:-}" ]] && rm -f "$CURL_CONFIG" 2>/dev/null || true
}
trap cleanup EXIT

apt_get(){ apt-get -o DPkg::Lock::Timeout=300 -o Acquire::Retries=4 "$@"; }
curl_retry(){ curl --retry 5 --retry-delay 2 --retry-all-errors --connect-timeout 15 --max-time 240 "$@"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run with sudo/root."

for cmd in curl jq sha256sum tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt_get update -y
    apt_get install -y --no-upgrade curl jq coreutils tar ca-certificates
    break
  fi
done

INPUT_TAG="${1:-}"
APP_IMAGE_VERSION="${2:-${DAWAMI_APP_IMAGE_VERSION:-}}"
APP_IMAGE_DIGEST="${3:-${DAWAMI_APP_IMAGE_DIGEST:-}}"

[[ -n "$INPUT_TAG" ]] || fail "Usage: sudo $0 <app-v1.0.6|v1.0.6|1.0.6> <application-image-version> <sha256:digest>"
[[ -n "$APP_IMAGE_VERSION" ]] || fail "Application image version is required. Example: 2026.10.01.1"
[[ "$APP_IMAGE_VERSION" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}\.[0-9]+$ ]] || fail "Invalid application image version: $APP_IMAGE_VERSION"
[[ -n "$APP_IMAGE_DIGEST" ]] || fail "Application image digest is required."
[[ "$APP_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "Invalid application image digest: $APP_IMAGE_DIGEST"

case "$INPUT_TAG" in
  app-v*)
    VERSION="${INPUT_TAG#app-v}"
    RELEASE_TAG="$INPUT_TAG"
    ;;
  v*)
    VERSION="${INPUT_TAG#v}"
    RELEASE_TAG="app-v${VERSION}"
    ;;
  *)
    VERSION="$INPUT_TAG"
    RELEASE_TAG="app-v${VERSION}"
    ;;
esac

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid version/tag: $INPUT_TAG"

bundle="dawami365-app-installer-${VERSION}.tar.gz"
checksum="${bundle}.sha256"

echo
echo "A temporary GitHub read token is required to fetch the private Dawami365 App installer."
release_json=""
for attempt in 1 2 3; do
  read -r -s -p "Enter installation token: " GH_TOKEN
  echo
  [[ -n "$GH_TOKEN" ]] || continue

  CURL_CONFIG="$(mktemp)"
  chmod 0600 "$CURL_CONFIG"
  cat > "$CURL_CONFIG" <<CFG
header = "Authorization: Bearer ${GH_TOKEN}"
header = "X-GitHub-Api-Version: 2022-11-28"
CFG

  if release_json="$(curl_retry \
      --fail --silent --show-error \
      --config "$CURL_CONFIG" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${INSTALLER_REPO}/releases/tags/${RELEASE_TAG}" \
      2>/tmp/dawami365-app-gh-error)"; then
    break
  fi

  rm -f "$CURL_CONFIG"
  CURL_CONFIG=""
  unset GH_TOKEN
  (( attempt < 3 )) && echo "Token rejected or GitHub request failed; try again." >&2
done

[[ -n "$release_json" ]] || {
  cat /tmp/dawami365-app-gh-error >&2 2>/dev/null || true
  fail "Unable to access private installer release ${INSTALLER_REPO}:${RELEASE_TAG}."
}

api_download(){
  curl_retry --fail --location --silent --show-error \
    --config "$CURL_CONFIG" \
    -H "Accept: application/octet-stream" \
    -o "$2" "$1"
}

rm -rf "$WORK_DIR"
install -d -m 0700 "$WORK_DIR"

bundle_url="$(jq -r --arg n "$bundle" '[.assets[] | select(.name==$n) | .url][0] // empty' <<<"$release_json")"
checksum_url="$(jq -r --arg n "$checksum" '[.assets[] | select(.name==$n) | .url][0] // empty' <<<"$release_json")"
[[ -n "$bundle_url" && -n "$checksum_url" ]] || fail "Required release assets missing: $bundle / $checksum"

api_download "$bundle_url" "$WORK_DIR/$bundle"
api_download "$checksum_url" "$WORK_DIR/$checksum"
(cd "$WORK_DIR" && sha256sum -c "$checksum") || fail "Checksum verification failed."

tar -tzf "$WORK_DIR/$bundle" > "$WORK_DIR/archive.list"
while IFS= read -r item; do
  case "$item" in
    /*|../*|*/../*|*'/..') fail "Unsafe path in archive: $item" ;;
  esac
done < "$WORK_DIR/archive.list"

install -d -m 0700 "$WORK_DIR/extracted"
tar -xzf "$WORK_DIR/$bundle" -C "$WORK_DIR/extracted" --no-same-owner

entry="$WORK_DIR/extracted/dawami-app-installer-entrypoint.sh"
[[ -f "$entry" && ! -L "$entry" ]] || fail "Installer entrypoint missing."
chmod 0700 "$entry"

rm -f "$CURL_CONFIG" /tmp/dawami365-app-gh-error
CURL_CONFIG=""
unset GH_TOKEN

cd "$WORK_DIR/extracted"

export DAWAMI_APP_IMAGE_VERSION="$APP_IMAGE_VERSION"
export DAWAMI_APP_IMAGE_DIGEST="$APP_IMAGE_DIGEST"

log "Installer release : $RELEASE_TAG"
log "Application image : scharfesicht/dawami365:$DAWAMI_APP_IMAGE_VERSION"
log "Image digest      : $DAWAMI_APP_IMAGE_DIGEST"

exec "$entry" "$APP_IMAGE_VERSION" "$APP_IMAGE_DIGEST"
