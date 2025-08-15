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

# macOS: map CERTIFICATE_OSX_* to electron-builder envs (CSC_*, APPLE_*)
if [[ "${OS_NAME}" == "osx" ]]; then
  # Write P12 from base64 and export CSC envs
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
    if [[ -n "${CERTIFICATE_OSX_P12_PASSWORD}" ]]; then
      export CSC_KEY_PASSWORD="${CERTIFICATE_OSX_P12_PASSWORD}"
    fi
  fi

  # Map Apple notarization envs if not already set
  if [[ -n "${CERTIFICATE_OSX_ID}" && -z "${APPLE_ID}" ]]; then
    export APPLE_ID="${CERTIFICATE_OSX_ID}"
  fi
  if [[ -n "${CERTIFICATE_OSX_APP_PASSWORD}" ]]; then
    # For legacy flows that still read APPLE_ID_PASSWORD
    if [[ -z "${APPLE_ID_PASSWORD}" ]]; then
      export APPLE_ID_PASSWORD="${CERTIFICATE_OSX_APP_PASSWORD}"
    fi
    # Newer @electron/notarize expects APPLE_APP_SPECIFIC_PASSWORD
    if [[ -z "${APPLE_APP_SPECIFIC_PASSWORD}" ]]; then
      export APPLE_APP_SPECIFIC_PASSWORD="${CERTIFICATE_OSX_APP_PASSWORD}"
    fi
  fi
  if [[ -n "${CERTIFICATE_OSX_TEAM_ID}" && -z "${APPLE_TEAM_ID}" ]]; then
    export APPLE_TEAM_ID="${CERTIFICATE_OSX_TEAM_ID}"
  fi
fi

# Ensure app dir exists (auto-detect or clone if needed)
ensure_app_dir

pushd "${APP_DIR}"

# For macOS notarization on electron-builder 24: inject build.mac.notarize into package.json
if [[ "${OS_NAME}" == "osx" ]]; then
  if command -v jq >/dev/null 2>&1; then
    cp package.json package.json.bak
    tmp_json=$( jq \
      --arg teamId "${APPLE_TEAM_ID}" \
      --arg appleId "${APPLE_ID}" \
      --arg appPwd "${APPLE_APP_SPECIFIC_PASSWORD}" \
      --arg appBundleId "com.qinglion.storm" \
      '(.build.mac.notarize //= {})
       | .build.mac.notarize.teamId = $teamId
       | .build.mac.notarize.appleId = $appleId
       | .build.mac.notarize.appleAppSpecificPassword = $appPwd
       | .build.mac.notarize.appBundleId = $appBundleId
       | (if .build.afterSign then del(.build.afterSign) else . end)' package.json )
    echo "${tmp_json}" > package.json && unset tmp_json
  fi
fi

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


