#!/usr/bin/env bash

set -e

# Default app variables (can be overridden by env)
APP_NAME="${APP_NAME:-Yuejuan}"
APP_QUALITY="${APP_QUALITY:-stable}"
GITHUB_USERNAME="${GITHUB_USERNAME:-qinglion}"
ASSETS_REPOSITORY="${ASSETS_REPOSITORY:-https://github.com/qinglion/yuejuan-binaries}"
VERSIONS_REPOSITORY="${VERSIONS_REPOSITORY:-https://github.com/qinglion/yuejuan-versions}"

# Upstream app repo and source path
# APP_REPO accepts either full http(s) URL or "owner/repo" form
APP_REPO="${APP_REPO:-https://github.com/haozan/qinglion_yuejuan}"
# Preferred branch to checkout when cloning/updating the app repo
APP_BRANCH="${APP_BRANCH:-master}"
# Where the app source lives (always freshly cloned in CI unless explicitly provided)
APP_DIR="${APP_DIR:-}"

echo "---------- utils.sh -----------"
echo "APP_NAME=\"${APP_NAME}\""
echo "APP_QUALITY=\"${APP_QUALITY}\""
echo "GITHUB_USERNAME=\"${GITHUB_USERNAME}\""
echo "ASSETS_REPOSITORY=\"${ASSETS_REPOSITORY}\""
echo "VERSIONS_REPOSITORY=\"${VERSIONS_REPOSITORY}\""
echo "APP_REPO=\"${APP_REPO}\""
echo "APP_DIR=\"${APP_DIR}\""
echo "APP_BRANCH=\"${APP_BRANCH}\""

exists() { type -t "$1" &> /dev/null; }

is_gnu_sed() {
  sed --version &> /dev/null
}

replace() {
  if is_gnu_sed; then
    sed -i -E "${1}" "${2}"
  else
    sed -i '' -E "${1}" "${2}"
  fi
}

detect_os_name() {
  local un
  un="$( uname -s | tr '[:upper:]' '[:lower:]' )"
  case "${un}" in
    darwin*) echo "osx" ;;
    linux*)  echo "linux" ;;
    msys*|mingw*|cygwin*) echo "windows" ;;
    *) echo "linux" ;;
  esac
}

detect_arch() {
  local m
  m="$( uname -m )"
  case "${m}" in
    x86_64|amd64) echo "x64" ;;
    arm64|aarch64) echo "arm64" ;;
    armv7l|armv7|armhf) echo "armv7l" ;;
    i386|i686) echo "ia32" ;;
    *) echo "x64" ;;
  esac
}

read_release_version() {
  if [[ -n "${RELEASE_VERSION}" ]]; then
    echo "${RELEASE_VERSION}"
    return 0
  fi

  if [[ -f "${APP_DIR}/package.json" ]]; then
    ( cd "${APP_DIR}" && node -p "require('./package.json').version" )
    return 0
  fi

  echo "0.0.0"
}


