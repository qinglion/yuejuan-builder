#!/usr/bin/env bash
# shellcheck disable=SC1091

set -e

. ./utils.sh

echo "----------- release -----------"
echo "Environment variables:"
echo "SHOULD_BUILD=${SHOULD_BUILD}"
echo "FORCE_UPDATE=${FORCE_UPDATE}"
echo "-------------------------"

if [[ "${SHOULD_BUILD}" != "yes" && "${FORCE_UPDATE}" != "true" ]]; then
  echo "Skip updating versions since not built"
  exit 0
fi

GITHUB_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-${GH_ENTERPRISE_TOKEN:-${GITHUB_ENTERPRISE_TOKEN}}}}"
if [[ -z "${GITHUB_TOKEN}" ]]; then
  echo "No GITHUB_TOKEN provided, skip"
  exit 0
fi

GH_HOST="${GH_HOST:-github.com}"

ensure_app_dir
RELEASE_VERSION="${RELEASE_VERSION:-$( read_release_version )}"
export RELEASE_VERSION

# Default platform/arch if not provided (map utils.sh detection to expected values)
if [[ -z "${VSCODE_PLATFORM}" ]]; then
  case "$( detect_os_name )" in
    osx) VSCODE_PLATFORM="darwin" ;;
    windows) VSCODE_PLATFORM="win32" ;;
    *) VSCODE_PLATFORM="linux" ;;
  esac
fi

if [[ -z "${VSCODE_ARCH}" ]]; then
  VSCODE_ARCH="$( detect_arch )"
fi

echo "RELEASE_VERSION=\"${RELEASE_VERSION}\""

# Use app version string as BUILD_SOURCEVERSION fallback
if [[ -z "${BUILD_SOURCEVERSION}" ]]; then
  if command -v checksum >/dev/null 2>&1; then
    BUILD_SOURCEVERSION=$( echo "${RELEASE_VERSION/-*/}" | checksum )
  else
    npm i -g checksum >/dev/null 2>&1 || true
    BUILD_SOURCEVERSION=$( echo "${RELEASE_VERSION/-*/}" | checksum )
  fi
fi

export BUILD_SOURCEVERSION

# Compute URL_BASE for assets (ASSETS_REPOSITORY is a fixed https repo URL)
URL_BASE="${ASSETS_REPOSITORY%/}/releases/download/${RELEASE_VERSION}"

pick_asset_basename() {
  local pattern="$1"
  local f
  for f in ${pattern}; do
    if [[ -e "${f}" ]]; then
      basename "${f}"
      return 0
    fi
  done
  echo ""
}

# Ensure assets directory exists before proceeding
if [[ ! -d "assets" ]]; then
  echo "assets/ directory not found; skip updating versions"
  exit 0
fi

