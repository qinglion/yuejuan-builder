#!/usr/bin/env bash
# Upload one packaged QingClaw Windows target with the shared OSS rules.
#
# Layout:
#   qingclaw/<quality>/desktop/qingclaw-<version>-windows-x64.exe
#   qingclaw/<quality>/desktop/qingclaw-<version>-windows-x64.exe.blockmap
#   qingclaw/<quality>/desktop/win-x64/<channel>.yml

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${script_dir}/../../utils.sh"

QINGCLAW_VERSION="${QINGCLAW_VERSION:?QINGCLAW_VERSION is required}"
QINGCLAW_QUALITY="${QINGCLAW_QUALITY:?QINGCLAW_QUALITY is required}"
QINGCLAW_CHANNEL="${QINGCLAW_CHANNEL:-nightly}"
QINGCLAW_ARTIFACTS_DIR="${QINGCLAW_ARTIFACTS_DIR:?QINGCLAW_ARTIFACTS_DIR is required}"
PUBLIC_DOWNLOAD_DOMAIN="${PUBLIC_DOWNLOAD_DOMAIN:-d.qinglion.com}"

case "${QINGCLAW_QUALITY}" in
  beta|stable) ;;
  *) echo "[ERROR] QINGCLAW_QUALITY must be beta or stable" >&2; exit 1 ;;
esac
case "${QINGCLAW_CHANNEL}" in
  nightly|stable) ;;
  *) echo "[ERROR] QINGCLAW_CHANNEL must be nightly or stable" >&2; exit 1 ;;
esac

artifacts="${QINGCLAW_ARTIFACTS_DIR}"
exe="${artifacts}/qingclaw-${QINGCLAW_VERSION}-windows-x64.exe"
blockmap="${exe}.blockmap"
feed="${artifacts}/${QINGCLAW_CHANNEL}.yml"

for file in "${exe}" "${blockmap}" "${feed}"; do
  if [[ ! -s "${file}" ]]; then
    echo "[ERROR] Missing packaged artifact: ${file}" >&2
    exit 1
  fi
done

root="qingclaw/${QINGCLAW_QUALITY}/desktop"
exe_key="${root}/qingclaw-${QINGCLAW_VERSION}-windows-x64.exe"
blockmap_key="${blockmap_key:-${root}/qingclaw-${QINGCLAW_VERSION}-windows-x64.exe.blockmap}"
feed_key="${root}/win-x64/${QINGCLAW_CHANNEL}.yml"
exe_url="https://${PUBLIC_DOWNLOAD_DOMAIN}/${exe_key}"
feed_url="https://${PUBLIC_DOWNLOAD_DOMAIN}/${feed_key}"

feed_version="$(grep -E '^version:' "${feed}" | head -n1 | sed -E 's/^version:[[:space:]]*//; s/^"//; s/"$//')"
if [[ "${feed_version}" != "${QINGCLAW_VERSION}" ]]; then
  echo "[ERROR] ${feed} declares '${feed_version}', expected '${QINGCLAW_VERSION}'" >&2
  exit 1
fi

# The website installer lives in the parent directory while the feed lives in
# win-x64; absolute URLs keep electron-updater on the same versioned file.
rewritten_feed="$(mktemp)"
trap 'rm -f "${rewritten_feed}"' EXIT
sed -E "s#^(path|  - url):[[:space:]]*qingclaw-${QINGCLAW_VERSION}-windows-x64\\.exe[[:space:]]*\$#\\1: ${exe_url}#" "${feed}" > "${rewritten_feed}"
if ! grep -Fq "${exe_url}" "${rewritten_feed}"; then
  echo "[ERROR] Could not rewrite ${feed} to ${exe_url}" >&2
  exit 1
fi

immutable_cache='public, max-age=31536000, immutable'
feed_cache='no-store, no-cache, must-revalidate'

oss_upload_file "${exe}" "${exe_key}" 'application/vnd.microsoft.portable-executable' "${immutable_cache}"
oss_upload_file "${blockmap}" "${blockmap_key}" 'application/octet-stream' "${immutable_cache}"
oss_upload_file "${rewritten_feed}" "${feed_key}" 'application/x-yaml' "${feed_cache}"

head_status() {
  local url="$1"
  local headers status
  headers="$(curl -fsSL -D - -o /dev/null --retry 3 --retry-delay 2 "${url}" 2>&1 || true)"
  status="$(printf '%s\n' "${headers}" | awk 'toupper($1) ~ /^HTTP\// { code=$2 } END { print code }')"
  if [[ "${status}" != "200" ]]; then
    echo "[ERROR] ${url} returned HTTP ${status:-unknown}" >&2
    return 1
  fi
  printf '%s\n' "${headers}"
}

echo "Verifying ${exe_url}"
head_status "${exe_url}" >/dev/null

echo "Verifying ${feed_url}"
feed_headers="$(head_status "${feed_url}")"
if ! printf '%s\n' "${feed_headers}" | grep -Eiq '^cache-control:.*no-(store|cache)'; then
  echo "[ERROR] ${feed_url} is missing a no-cache Cache-Control header" >&2
  exit 1
fi
remote_version="$(curl -fsSL --retry 3 --retry-delay 2 "${feed_url}" | grep -E '^version:' | head -n1 | sed -E 's/^version:[[:space:]]*//; s/^"//; s/"$//')"
if [[ "${remote_version}" != "${QINGCLAW_VERSION}" ]]; then
  echo "[ERROR] ${feed_url} reports '${remote_version}', expected '${QINGCLAW_VERSION}'" >&2
  exit 1
fi

echo "QingClaw Windows published:"
echo "  ${exe_url}"
echo "  ${feed_url}"
