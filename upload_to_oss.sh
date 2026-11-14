#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

# === VERSION MARKER: 2026-05-19 fix-ossutil-v230 ===
echo "[upload_to_oss.sh] version: fix-ossutil-v230 (2026-05-19)"

# Try to load helpers first (for read_release_version, etc.)
if [[ -f ./utils.sh ]]; then
  . ./utils.sh
fi

# Best-effort derive release version early to avoid empty path segments
# Missing means empty or "0.0.0" (default placeholder). We'll prefer real version if we can detect it.
is_version_missing() { [[ -z "$1" || "$1" == "0.0.0" ]]; }

# Try to locate app dir locally if not provided (common clone path derived from APP_REPO)
detect_app_dir() {
  if [[ -n "${APP_DIR}" && -f "${APP_DIR}/package.json" ]]; then
    return 0
  fi
  local candidate
  if [[ -n "${APP_REPO}" ]]; then
    candidate="./$( basename "${APP_REPO%.git}" )"
    if [[ -f "${candidate}/package.json" ]]; then
      APP_DIR="${candidate}"
      export APP_DIR
      return 0
    fi
  fi
  # Fallback to common repo name
  if [[ -f "./qinglion_yuejuan/package.json" ]]; then
    APP_DIR="./qinglion_yuejuan"
    export APP_DIR
  fi
}

# Derive version from package.json when current version is missing
derive_release_version() {
  if ! is_version_missing "${RELEASE_VERSION}"; then
    return 0
  fi
  detect_app_dir
  if [[ -n "${APP_DIR}" && -f "${APP_DIR}/package.json" ]]; then
    # Prefer direct node read to avoid helper depending on APP_DIR env in another step
    local pkg_ver
    pkg_ver=$( node -p "require('${APP_DIR}/package.json').version" 2>/dev/null || true )
    if [[ -n "${pkg_ver}" ]]; then
      RELEASE_VERSION="${pkg_ver}"
      return 0
    fi
  fi
  # As a secondary attempt, use helper if available
  if command -v read_release_version >/dev/null 2>&1; then
    local candidate_ver
    candidate_ver="$( read_release_version )"
    if [[ -n "${candidate_ver}" && "${candidate_ver}" != "0.0.0" ]]; then
      RELEASE_VERSION="${candidate_ver}"
      return 0
    fi
  fi
}

# Attempt to derive a real version before uploads
derive_release_version

# Echo envs
echo "----------- OSS Upload -----------"
echo "OSS credentials: configured"
echo "OSS_BUCKET_NAME=${OSS_BUCKET_NAME}"
echo "OSS_ENDPOINT=${OSS_ENDPOINT}"
echo "OSS_REGION=${OSS_REGION}"
echo "APP_NAME=${APP_NAME}"
echo "RELEASE_VERSION=${RELEASE_VERSION}"
echo "VSCODE_PLATFORM=${VSCODE_PLATFORM}"
echo "-------------------------"

if [[ -z "${OSS_ACCESS_KEY_ID}" || -z "${OSS_ACCESS_KEY_SECRET}" || -z "${OSS_BUCKET_NAME}" ]]; then
  echo "[ERROR] OSS credentials are required but missing."
  exit 1
fi

# ossutil installation and object upload are shared with QingClaw in utils.sh.
get_platform() {
  echo "${VSCODE_PLATFORM:-linux}"
}

cd assets || { echo "[ERROR] assets dir not found"; exit 1; }

exit_code=0
for file in *; do
  if [[ -f "$file" ]]; then
    platform=$(get_platform)
    oss_path="${APP_NAME}/${APP_QUALITY}/${RELEASE_VERSION}/${platform}/${file}"
    if ! oss_upload_file "$file" "${oss_path}" "" ""; then
      echo "[ERROR] Failed to upload ${file}"
      exit_code=1
    fi
  fi
done

# Generate url list for later version update
mkdir -p ../oss_urls
for file in *; do
  if [[ -f "$file" && "$file" != *.sha1 && "$file" != *.sha256 ]]; then
    if [[ -n "${PUBLIC_DOWNLOAD_DOMAIN}" ]]; then
      base_url="https://${PUBLIC_DOWNLOAD_DOMAIN}"
    else
      base_url="https://${OSS_BUCKET_NAME}.${OSS_ENDPOINT}"
    fi
    platform=$(get_platform)
    echo "${base_url}/${APP_NAME}/${APP_QUALITY}/${RELEASE_VERSION}/${platform}/${file}" > "../oss_urls/${file}.url"
  fi
done

cd ..

# Propagate failure if any upload failed
if [[ ${exit_code} -ne 0 ]]; then
  exit ${exit_code}
fi