generateJson() {
  local url name version productVersion sha1hash sha256hash timestamp oss_url
  JSON_DATA="{}"

  local platform
  case "${VSCODE_PLATFORM}" in
    darwin) platform="darwin" ;;
    win32)  platform="win32" ;;
    *)      platform="linux" ;;
  esac

  # Prefer CDN domain; else OSS bucket endpoint if configured; else GitHub Releases
  if [[ -n "${PUBLIC_DOWNLOAD_DOMAIN}" ]]; then
    url="https://${PUBLIC_DOWNLOAD_DOMAIN}/${APP_NAME}/${RELEASE_VERSION}/${platform}/${ASSET_NAME}"
  elif [[ -n "${OSS_BUCKET_NAME}" && -n "${OSS_ENDPOINT}" ]]; then
    url="https://${OSS_BUCKET_NAME}.${OSS_ENDPOINT}/${APP_NAME}/${RELEASE_VERSION}/${platform}/${ASSET_NAME}"
  else
    url="${URL_BASE}/${ASSET_NAME}"
  fi

  name="${RELEASE_VERSION}"
  version="${BUILD_SOURCEVERSION}"
  productVersion="${RELEASE_VERSION}"
  timestamp=$( node -e 'console.log(Date.now())' )

  if [[ ! -f "assets/${ASSET_NAME}" ]]; then
    echo "assets/${ASSET_NAME} not found"
    exit 1
  fi

  sha1hash=$( awk '{ print $1 }' "assets/${ASSET_NAME}.sha1" )
  sha256hash=$( awk '{ print $1 }' "assets/${ASSET_NAME}.sha256" )

  if [[ -n "${PUBLIC_DOWNLOAD_DOMAIN}" ]]; then
    oss_url="https://${PUBLIC_DOWNLOAD_DOMAIN}/${APP_NAME}/${RELEASE_VERSION}/${platform}/${ASSET_NAME}"
  else
    oss_url="https://${OSS_BUCKET_NAME}.${OSS_ENDPOINT}/${APP_NAME}/${RELEASE_VERSION}/${platform}/${ASSET_NAME}"
  fi

  if [[ -n "${oss_url}" ]]; then
    JSON_DATA=$( jq \
      --arg url             "${url}" \
      --arg name            "${name}" \
      --arg version         "${version}" \
      --arg productVersion  "${productVersion}" \
      --arg hash            "${sha1hash}" \
      --arg timestamp       "${timestamp}" \
      --arg sha256hash      "${sha256hash}" \
      --arg oss_url         "${oss_url}" \
      '. | .url=$url | .name=$name | .version=$version | .productVersion=$productVersion | .hash=$hash | .timestamp=$timestamp | .sha256hash=$sha256hash | .oss_url=$oss_url' \
      <<<'{}' )
  else
    JSON_DATA=$( jq \
      --arg url             "${url}" \
      --arg name            "${name}" \
      --arg version         "${version}" \
      --arg productVersion  "${productVersion}" \
      --arg hash            "${sha1hash}" \
      --arg timestamp       "${timestamp}" \
      --arg sha256hash      "${sha256hash}" \
      '. | .url=$url | .name=$name | .version=$version | .productVersion=$productVersion | .hash=$hash | .timestamp=$timestamp | .sha256hash=$sha256hash' \
      <<<'{}' )
  fi
}

updateLatestVersion() {
  echo "Updating ${VERSION_PATH}/latest.json"

  if [[ -f "${REPOSITORY_NAME}/${VERSION_PATH}/latest.json" ]]; then
    CURRENT_VERSION=$( jq -r '.name' "${REPOSITORY_NAME}/${VERSION_PATH}/latest.json" )
    echo "CURRENT_VERSION: ${CURRENT_VERSION}"
    if [[ "${CURRENT_VERSION}" == "${RELEASE_VERSION}" && "${FORCE_UPDATE}" != "true" ]]; then
      return 0
    fi
  fi

  echo "Generating ${VERSION_PATH}/latest.json"

  mkdir -p "${REPOSITORY_NAME}/${VERSION_PATH}"

  generateJson
  echo "${JSON_DATA}" > "${REPOSITORY_NAME}/${VERSION_PATH}/latest.json"
  echo "${JSON_DATA}"
}

# Prepare clone/push URLs for versions repo (robust parsing)
repo_input="${VERSIONS_REPOSITORY%.git}"
repo_input="${repo_input%/}"

