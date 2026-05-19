#!/usr/bin/env bash

set -ex

. ./utils.sh

# Resolve variables
OS_NAME="${OS_NAME:-$( detect_os_name )}"
VSCODE_ARCH="${VSCODE_ARCH:-$( detect_arch )}"
RELEASE_VERSION="${RELEASE_VERSION:-$( read_release_version )}"
CI_BUILD="${CI_BUILD:-no}"
# BUILD_STAGE: full (default) | renderer-only | package-only
# - renderer-only: webpack 跑完即停（Node 14 兼容机器用）
# - package-only:  跳过 webpack，需要先解压 RENDERER_DIST_TARBALL（现代 Node 机器用）
BUILD_STAGE="${BUILD_STAGE:-full}"

export OS_NAME VSCODE_ARCH RELEASE_VERSION CI_BUILD BUILD_STAGE

echo "RELEASE_VERSION=\"${RELEASE_VERSION}\""
echo "BUILD_STAGE=\"${BUILD_STAGE}\""

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

# Inject build-time channel/arch into package.json build.extraMetadata, then restore
PKG_FILE="package.json"
RESTORE_PKG="no"
if [[ -f "${PKG_FILE}" ]]; then
  cp -f "${PKG_FILE}" "${PKG_FILE}.bak"
  RESTORE_PKG="yes"
  if command -v jq >/dev/null 2>&1; then
    TMP_JSON="${PKG_FILE}.tmp"
    jq '(.product //= {}) | (if env.APP_QUALITY then .product.quality = env.APP_QUALITY else . end) | (if env.VSCODE_ARCH then .product.arch = env.VSCODE_ARCH else . end) | (if (env.APP_QUALITY == "insider") then (.build //= {}) | (.build.productName = "青狮阅卷Beta") else . end)' "${PKG_FILE}" > "${TMP_JSON}" && mv -f "${TMP_JSON}" "${PKG_FILE}"
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

# Restore renderer-dist tarball (only in package-only mode)
if [[ "${BUILD_STAGE}" == "package-only" ]]; then
  if [[ -z "${RENDERER_DIST_TARBALL}" || ! -f "${RENDERER_DIST_TARBALL}" ]]; then
    echo "[ERROR] BUILD_STAGE=package-only requires RENDERER_DIST_TARBALL pointing to an existing tarball"
    exit 1
  fi
  echo "Extracting renderer-dist tarball: ${RENDERER_DIST_TARBALL}"
  tar -xzf "${RENDERER_DIST_TARBALL}" -C .
fi

# Build renderer css first
if [[ -f package.json ]]; then
  # Force native deps to build from source on non-Windows only.
  # Skip in package-only — node-sass postinstall would invoke node-gyp@3.8.0
  # which uses Python 2 syntax and dies on Python 3-only runners.
  if [[ "${OS_NAME}" != "windows" && "${BUILD_STAGE}" != "package-only" ]]; then
    export npm_config_build_from_source=true
  else
    unset npm_config_build_from_source || true
  fi

  # package-only doesn't need node-sass (renderer is already built); strip it
  # from package.json so yarn never tries to compile it. Restore on exit.
  if [[ "${BUILD_STAGE}" == "package-only" && -f package.json ]]; then
    cp -f package.json package.json.pkgonly.bak
    [[ -f yarn.lock ]] && cp -f yarn.lock yarn.lock.pkgonly.bak
    node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('package.json','utf8'));['dependencies','devDependencies','optionalDependencies'].forEach(k=>{if(p[k]&&p[k]['node-sass'])delete p[k]['node-sass'];});fs.writeFileSync('package.json',JSON.stringify(p,null,2));"
    trap 'mv -f package.json.pkgonly.bak package.json 2>/dev/null || true; [[ -f yarn.lock.pkgonly.bak ]] && mv -f yarn.lock.pkgonly.bak yarn.lock 2>/dev/null || true' EXIT
  fi

  if exists yarn; then
    INSTALL_FLAGS="--network-timeout 600000"
    if [[ "${OS_NAME}" == "windows" ]]; then
      INSTALL_FLAGS+=" --ignore-optional"
    fi
    # package-only runs on modern Node (>=20) where legacy fsevents@1 / nan
    # fail to compile; skip optional deps since they're build-time only.
    if [[ "${BUILD_STAGE}" == "package-only" ]]; then
      INSTALL_FLAGS+=" --ignore-optional"
    fi
    yarn install ${INSTALL_FLAGS}
    if [[ "${BUILD_STAGE}" != "package-only" ]]; then
      yarn run build:css
    fi
  else
    if [[ "${OS_NAME}" == "windows" || "${BUILD_STAGE}" == "package-only" ]]; then
      npm install --no-optional --network-timeout=600000
    else
      npm install --network-timeout=600000
    fi
    if [[ "${BUILD_STAGE}" != "package-only" ]]; then
      npm run build:css
    fi
  fi
fi

