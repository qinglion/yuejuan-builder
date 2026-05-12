#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

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
echo "OSS_ACCESS_KEY_ID=${OSS_ACCESS_KEY_ID:0:8}..."
echo "OSS_ACCESS_KEY_SECRET=${OSS_ACCESS_KEY_SECRET:0:8}..."
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

# Install ossutil 2.x if not present
OSSUTIL_VERSION="2.1.2"
OSSUTIL_BASE_URL="https://gosspublic.alicdn.com/ossutil/v2/${OSSUTIL_VERSION}"

install_ossutil() {
  local os="$1" arch="$2" zip_name="$3" extract_dir="$4" binary_name="$5"

  echo "Downloading ossutil for ${os}/${arch}..."
  if ! curl -fSL --connect-timeout 30 --retry 3 "${OSSUTIL_BASE_URL}/${zip_name}" -o ossutil.zip; then
    echo "[ERROR] Failed to download ossutil from ${OSSUTIL_BASE_URL}/${zip_name}"
    return 1
  fi

  if ! unzip -q ossutil.zip; then
    echo "[ERROR] Failed to unzip ossutil.zip"
    rm -f ossutil.zip
    return 1
  fi

  if [[ ! -f "${extract_dir}/${binary_name}" ]]; then
    echo "[ERROR] Expected binary not found: ${extract_dir}/${binary_name}"
    rm -rf ossutil.zip "${extract_dir}"
    return 1
  fi

  mkdir -p "./bin"
  chmod 755 "${extract_dir}/${binary_name}" 2>/dev/null || true
  mv "${extract_dir}/${binary_name}" "./bin/"
  export PATH="$(pwd)/bin:$PATH"
  rm -rf ossutil.zip "${extract_dir}"

  # Verify installation
  if ! command -v ossutil &> /dev/null; then
    echo "[ERROR] ossutil installed to ./bin/ but not found in PATH"
    return 1
  fi

  echo "ossutil installed successfully: $(ossutil --version 2>&1 || echo 'version check skipped')"
  return 0
}

if ! command -v ossutil &> /dev/null; then
  echo "Installing ossutil v${OSSUTIL_VERSION}..."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
      install_ossutil "linux" "amd64" \
        "ossutil-${OSSUTIL_VERSION}-linux-amd64.zip" \
        "ossutil-v${OSSUTIL_VERSION}-linux-amd64" "ossutil" || exit 1
    else
      install_ossutil "linux" "arm64" \
        "ossutil-${OSSUTIL_VERSION}-linux-arm64.zip" \
        "ossutil-v${OSSUTIL_VERSION}-linux-arm64" "ossutil" || exit 1
    fi
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
      install_ossutil "mac" "amd64" \
        "ossutil-${OSSUTIL_VERSION}-mac-amd64.zip" \
        "ossutil-v${OSSUTIL_VERSION}-mac-amd64" "ossutil" || exit 1
    else
      install_ossutil "mac" "arm64" \
        "ossutil-${OSSUTIL_VERSION}-mac-arm64.zip" \
        "ossutil-v${OSSUTIL_VERSION}-mac-arm64" "ossutil" || exit 1
    fi
  elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]] || [[ "$OSTYPE" == "cygwin" ]]; then
    # Windows (Git Bash / MSYS2 / Cygwin)
    if ! install_ossutil "windows" "amd64" \
      "ossutil-${OSSUTIL_VERSION}-windows-amd64-go1.20.zip" \
      "ossutil-${OSSUTIL_VERSION}-windows-amd64-go1.20" "ossutil.exe"; then
      # Fallback: try PowerShell download
      echo "Bash download failed, trying PowerShell fallback..."
      pwsh -NoProfile -Command "
        \$url = '${OSSUTIL_BASE_URL}/ossutil-${OSSUTIL_VERSION}-windows-amd64-go1.20.zip'
        Write-Host \"Downloading \$url\"
        Invoke-WebRequest -Uri \$url -OutFile ossutil.zip -ErrorAction Stop
        Expand-Archive -Path ossutil.zip -DestinationPath . -Force
        New-Item -ItemType Directory -Force ./bin | Out-Null
        Move-Item -Force 'ossutil-${OSSUTIL_VERSION}-windows-amd64-go1.20/ossutil.exe' ./bin/
        Remove-Item -Recurse -Force ossutil.zip, 'ossutil-${OSSUTIL_VERSION}-windows-amd64-go1.20'
      " || { echo "[ERROR] PowerShell fallback also failed"; exit 1; }
      export PATH="$(pwd)/bin:$PATH"
      if ! command -v ossutil &> /dev/null; then
        echo "[ERROR] ossutil still not found after PowerShell install"
        exit 1
      fi
      echo "ossutil installed via PowerShell fallback"
    fi
  else
    echo "[ERROR] Unsupported OS: ${OSTYPE}"
    exit 1
  fi
fi

get_platform() {
  echo "${VSCODE_PLATFORM:-linux}"
}

upload_to_oss() {
  local file_path="$1"; local file_name="$2"; local platform="$3"
  # Fallback: parse version like 1.2.3 or 1.2.3-xx from file name when RELEASE_VERSION is empty
  local inferred_version
  if is_version_missing "${RELEASE_VERSION}"; then
    inferred_version=$( echo "${file_name}" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+(-[0-9]+)?' | head -n1 || true )
    RELEASE_VERSION="${inferred_version}"
  fi
  local oss_path="${APP_NAME}/${APP_QUALITY}/${RELEASE_VERSION}/${platform}/${file_name}"
  echo "Uploading ${file_name} -> oss://${OSS_BUCKET_NAME}/${oss_path}"
  for i in {1..3}; do
    if ossutil cp "${file_path}" "oss://${OSS_BUCKET_NAME}/${oss_path}" -f \
      --access-key-id "${OSS_ACCESS_KEY_ID}" \
      --access-key-secret "${OSS_ACCESS_KEY_SECRET}" \
      --endpoint "https://${OSS_ENDPOINT}"; then
      ossutil set-acl "oss://${OSS_BUCKET_NAME}/${oss_path}" --acl public-read \
        --access-key-id "${OSS_ACCESS_KEY_ID}" \
        --access-key-secret "${OSS_ACCESS_KEY_SECRET}" \
        --endpoint "https://${OSS_ENDPOINT}"
      echo "Successfully uploaded ${file_name} (attempt ${i})"
      return 0
    else
      echo "Failed to upload ${file_name} (attempt ${i})"
      if [[ $i -eq 3 ]]; then
        echo "Failed to upload ${file_name} after 3 attempts"
        return 1
      fi
      sleep 10
    fi
  done
}

cd assets || { echo "[ERROR] assets dir not found"; exit 1; }

exit_code=0
for file in *; do
  if [[ -f "$file" ]]; then
    platform=$(get_platform)
    if ! upload_to_oss "$file" "$file" "$platform"; then
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
