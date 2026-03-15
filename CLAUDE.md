# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**yuejuan-builder** is a CI/CD build automation toolkit for packaging the Qinglion Yuejuan (青狮阅卷) Electron application across macOS, Windows, and Linux. It handles compilation, code signing, checksum generation, OSS upload, and version metadata management.

## Pipeline Scripts

The build pipeline consists of four sequential shell scripts:

| Script | Purpose |
|---|---|
| `build.sh` | Clone/update app source, inject build metadata, run `yarn build`, collect artifacts to `./assets/` |
| `prepare_checksums.sh` | Generate `.sha1` and `.sha256` files for every file in `./assets/` |
| `upload_to_oss.sh` | Upload `./assets/` to Alibaba Cloud OSS, write download URLs to `../oss_urls/` |
| `release.sh` | Clone `yuejuan-versions` repo, write `latest.json` metadata, push |

`utils.sh` is sourced by other scripts — it provides `detect_os_name()`, `detect_arch()`, `read_release_version()`, and `ensure_app_dir()`.

## Running Locally

```bash
# Set required env vars first, then run each script in order:
export APP_NAME=Yuejuan
export APP_QUALITY=insider   # or stable
export APP_BRANCH=master     # optional, defaults to master

bash build.sh
bash prepare_checksums.sh

# For OSS upload (requires credentials):
export OSS_ACCESS_KEY_ID=...
export OSS_ACCESS_KEY_SECRET=...
export OSS_BUCKET_NAME=...
export OSS_ENDPOINT=oss-cn-shanghai.aliyuncs.com
export OSS_REGION=cn-shanghai
bash upload_to_oss.sh

# For version metadata update (requires GitHub token):
export GITHUB_TOKEN=...
export GITHUB_USERNAME=qinglion
export SHOULD_BUILD=yes
bash release.sh
```

## GitHub Actions Workflows

All three workflows are triggered manually via `workflow_dispatch` with inputs:
- `quality`: `stable` or `insider`
- `branch`: git branch to build (default: `master`)

| Workflow | Runner | Code Signing |
|---|---|---|
| `build-macos.yml` | `macos-13` (x64) | P12 certificate + Apple notarization |
| `build-windows.yml` | `windows-2022` (x64) | SSL.com esigner batch signing |
| `build-linux.yml` | `ubuntu-22.04` (x64) | None |

## Key Environment Variables

```bash
# App identity
APP_NAME="Yuejuan"
APP_QUALITY="stable|insider"
APP_REPO="https://github.com/haozan/qinglion_yuejuan"
APP_BRANCH="master"
APP_DIR=""  # auto-detected; set to override

# Repositories
ASSETS_REPOSITORY="https://github.com/qinglion/yuejuan-binaries"
VERSIONS_REPOSITORY="https://github.com/qinglion/yuejuan-versions"
GITHUB_USERNAME="qinglion"

# Build flags
CI_BUILD="yes|no"
SHOULD_BUILD="yes"
FORCE_UPDATE="true|false"
VSCODE_ARCH="x64|arm64"
VSCODE_PLATFORM="darwin|win32|linux"  # set by build.sh, used by release.sh
```

## Architecture Notes

- **Artifact output**: `build.sh` collects `.dmg`, `.zip`, `.exe`, `.AppImage`, `.deb`, `.rpm` from `APP_DIR/build/` into `./assets/`. Chinese characters in filenames are replaced with ASCII (`青狮阅卷` → `QingLion`).
- **Branch suffix**: When `APP_BRANCH != master`, a suffix is appended to artifact filenames (e.g., `-feature-branch`).
- **OSS path structure**: `oss://{bucket}/{APP_NAME}/{APP_QUALITY}/{version}/{platform}/{filename}`
- **Version metadata path** in `yuejuan-versions` repo: `{quality}/{platform}/{arch}/latest.json` (Windows also has `user/` and `archive/` subdirs).
- **sqlite3 mirror**: Windows builds use `npm_config_node_sqlite3_binary_host_mirror` pointing to npmmirror.com to avoid network issues.
- **ossutil**: `upload_to_oss.sh` auto-installs `ossutil` v2.1.2 if missing; no manual installation needed.
