#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

BOOTSTRAP_VERSION="1.0.0"
INSTALLER_REPO="${INSTALLER_REPO:-scharfesicht/Dawami365-Installer}"
WORK_DIR="${WORK_DIR:-/tmp/dawami365-bootstrap}"

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    unset GH_TOKEN
  fi
}
trap cleanup EXIT

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "Run with sudo/root."
}

install_bootstrap_dependencies() {
  local missing=()
  for cmd in curl jq sha256sum tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if (( ${#missing[@]} > 0 )); then
    log "Installing bootstrap dependencies: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl jq coreutils tar ca-certificates
  fi
}

prompt_token() {
  echo
  echo "A temporary GitHub read token is required to fetch the private installer."
  read -r -s -p "Enter installation token: " GH_TOKEN
  echo
  [[ -n "$GH_TOKEN" ]] || fail "Installation token cannot be empty."
}

github_api() {
  curl --fail --silent --show-error     -H "Accept: application/vnd.github+json"     -H "Authorization: Bearer ${GH_TOKEN}"     -H "X-GitHub-Api-Version: 2022-11-28"     "$@"
}

github_download_asset() {
  local api_url="$1"
  local output="$2"
  curl --fail --location --silent --show-error     -H "Accept: application/octet-stream"     -H "Authorization: Bearer ${GH_TOKEN}"     -H "X-GitHub-Api-Version: 2022-11-28"     -o "$output"     "$api_url"
}

resolve_release() {
  local requested="${1:-}"
  if [[ -n "$requested" ]]; then
    github_api "https://api.github.com/repos/${INSTALLER_REPO}/releases/tags/${requested}"
  else
    github_api "https://api.github.com/repos/${INSTALLER_REPO}/releases/latest"
  fi
}

main() {
  require_root
  install_bootstrap_dependencies

  local requested_tag="${1:-}"
  prompt_token

  rm -rf "$WORK_DIR"
  install -d -m 0700 "$WORK_DIR"

  log "Resolving private Dawami365 installer release..."
  local release_json tag
  release_json="$(resolve_release "$requested_tag")"
  tag="$(jq -r '.tag_name // empty' <<<"$release_json")"
  [[ -n "$tag" ]] || fail "Could not resolve installer release tag."

  local version="${tag#v}"
  local bundle="dawami365-installer-${version}.tar.gz"
  local checksum="${bundle}.sha256"

  local bundle_url checksum_url
  bundle_url="$(jq -r --arg n "$bundle" '.assets[] | select(.name==$n) | .url' <<<"$release_json")"
  checksum_url="$(jq -r --arg n "$checksum" '.assets[] | select(.name==$n) | .url' <<<"$release_json")"

  [[ -n "$bundle_url" && "$bundle_url" != "null" ]] || fail "Release asset missing: $bundle"
  [[ -n "$checksum_url" && "$checksum_url" != "null" ]] || fail "Release asset missing: $checksum"

  log "Downloading installer release ${tag}..."
  github_download_asset "$bundle_url" "$WORK_DIR/$bundle"
  github_download_asset "$checksum_url" "$WORK_DIR/$checksum"

  log "Verifying SHA-256..."
  (
    cd "$WORK_DIR"
    sha256sum -c "$checksum"
  ) || fail "Installer checksum verification failed."

  log "Checksum verified."

  install -d -m 0700 "$WORK_DIR/extracted"
  tar -xzf "$WORK_DIR/$bundle" -C "$WORK_DIR/extracted"

  local entry="$WORK_DIR/extracted/installer-entrypoint.sh"
  [[ -f "$entry" ]] || fail "installer-entrypoint.sh is missing from release bundle."
  chmod 0700 "$entry"

  unset GH_TOKEN

  log "Starting Dawami365 installer ${tag}..."
  "$entry"

  log "Bootstrap completed."
}

main "$@"
