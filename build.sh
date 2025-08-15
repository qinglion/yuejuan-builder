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
    if base64 --help 2>&1 | grep -q "--decode"; then
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
  if [[ -n "${CERTIFICATE_OSX_APP_PASSWORD}" && -z "${APPLE_ID_PASSWORD}" ]]; then
    export APPLE_ID_PASSWORD="${CERTIFICATE_OSX_APP_PASSWORD}"
  fi
  if [[ -n "${CERTIFICATE_OSX_TEAM_ID}" && -z "${APPLE_TEAM_ID}" ]]; then
    export APPLE_TEAM_ID="${CERTIFICATE_OSX_TEAM_ID}"
  fi
fi

# Ensure app dir exists (auto-detect or clone if needed)
ensure_app_dir

pushd "${APP_DIR}"

# Node version for this project (fermium / 14.x)
if exists nvm && [[ -f .nvmrc ]]; then
  nvm use || true
fi

# Build renderer css first
if [[ -f package.json ]]; then
  if exists yarn; then
    yarn install
    yarn run build:css
  else
    npm install
    npm run build:css
  fi
fi

# Clean previous artifacts and build
if exists yarn; then
  yarn run dist:clean || true
  yarn run build
  yarn run dist
else
  npm run dist:clean || true
  npm run build
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


