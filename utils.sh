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


