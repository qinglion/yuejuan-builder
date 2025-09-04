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
if ! command -v ossutil &> /dev/null; then
  echo "Installing ossutil..."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
      curl -sL https://gosspublic.alicdn.com/ossutil/v2/2.1.2/ossutil-2.1.2-linux-amd64.zip -o ossutil.zip
      unzip -q ossutil.zip
      chmod 755 ossutil-v2.1.2-linux-amd64/ossutil
      sudo mv ossutil-v2.1.2-linux-amd64/ossutil /usr/local/bin/
      rm -rf ossutil.zip ossutil-v2.1.2-linux-amd64
    else
      curl -sL https://gosspublic.alicdn.com/ossutil/v2/2.1.2/ossutil-2.1.2-linux-arm64.zip -o ossutil.zip
      unzip -q ossutil.zip
      chmod 755 ossutil-2.1.2-linux-arm64/ossutil
      sudo mv ossutil-2.1.2-linux-arm64/ossutil /usr/local/bin/
      rm -rf ossutil.zip ossutil-2.1.2-linux-arm64
    fi
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
      # macOS Intel
      curl -sL https://gosspublic.alicdn.com/ossutil/v2/2.1.2/ossutil-2.1.2-mac-amd64.zip -o ossutil.zip
      unzip -q ossutil.zip
      chmod 755 ossutil-2.1.2-mac-amd64/ossutil
      sudo mv ossutil-2.1.2-mac-amd64/ossutil /usr/local/bin/
      rm -rf ossutil.zip ossutil-2.1.2-mac-amd64
    else
      # macOS Apple Silicon
      curl -sL https://gosspublic.alicdn.com/ossutil/v2/2.1.2/ossutil-2.1.2-mac-arm64.zip -o ossutil.zip
      unzip -q ossutil.zip
      chmod 755 ossutil-2.1.2-mac-arm64/ossutil
      sudo mv ossutil-2.1.2-mac-arm64/ossutil /usr/local/bin/
      rm -rf ossutil.zip ossutil-2.1.2-mac-arm64
    fi
  elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
    curl -sL https://gosspublic.alicdn.com/ossutil/v2/2.1.2/ossutil-2.1.2-windows-amd64-go1.20.zip -o ossutil.zip
    unzip -q ossutil.zip
    # Create local bin directory if it doesn't exist and move ossutil there
    mkdir -p "./bin"
    mv ossutil-2.1.2-windows-amd64-go1.20/ossutil.exe ./bin/
    # Add local bin to PATH for current session
    export PATH="$(pwd)/bin:$PATH"
    rm -rf ossutil.zip ossutil-2.1.2-windows-amd64-go1.20
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
