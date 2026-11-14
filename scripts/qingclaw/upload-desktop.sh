#!/usr/bin/env bash
# Upload one packaged QingClaw macOS target with the shared OSS rules.
#
# Layout (one root for the website and electron-updater):
#   qingclaw/<quality>/desktop/qingclaw-<version>-macos-<arch>.dmg
#   qingclaw/<quality>/desktop/<arch>/nightly-mac.yml
#   qingclaw/<quality>/desktop/<arch>/qingclaw-<version>-mac-<arch>.zip
#   qingclaw/<quality>/desktop/<arch>/qingclaw-<version>-mac-<arch>.zip.blockmap

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../utils.sh
. "${script_dir}/../../utils.sh"

QINGCLAW_VERSION="${QINGCLAW_VERSION:?QINGCLAW_VERSION is required}"
QINGCLAW_ARCH="${QINGCLAW_ARCH:?QINGCLAW_ARCH is required}"
QINGCLAW_QUALITY="${QINGCLAW_QUALITY:?QINGCLAW_QUALITY is required}"
QINGCLAW_CHANNEL="${QINGCLAW_CHANNEL:-nightly}"
QINGCLAW_ARTIFACTS_DIR="${QINGCLAW_ARTIFACTS_DIR:?QINGCLAW_ARTIFACTS_DIR is required}"
PUBLIC_DOWNLOAD_DOMAIN="${PUBLIC_DOWNLOAD_DOMAIN:-d.qinglion.com}"

case "${QINGCLAW_ARCH}" in
  arm64|x64) ;;
  *) echo "[ERROR] QINGCLAW_ARCH must be arm64 or x64" >&2; exit 1 ;;
esac
case "${QINGCLAW_QUALITY}" in
  beta|stable) ;;
  *) echo "[ERROR] QINGCLAW_QUALITY must be beta or stable" >&2; exit 1 ;;
esac
case "${QINGCLAW_CHANNEL}" in
  nightly|stable) ;;
  *) echo "[ERROR] QINGCLAW_CHANNEL must be nightly or stable" >&2; exit 1 ;;
esac

artifacts="${QINGCLAW_ARTIFACTS_DIR}"
dmg="${artifacts}/qingclaw-${QINGCLAW_VERSION}-mac-${QINGCLAW_ARCH}.dmg"
zip="${artifacts}/qingclaw-${QINGCLAW_VERSION}-mac-${QINGCLAW_ARCH}.zip"
blockmap="${zip}.blockmap"
feed="${artifacts}/${QINGCLAW_CHANNEL}-mac.yml"

for file in "${dmg}" "${zip}" "${blockmap}" "${feed}"; do
  if [[ ! -s "${file}" ]]; then
    echo "[ERROR] Missing packaged artifact: ${file}" >&2
    exit 1
  fi
done

# Keep the updater metadata consistent with the files beside it.
feed_version="$(grep -E '^version:' "${feed}" | head -n1 | sed -E 's/^version:[[:space:]]*//; s/^"//; s/"$//')"
if [[ "${feed_version}" != "${QINGCLAW_VERSION}" ]]; then
  echo "[ERROR] ${feed} declares version '${feed_version}', expected '${QINGCLAW_VERSION}'" >&2
  exit 1
fi
if ! grep -Fq "$(basename "${zip}")" "${feed}"; then
  echo "[ERROR] ${feed} does not reference $(basename "${zip}")" >&2
  exit 1
fi

root="qingclaw/${QINGCLAW_QUALITY}/desktop"
dmg_key="${root}/qingclaw-${QINGCLAW_VERSION}-macos-${QINGCLAW_ARCH}.dmg"
zip_key="${root}/${QINGCLAW_ARCH}/$(basename "${zip}")"
blockmap_key="${root}/${QINGCLAW_ARCH}/$(basename "${blockmap}")"
feed_key="${root}/${QINGCLAW_ARCH}/${QINGCLAW_CHANNEL}-mac.yml"

immutable_cache='public, max-age=31536000, immutable'
feed_cache='no-store, no-cache, must-revalidate'

oss_upload_file "${dmg}" "${dmg_key}" 'application/x-apple-diskimage' "${immutable_cache}"
oss_upload_file "${zip}" "${zip_key}" 'application/zip' "${immutable_cache}"
oss_upload_file "${blockmap}" "${blockmap_key}" 'application/octet-stream' "${immutable_cache}"
oss_upload_file "${feed}" "${feed_key}" 'application/x-yaml' "${feed_cache}"

dmg_url="https://${PUBLIC_DOWNLOAD_DOMAIN}/${dmg_key}"
feed_url="https://${PUBLIC_DOWNLOAD_DOMAIN}/${feed_key}"

check_url() {
  local url="$1" expected_status="${2:-200}"
  local headers status
  headers="$(curl -fsSL -D - -o /dev/null --retry 3 --retry-delay 2 "${url}" 2>&1 || true)"
  status="$(printf '%s\n' "${headers}" | awk 'toupper($1) ~ /^HTTP\// { code=$2 } END { print code }')"
  if [[ "${status}" != "${expected_status}" ]]; then
    echo "[ERROR] ${url} returned HTTP ${status:-unknown}, expected ${expected_status}" >&2
    return 1
  fi
  printf '%s\n' "${headers}"
}

echo "Verifying ${dmg_url}"
check_url "${dmg_url}" 200 >/dev/null

echo "Verifying ${feed_url}"
feed_headers="$(check_url "${feed_url}" 200)"
if ! printf '%s\n' "${feed_headers}" | grep -Eiq '^cache-control:.*no-(store|cache)'; then
  echo "[ERROR] ${feed_url} is missing a no-cache Cache-Control header" >&2
  exit 1
fi
remote_version="$(curl -fsSL --retry 3 --retry-delay 2 "${feed_url}" | grep -E '^version:' | head -n1 | sed -E 's/^version:[[:space:]]*//; s/^"//; s/"$//')"
if [[ "${remote_version}" != "${QINGCLAW_VERSION}" ]]; then
  echo "[ERROR] ${feed_url} reports '${remote_version}', expected '${QINGCLAW_VERSION}'" >&2
  exit 1
fi

echo "QingClaw ${QINGCLAW_ARCH} published:"
echo "  ${dmg_url}"
echo "  ${feed_url}"