# Ensure APP_DIR exists; if not, clone from APP_REPO
ensure_app_dir() {
  # If APP_DIR provided and exists, keep it
  if [[ -n "${APP_DIR}" && -d "${APP_DIR}" ]]; then
    return 0
  fi

  # Fallback: clone from APP_REPO into local subdir
  local repo="${APP_REPO}"
  local dest
  local clone_url
  local token
  local clone_branch_flag

  # derive dest dir from repo name
  if [[ "${repo}" == http://* || "${repo}" == https://* ]]; then
    dest="./$( basename "${repo%.git}" )"
  else
    dest="./$( basename "${repo}" )"
  fi

  # If destination already exists, reuse it (avoid clone failure)
  if [[ -d "${dest}" ]]; then
    echo "Using existing app dir: ${dest}"
    APP_DIR="${dest}"
    export APP_DIR
    # Optionally update when requested
    if [[ "${FORCE_UPDATE}" == "true" && -d "${dest}/.git" ]]; then
      echo "Updating existing repo in ${dest} (branch=${APP_BRANCH})"
      # Fetch the requested branch and tags (depth=1 for speed)
      git -C "${dest}" fetch --depth=1 origin "${APP_BRANCH}" --tags || true
      # Determine target branch: prefer APP_BRANCH; else fall back to origin/HEAD
      target_branch="${APP_BRANCH}"
      if [[ -z "${target_branch}" ]]; then
        target_branch=$( git -C "${dest}" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##' || true )
      fi
      if [[ -n "${target_branch}" ]]; then
        git -C "${dest}" checkout -q "${target_branch}" || true
        git -C "${dest}" pull --ff-only origin "${target_branch}" || true
      else
        git -C "${dest}" pull --ff-only || true
      fi
    fi
    return 0
  fi

  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  if [[ "${repo}" == http://* || "${repo}" == https://* ]]; then
    if [[ -n "${token}" ]]; then
      # https://<token>@github.com/owner/repo.git
      clone_url="https://${token}@${repo#https://}"
      clone_url="${clone_url%.git}.git"
    else
      clone_url="${repo%.git}.git"
    fi
  else
    if [[ -n "${token}" ]]; then
      clone_url="https://${token}@github.com/${repo%.git}.git"
    else
      clone_url="https://github.com/${repo%.git}.git"
    fi
  fi

  if [[ -n "${APP_BRANCH}" ]]; then
    clone_branch_flag=( -b "${APP_BRANCH}" )
  else
    clone_branch_flag=()
  fi

  echo "Cloning app repo: ${APP_REPO} -> ${dest} (branch=${APP_BRANCH})"
  git clone --depth=1 --single-branch "${clone_branch_flag[@]}" "${clone_url}" "${dest}"

  APP_DIR="${dest}"
  export APP_DIR
}



# ---------------------------------------------------------------------------
# Alibaba Cloud OSS helpers shared by Yuejuan and QingClaw.
#
# Both products upload signed installers and their update metadata with the
# same ossutil invocation: three attempts, public-read ACL, and explicit
# cache metadata. Product-specific object keys stay in the caller.
# ---------------------------------------------------------------------------

OSSUTIL_VERSION="${OSSUTIL_VERSION:-2.3.0}"
OSSUTIL_BASE_URL="${OSSUTIL_BASE_URL:-https://gosspublic.alicdn.com/ossutil/v2/${OSSUTIL_VERSION}}"

install_ossutil_for_host() {
  local os="$1" arch="$2" zip_name="$3" extract_dir="$4" binary_name="$5"

  echo "Downloading ossutil for ${os}/${arch}..."
  if ! curl -fSL --connect-timeout 30 --retry 3 "${OSSUTIL_BASE_URL}/${zip_name}" -o ossutil.zip; then
    echo "[ERROR] Failed to download ossutil from ${OSSUTIL_BASE_URL}/${zip_name}" >&2
    return 1
  fi
  if ! unzip -q ossutil.zip; then
    echo "[ERROR] Failed to unzip ossutil.zip" >&2
    rm -f ossutil.zip
    return 1
  fi
  if [[ ! -f "${extract_dir}/${binary_name}" ]]; then
    echo "[ERROR] Expected ossutil binary not found: ${extract_dir}/${binary_name}" >&2
    rm -rf ossutil.zip "${extract_dir}"
    return 1
  fi

  mkdir -p ./bin
  chmod 755 "${extract_dir}/${binary_name}" 2>/dev/null || true
  mv "${extract_dir}/${binary_name}" ./bin/
  export PATH="$(pwd)/bin:${PATH}"
  rm -rf ossutil.zip "${extract_dir}"

  if ! command -v ossutil &> /dev/null; then
    echo "[ERROR] ossutil installed to ./bin/ but not found in PATH" >&2
    return 1
  fi
  echo "ossutil installed successfully: $(ossutil --version 2>&1 || echo 'version check skipped')"
}

# Install ossutil 2.x when the host does not already provide it.
ensure_ossutil() {
  if command -v ossutil &> /dev/null; then
    return 0
  fi
  echo "Installing ossutil v${OSSUTIL_VERSION}..."
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [[ "$(uname -m)" == "x86_64" ]]; then
      install_ossutil_for_host "linux" "amd64" \
        "ossutil-${OSSUTIL_VERSION}-linux-amd64.zip" \
        "ossutil-${OSSUTIL_VERSION}-linux-amd64" "ossutil" || return 1
    else
      install_ossutil_for_host "linux" "arm64" \
        "ossutil-${OSSUTIL_VERSION}-linux-arm64.zip" \
        "ossutil-${OSSUTIL_VERSION}-linux-arm64" "ossutil" || return 1
    fi
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    local mac_arch="${VSCODE_ARCH:-$(uname -m)}"
    if [[ "${mac_arch}" == "x64" || "${mac_arch}" == "x86_64" || "${mac_arch}" == "amd64" ]]; then
      install_ossutil_for_host "mac" "amd64" \
        "ossutil-${OSSUTIL_VERSION}-mac-amd64.zip" \
        "ossutil-${OSSUTIL_VERSION}-mac-amd64" "ossutil" || return 1
    else
      install_ossutil_for_host "mac" "arm64" \
        "ossutil-${OSSUTIL_VERSION}-mac-arm64.zip" \
        "ossutil-${OSSUTIL_VERSION}-mac-arm64" "ossutil" || return 1
    fi
  elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "win32" || "$OSTYPE" == "cygwin" ]]; then
    if ! install_ossutil_for_host "windows" "amd64" \
      "ossutil-${OSSUTIL_VERSION}-windows-amd64.zip" \
      "ossutil-${OSSUTIL_VERSION}-windows-amd64" "ossutil.exe"; then
      echo "Bash download failed, trying PowerShell fallback..." >&2
      pwsh -NoProfile -Command "
        \$url = '${OSSUTIL_BASE_URL}/ossutil-${OSSUTIL_VERSION}-windows-amd64.zip'
        Invoke-WebRequest -Uri \$url -OutFile ossutil.zip -ErrorAction Stop
        Expand-Archive -Path ossutil.zip -DestinationPath . -Force
        New-Item -ItemType Directory -Force ./bin | Out-Null
        Move-Item -Force 'ossutil-${OSSUTIL_VERSION}-windows-amd64/ossutil.exe' ./bin/
        Remove-Item -Recurse -Force ossutil.zip, 'ossutil-${OSSUTIL_VERSION}-windows-amd64'
      " || { echo "[ERROR] PowerShell fallback also failed" >&2; return 1; }
      export PATH="$(pwd)/bin:${PATH}"
      command -v ossutil &> /dev/null || { echo "[ERROR] ossutil still not found after PowerShell install" >&2; return 1; }
    fi
  else
    echo "[ERROR] Unsupported OS for ossutil: ${OSTYPE}" >&2
    return 1
  fi
}

# Upload one object with public-read access and optional cache/content metadata.
# Usage: oss_upload_file <local-path> <object-key> [content-type] [cache-control]
oss_upload_file() {
  local file_path="$1" object_key="$2" content_type="${3:-}" cache_control="${4:-}"
  if [[ ! -f "${file_path}" ]]; then
    echo "[ERROR] OSS upload source missing: ${file_path}" >&2
    return 1
  fi
  if [[ -z "${OSS_ACCESS_KEY_ID:-}" || -z "${OSS_ACCESS_KEY_SECRET:-}" || -z "${OSS_BUCKET_NAME:-}" ]]; then
    echo "[ERROR] OSS credentials are required but missing." >&2
    return 1
  fi
  ensure_ossutil || return 1

  local -a metadata=()
  [[ -n "${content_type}" ]] && metadata+=(--content-type "${content_type}")
  [[ -n "${cache_control}" ]] && metadata+=(--cache-control "${cache_control}")

  local attempt
  for attempt in 1 2 3; do
    echo "Uploading ${file_path} -> oss://${OSS_BUCKET_NAME}/${object_key} (attempt ${attempt})"
    if ossutil cp "${file_path}" "oss://${OSS_BUCKET_NAME}/${object_key}" -f \
      --access-key-id "${OSS_ACCESS_KEY_ID}" \
      --access-key-secret "${OSS_ACCESS_KEY_SECRET}" \
      --endpoint "https://${OSS_ENDPOINT}" \
      --region "${OSS_REGION:-oss-cn-hangzhou}" \
      --acl public-read \
      "${metadata[@]}"; then
      return 0
    fi
    if [[ "${attempt}" -lt 3 ]]; then
      sleep 10
    fi
  done
  echo "[ERROR] Failed to upload ${file_path} after 3 attempts" >&2
  return 1
}
