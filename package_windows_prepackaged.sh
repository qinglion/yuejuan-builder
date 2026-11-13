#!/usr/bin/env bash

set -euo pipefail

. ./utils.sh

VSCODE_ARCH="${VSCODE_ARCH:-$( detect_arch )}"
PREPACKAGED_APP_DIR="${PREPACKAGED_APP_DIR:-}"
WINDOWS_SIGN_HOOK="${WINDOWS_SIGN_HOOK:-}"

to_bash_path() {
  local value="$1"
  if command -v cygpath >/dev/null 2>&1 && [[ "${value}" =~ ^[A-Za-z]:[\\/].* ]]; then
    cygpath -u "${value}"
  else
    echo "${value}"
  fi
}

# GitHub exposes github.workspace as a native D:\ path, while this script runs
# under Git Bash. Normalize before using Bash filesystem operators.
APP_DIR="$( to_bash_path "${APP_DIR:-}" )"
PREPACKAGED_APP_DIR="$( to_bash_path "${PREPACKAGED_APP_DIR}" )"
WINDOWS_SIGN_HOOK="$( to_bash_path "${WINDOWS_SIGN_HOOK}" )"
export APP_DIR PREPACKAGED_APP_DIR WINDOWS_SIGN_HOOK

if [[ -z "${PREPACKAGED_APP_DIR}" || ! -d "${PREPACKAGED_APP_DIR}" ]]; then
  echo "[ERROR] PREPACKAGED_APP_DIR must point to the signed win-unpacked directory"
  exit 1
fi

if [[ -z "${WINDOWS_SIGN_HOOK}" || ! -f "${WINDOWS_SIGN_HOOK}" ]]; then
  echo "[ERROR] WINDOWS_SIGN_HOOK must point to the electron-builder signing hook"
  exit 1
fi

PREPACKAGED_APP_DIR="$( cd "${PREPACKAGED_APP_DIR}" && pwd )"
WINDOWS_SIGN_HOOK="$( cd "$( dirname "${WINDOWS_SIGN_HOOK}" )" && pwd )/$( basename "${WINDOWS_SIGN_HOOK}" )"
ensure_app_dir

if [[ ! -f "${APP_DIR}/package.json" ]]; then
  echo "[ERROR] App package.json not found in ${APP_DIR}"
  exit 1
fi

# Never allow the unsigned installer emitted by the first build to be reused.
find "${APP_DIR}/build" -maxdepth 1 -type f \
  \( -name '*.exe' -o -name '*.msi' -o -name '*.blockmap' \) -delete

pushd "${APP_DIR}" >/dev/null
electron_prepackaged_dir="${PREPACKAGED_APP_DIR}"
electron_sign_hook="${WINDOWS_SIGN_HOOK}"
if command -v cygpath >/dev/null 2>&1; then
  electron_prepackaged_dir="$( cygpath -w "${PREPACKAGED_APP_DIR}" )"
  electron_sign_hook="$( cygpath -w "${WINDOWS_SIGN_HOOK}" )"
fi
npx --no-install electron-builder \
  --win nsis \
  --"${VSCODE_ARCH}" \
  --prepackaged "${electron_prepackaged_dir}" \
  --config.win.sign="${electron_sign_hook}"
popd >/dev/null

rm -rf assets
mkdir -p assets

shopt -s nullglob
installers=( "${APP_DIR}/build"/*.exe "${APP_DIR}/build"/*.msi )
blockmaps=( "${APP_DIR}/build"/*.blockmap )
shopt -u nullglob

if [[ "${#installers[@]}" -eq 0 ]]; then
  echo "[ERROR] No Windows installer was produced from the signed application"
  exit 1
fi

safe_branch="${APP_BRANCH:-}"
if [[ -n "${safe_branch}" && "${safe_branch}" != "master" ]]; then
  safe_branch=$( echo "${safe_branch}" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' )
else
  safe_branch=""
fi

copy_asset() {
  local source="$1"
  local name extension stem
  name="$( basename "${source}" )"
  name="${name//青狮阅卷/QingLion}"

  if [[ -n "${safe_branch}" ]]; then
    if [[ "${name}" == *.blockmap ]]; then
      extension=".blockmap"
      stem="${name%.blockmap}"
    else
      extension=".${name##*.}"
      stem="${name%.*}"
    fi
    name="${stem}-${safe_branch}${extension}"
  fi

  cp -f "${source}" "assets/${name}"
}

for artifact in "${installers[@]}" "${blockmaps[@]}"; do
  copy_asset "${artifact}"
done

echo "Packaged signed Windows application into ${#installers[@]} installer(s)."
