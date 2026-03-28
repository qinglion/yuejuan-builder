#!/usr/bin/env bash
# Build script for Tuomisi (脱敏大师) — Windows/macOS packaging
# Intended to be run from the yuejuan-builder root directory.
# shellcheck disable=SC1091

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Set APP_NAME before sourcing utils.sh so its default (Yuejuan) is not applied
export APP_NAME="${APP_NAME:-Tuomisi}"

# Point APP_REPO to the tuomisi repo; ensure_app_dir() in utils.sh will use this
export APP_REPO="${TUOMISI_REPO:-${APP_REPO:-}}"

# Source shared utilities (detect_os_name, detect_arch, ensure_app_dir, etc.)
source "$SCRIPT_DIR/utils.sh"

APP_QUALITY="${APP_QUALITY:-stable}"
APP_BRANCH="${APP_BRANCH:-master}"

OS_NAME="${OS_NAME:-$( detect_os_name )}"
VSCODE_ARCH="${VSCODE_ARCH:-$( detect_arch )}"

echo "---------- build-tuomisi.sh -----------"
echo "OS_NAME=$OS_NAME / VSCODE_ARCH=$VSCODE_ARCH"
echo "APP_BRANCH=$APP_BRANCH"

# Clone or update the tuomisi source repo
ensure_app_dir

cd "$APP_DIR"

# ── macOS code signing setup ───────────────────────────────────────────────────
if [ "$OS_NAME" = "osx" ] && [ -n "${CERTIFICATE_OSX_P12_DATA:-}" ]; then
  echo "--- macOS: setting up code signing ---"
  CERT_TMP="$(mktemp /tmp/tuomisi-cert.XXXXXX.p12)"
  echo "$CERTIFICATE_OSX_P12_DATA" | base64 --decode > "$CERT_TMP"
  export CSC_LINK="$CERT_TMP"
  export CSC_KEY_PASSWORD="${CERTIFICATE_OSX_P12_PASSWORD:-}"
  # Notarization credentials (electron-builder reads these directly)
  export APPLE_ID="${APPLE_ID:-}"
  export APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-}"
  export APPLE_TEAM_ID="${APPLE_TEAM_ID:-}"
fi

# ── 1. Build Python engine with PyInstaller (onedir mode) ──────────────────────
echo "--- PyInstaller: installing deps ---"
pip install --quiet --upgrade pyinstaller lxml mammoth

echo "--- PyInstaller: building engine ---"
# Outputs to dist/engine/ (onedir), matching electron-builder.yml extraResources
pyinstaller engine.spec --distpath dist --noconfirm

# ── 2. Install Node.js dependencies ───────────────────────────────────────────
echo "--- npm install ---"
npm install

# ── 3. Build Electron app for the target platform ─────────────────────────────
echo "--- Electron build ($OS_NAME) ---"
case "$OS_NAME" in
  osx)     npm run build:mac ;;
  windows) npm run build:win ;;
  *)       echo "[ERROR] Unsupported OS: $OS_NAME"; exit 1 ;;
esac

# ── 4. Collect artifacts ───────────────────────────────────────────────────────
echo "--- Collecting artifacts ---"
mkdir -p "$SCRIPT_DIR/assets"

find dist -maxdepth 1 -type f \( -name "*.exe" -o -name "*.zip" -o -name "*.dmg" \) | while IFS= read -r f; do
  echo "  -> $f"
  cp "$f" "$SCRIPT_DIR/assets/"
done

# ── 5. Export version and platform for downstream scripts ─────────────────────
RELEASE_VERSION="$( node -p "require('./package.json').version" )"
export RELEASE_VERSION
export APP_DIR

case "$OS_NAME" in
  osx)     VSCODE_PLATFORM=darwin ;;
  windows) VSCODE_PLATFORM=win32 ;;
  *)       VSCODE_PLATFORM=linux ;;
esac
export VSCODE_PLATFORM

# Propagate to subsequent GitHub Actions steps
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "RELEASE_VERSION=$RELEASE_VERSION" >> "$GITHUB_ENV"
  echo "APP_DIR=$APP_DIR"                 >> "$GITHUB_ENV"
  echo "VSCODE_PLATFORM=$VSCODE_PLATFORM" >> "$GITHUB_ENV"
fi

echo "--- Build complete ---"
echo "RELEASE_VERSION=$RELEASE_VERSION | VSCODE_PLATFORM=$VSCODE_PLATFORM"
ls -la "$SCRIPT_DIR/assets/"
