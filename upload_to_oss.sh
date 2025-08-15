#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

# Echo envs
echo "----------- OSS Upload -----------"
echo "OSS_ACCESS_KEY_ID=${OSS_ACCESS_KEY_ID:0:8}..."
echo "OSS_BUCKET_NAME=${OSS_BUCKET_NAME}"
echo "OSS_ENDPOINT=${OSS_ENDPOINT}"
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
  if [[ "$OSTYPE" == "darwin"* ]]; then
    curl -sL https://gosspublic.alicdn.com/ossutil/v2/2.1.2/ossutil-2.1.2-mac-arm64.zip -o ossutil.zip
    unzip -q ossutil.zip
    chmod 755 ossutil-2.1.2-mac-arm64/ossutil
    sudo mv ossutil-2.1.2-mac-arm64/ossutil /usr/local/bin/
    rm -rf ossutil.zip ossutil-2.1.2-mac-arm64
  else
    curl -sL https://gosspublic.alicdn.com/ossutil/v2/2.1.1/ossutil-2.1.1-linux-amd64.zip -o ossutil.zip
    unzip -q ossutil.zip
    chmod 755 ossutil-v2.1.1-linux-amd64/ossutil
    sudo mv ossutil-v2.1.1-linux-amd64/ossutil /usr/local/bin/
    rm -rf ossutil.zip ossutil-v2.1.1-linux-amd64
  fi
fi

get_platform() {
  echo "${VSCODE_PLATFORM:-linux}"
}

upload_to_oss() {
  local file_path="$1"; local file_name="$2"; local platform="$3"
  local oss_path="${APP_NAME}/${RELEASE_VERSION}/${platform}/${file_name}"
  echo "Uploading ${file_name} -> oss://${OSS_BUCKET_NAME}/${oss_path}"
  ossutil cp "${file_path}" "oss://${OSS_BUCKET_NAME}/${oss_path}" \
    --access-key-id "${OSS_ACCESS_KEY_ID}" \
    --access-key-secret "${OSS_ACCESS_KEY_SECRET}" \
    --endpoint "https://${OSS_ENDPOINT}"
  ossutil set-acl "oss://${OSS_BUCKET_NAME}/${oss_path}" public-read \
    --access-key-id "${OSS_ACCESS_KEY_ID}" \
    --access-key-secret "${OSS_ACCESS_KEY_SECRET}" \
    --endpoint "https://${OSS_ENDPOINT}"
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
    echo "${base_url}/${APP_NAME}/${RELEASE_VERSION}/${platform}/${file}" > "../oss_urls/${file}.url"
  fi
done

cd ..

# Propagate failure if any upload failed
if [[ ${exit_code} -ne 0 ]]; then
  exit ${exit_code}
fi