# Stage A: renderer-only — run webpack and stop (no dist, no collect)
if [[ "${BUILD_STAGE}" == "renderer-only" ]]; then
  if exists yarn; then
    yarn run build
  else
    npm run build
  fi
  popd

  # Package renderer artifacts for downstream package-only jobs
  TARBALL_OUT="${RENDERER_DIST_OUT:-./renderer-dist.tar.gz}"
  echo "Packing renderer dist into ${TARBALL_OUT}"
  tar -czf "${TARBALL_OUT}" \
    -C "${APP_DIR}" \
    dist/electron \
    package.json \
    static
  echo "Renderer-only stage complete: ${TARBALL_OUT}"
  exit 0
fi

# Clean previous artifacts and build
if exists yarn; then
  yarn run dist:clean || true
  if [[ "${BUILD_STAGE}" != "package-only" ]]; then
    yarn run build
  fi
  # package-only: renderer already built, call electron-builder directly with explicit arch
  if [[ "${BUILD_STAGE}" == "package-only" ]]; then
    if [[ "${OS_NAME}" == "osx" ]]; then
      npx electron-builder --mac --"${VSCODE_ARCH}"
    elif [[ "${OS_NAME}" == "windows" ]]; then
      npx electron-builder --win --"${VSCODE_ARCH}"
    else
      npx electron-builder --linux --"${VSCODE_ARCH}"
    fi
  else
    if [[ "${OS_NAME}" == "osx" ]]; then
      yarn run dist || yarn run build:mac
    elif [[ "${OS_NAME}" == "windows" ]]; then
      yarn run dist:win || yarn run dist
    else
      yarn run dist
    fi
  fi
else
  npm run dist:clean || true
  if [[ "${BUILD_STAGE}" != "package-only" ]]; then
    npm run build
  fi
  if [[ "${BUILD_STAGE}" == "package-only" ]]; then
    if [[ "${OS_NAME}" == "osx" ]]; then
      npx electron-builder --mac --"${VSCODE_ARCH}"
    elif [[ "${OS_NAME}" == "windows" ]]; then
      npx electron-builder --win --"${VSCODE_ARCH}"
    else
      npx electron-builder --linux --"${VSCODE_ARCH}"
    fi
  else
    if [[ "${OS_NAME}" == "osx" ]]; then
      npm run dist || npm run build:mac
    elif [[ "${OS_NAME}" == "windows" ]]; then
      npm run dist:win || npm run dist
    else
      npm run dist
    fi
  fi
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

# Fail fast if no installable artifacts were collected
asset_count=$(find assets/ -maxdepth 1 -type f \( -name "*.dmg" -o -name "*.zip" -o -name "*.exe" -o -name "*.AppImage" -o -name "*.deb" -o -name "*.rpm" \) | wc -l)
if [[ "${asset_count}" -eq 0 ]]; then
  echo "[ERROR] No artifacts found in assets/ — dist step likely failed. Aborting."
  exit 1
fi

# Rename Chinese productName in asset filenames to ASCII alias for updater
shopt -s nullglob
for f in assets/*青狮阅卷*; do
  new="${f//青狮阅卷/QingLion}"
  mv -f "$f" "$new"
done
shopt -u nullglob

# Append branch suffix to asset filenames (when not on master)
SAFE_BRANCH="${APP_BRANCH:-}" 
if [[ -n "${SAFE_BRANCH}" && "${SAFE_BRANCH}" != "master" ]]; then
  # sanitize branch for filenames: replace non-alnum/._- with '-'
  SAFE_BRANCH=$( echo "${SAFE_BRANCH}" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' )
  if [[ -n "${SAFE_BRANCH}" ]]; then
    shopt -s nullglob
    for f in assets/*; do
      # skip checksum files
      [[ -f "$f" ]] || continue
      case "$f" in
        *.sha1|*.sha256) continue ;;
      esac
      dir="$( dirname "$f" )"
      base="$( basename "$f" )"
      # Avoid double-tagging
      if [[ "$base" == *"-${SAFE_BRANCH}"* ]]; then
        continue
      fi
      # Determine extension (handle .tar.gz and .blockmap specially)
      ext=""
      name_no_ext="$base"
      if [[ "$base" == *.tar.gz ]]; then
        ext=".tar.gz"
        name_no_ext="${base%*.tar.gz}"
      elif [[ "$base" == *.blockmap ]]; then
        ext=".blockmap"
        name_no_ext="${base%*.blockmap}"
      else
        if [[ "$base" == *.* ]]; then
          ext=".${base##*.}"
          name_no_ext="${base%.*}"
        fi
      fi
      new_name="${name_no_ext}-${SAFE_BRANCH}${ext}"
      mv -f "$f" "${dir}/${new_name}"
    done
    shopt -u nullglob
  fi
fi

# Set platform for downstream scripts
case "${OS_NAME}" in
  osx)   export VSCODE_PLATFORM="darwin" ;;
  linux) export VSCODE_PLATFORM="linux" ;;
  *)     export VSCODE_PLATFORM="win32" ;;
esac

echo "Assets prepared in ./assets"


