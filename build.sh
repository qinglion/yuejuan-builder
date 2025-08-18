#!/usr/bin/env bash

set -ex

. ./utils.sh

# Resolve variables
OS_NAME="${OS_NAME:-$( detect_os_name )}"
VSCODE_ARCH="${VSCODE_ARCH:-$( detect_arch )}"
RELEASE_VERSION="${RELEASE_VERSION:-$( read_release_version )}"
CI_BUILD="${CI_BUILD:-no}"

export OS_NAME VSCODE_ARCH RELEASE_VERSION CI_BUILD

echo "RELEASE_VERSION=\"${RELEASE_VERSION}\""

# macOS: 仅收敛为四个核心变量，并做兼容映射
if [[ "${OS_NAME}" == "osx" ]]; then
  # 1) 证书：CERTIFICATE_OSX_P12_DATA -> 临时 .p12 文件 -> CSC_LINK；密码 -> CSC_KEY_PASSWORD
  if [[ -n "${CERTIFICATE_OSX_P12_DATA}" ]]; then
    TMP_BASE="${RUNNER_TEMP:-/tmp}"
    mkdir -p "${TMP_BASE}"
    CERT_FILE="${TMP_BASE}/macos_signing_${RANDOM}.p12"
    if echo test | base64 --decode >/dev/null 2>&1; then
      echo "${CERTIFICATE_OSX_P12_DATA}" | base64 --decode > "${CERT_FILE}"
    else
      echo "${CERTIFICATE_OSX_P12_DATA}" | base64 -D > "${CERT_FILE}"
    fi
    export CSC_LINK="${CERT_FILE}"
    export CSC_KEY_PASSWORD="${CERTIFICATE_OSX_P12_PASSWORD}"
  fi

  # 这段代码的意思是：如果环境变量 appleId 没有被设置（为空），但 CERTIFICATE_OSX_P12_PASSWORD 已经有值，
  # 就把 CERTIFICATE_OSX_P12_PASSWORD 的值赋给 appleId ，并导出到环境变量中。
  if [[ -z "${appleId}" && -n "${CERTIFICATE_OSX_ID}" ]]; then
    export appleId="${CERTIFICATE_OSX_ID}"
  fi
  if [[ -z "${appleApiKey}" && -n "${CERTIFICATE_OSX_APP_PASSWORD}" ]]; then
    export appleApiKey="${CERTIFICATE_OSX_APP_PASSWORD}"
  fi
fi

# Ensure app dir exists (auto-detect or clone if needed)
ensure_app_dir

pushd "${APP_DIR}"

# Node version for this project (fermium / 14.x)
if exists nvm && [[ -f .nvmrc ]]; then
  nvm use || true
fi

# Ensure Python for node-gyp (distutils via setuptools)
if command -v python3 >/dev/null 2>&1; then
  export PYTHON="$( command -v python3 )"
  python3 -m ensurepip --upgrade >/dev/null 2>&1 || true
  python3 -m pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
  # Ensure npm sees the right Python
  npm config set python "${PYTHON}" >/dev/null 2>&1 || true
  export npm_config_python="${PYTHON}"
fi

# Build renderer css first
if [[ -f package.json ]]; then
  # Force native deps to build from source if prebuilt not available
  export npm_config_build_from_source=true
  if exists yarn; then
    yarn install --network-timeout 600000
    yarn run build:css
  else
    npm install --network-timeout=600000
    npm run build:css
  fi
fi

# Clean previous artifacts and build
if exists yarn; then
  # Rebuild native modules for electron 12
  export npm_config_runtime=electron
  export npm_config_target=12.2.3
  export npm_config_disturl=https://electronjs.org/headers
  if [[ "${VSCODE_ARCH}" == "arm64" ]]; then export npm_config_target_arch=arm64; else export npm_config_target_arch=x64; fi
  (npm rebuild sqlite3 || true)
  (npm rebuild nodejieba || true)
  yarn run dist:clean || true
  yarn run build || true
  yarn run dist
else
  # Rebuild native modules for electron 12
  export npm_config_runtime=electron
  export npm_config_target=12.2.3
  export npm_config_disturl=https://electronjs.org/headers
  if [[ "${VSCODE_ARCH}" == "arm64" ]]; then export npm_config_target_arch=arm64; else export npm_config_target_arch=x64; fi
  (npm rebuild sqlite3 || true)
  (npm rebuild nodejieba || true)
  npm run dist:clean || true
  npm run build || true
  npm run dist
fi

popd

# Collect artifacts into ./assets
mkdir -p assets

# Electron-builder outputs to APP_DIR/build by config
shopt -s nullglob
for f in "${APP_DIR}/build"/*.{dmg,zip,exe,blockmap,AppImage,deb,rpm}; do
  cp -f "$f" assets/
done
shopt -u nullglob

# Set platform for downstream scripts
case "${OS_NAME}" in
  osx)   export VSCODE_PLATFORM="darwin" ;;
  linux) export VSCODE_PLATFORM="linux" ;;
  *)     export VSCODE_PLATFORM="win32" ;;
esac

echo "Assets prepared in ./assets"