# Extract host and path from VERSIONS_REPOSITORY
if [[ "${repo_input}" == http://* || "${repo_input}" == https://* ]]; then
  # strip scheme
  tmp="${repo_input#*://}"
  # strip potential creds (user[:pass]@)
  tmp="${tmp#*@}"
  host="${tmp%%/*}"
  path="${tmp#*/}"
else
  host="${GH_HOST:-github.com}"
  path="${repo_input}"
fi

# Normalize path to owner/repo
path="${path%.git}"
base_repo_url="https://${host}/${path}.git"

REPOSITORY_NAME="$( basename "${path}" )"

# Build auth URL if token provided
if [[ -n "${GITHUB_TOKEN}" ]]; then
  auth_user="${GITHUB_USERNAME:-}"  # may be empty
  if [[ -n "${auth_user}" ]]; then
    auth_url="https://${auth_user}:${GITHUB_TOKEN}@${host}/${path}.git"
  else
    auth_url="https://${GITHUB_TOKEN}@${host}/${path}.git"
  fi
else
  auth_url="${base_repo_url}"
fi

echo "Cloning versions repo: ${base_repo_url} -> ${REPOSITORY_NAME}"
git clone "${auth_url}" "${REPOSITORY_NAME}"
cd "${REPOSITORY_NAME}" || { echo "'${REPOSITORY_NAME}' dir not found"; exit 1; }
git config user.email "$( echo "${GITHUB_USERNAME}" | awk '{print tolower($0)}' )-ci@not-real.com"
git config user.name "${GITHUB_USERNAME} CI"
git remote rm origin || true
git remote add origin "${auth_url}" &> /dev/null
cd ..

if [[ "${VSCODE_PLATFORM}" == "darwin" ]]; then
  # prefer zip; fallback dmg
  ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*.zip" )
  if [[ -z "${ASSET_NAME}" ]]; then
    ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*.dmg" )
  fi
  if [[ -z "${ASSET_NAME}" ]]; then
    echo "No darwin asset found in assets/ for ${RELEASE_VERSION}"
    exit 0
  fi
  VERSION_PATH="${APP_QUALITY}/darwin/${VSCODE_ARCH}"
  updateLatestVersion

  # Also write electron autoUpdater feed under api/update for macOS
  # assetID follows VS Code: darwin (x64) or darwin-arm64 (arm64)
  assetID="darwin"
  if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
    assetID="darwin-arm64"
  fi
  API_FEED_DIR="${REPOSITORY_NAME}/api/update/${assetID}/${APP_QUALITY}"
  mkdir -p "${API_FEED_DIR}"
  # Reuse JSON_DATA generated by generateJson()
  # Ensure JSON_DATA present
  if [[ -z "${JSON_DATA}" ]]; then
    generateJson
  fi
  echo "${JSON_DATA}" > "${API_FEED_DIR}/latest.json"
  echo "${JSON_DATA}" > "${API_FEED_DIR}/${RELEASE_VERSION}.json"
  echo "Wrote macOS feed: api/update/${assetID}/${APP_QUALITY}/latest.json"
  echo "Wrote macOS feed: api/update/${assetID}/${APP_QUALITY}/${RELEASE_VERSION}.json"
elif [[ "${VSCODE_PLATFORM}" == "win32" ]]; then
  # prefer system/user setup exe; fallback zip
  # Try common naming: Setup-arch-version
  ASSET_NAME=$( pick_asset_basename "assets/*Setup*${VSCODE_ARCH}*${RELEASE_VERSION}*.exe" )
  # Try alternative order: version-Setup-arch
  if [[ -z "${ASSET_NAME}" ]]; then
    ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*Setup*${VSCODE_ARCH}*.exe" )
  fi
  # Fallback zip patterns (two orders)
  if [[ -z "${ASSET_NAME}" ]]; then
    ASSET_NAME=$( pick_asset_basename "assets/*win32*${VSCODE_ARCH}*${RELEASE_VERSION}*.zip" )
  fi
  if [[ -z "${ASSET_NAME}" ]]; then
    ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*win32*${VSCODE_ARCH}*.zip" )
  fi
  if [[ -z "${ASSET_NAME}" ]]; then
    echo "No win32 asset found in assets/ for ${RELEASE_VERSION}"
    exit 0
  fi
  VERSION_PATH="${APP_QUALITY}/win32/${VSCODE_ARCH}/archive"
  updateLatestVersion
else
  # prefer tar.gz; fallback AppImage, deb, rpm (pick one)
  ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*.tar.gz" )
  if [[ -z "${ASSET_NAME}" ]]; then
    ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*.AppImage" )
  fi
  if [[ -z "${ASSET_NAME}" ]]; then
    ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*.deb" )
  fi
  if [[ -z "${ASSET_NAME}" ]]; then
    ASSET_NAME=$( pick_asset_basename "assets/*${RELEASE_VERSION}*.rpm" )
  fi
  if [[ -z "${ASSET_NAME}" ]]; then
    echo "No linux asset found in assets/ for ${RELEASE_VERSION}"
    exit 0
  fi
  VERSION_PATH="${APP_QUALITY}/linux/${VSCODE_ARCH}"
  updateLatestVersion
fi

cd "${REPOSITORY_NAME}" || { echo "'${REPOSITORY_NAME}' dir not found"; exit 1; }
git pull origin main || true
git add .
CHANGES=$( git status --porcelain )
if [[ -n "${CHANGES}" ]]; then
  dateAndMonth=$( date "+%D %T" )
  git commit -m "CI update: ${dateAndMonth}"
  git push origin main --quiet || { git pull origin main; git push origin main --quiet; }
else
  echo "No changes"
fi
cd ..


