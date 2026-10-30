#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin"

# Isolate all repository operations; the real release script writes its JSON locally.
cat > "${test_root}/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == clone ]]; then mkdir -p "$3"; fi
MOCK
chmod +x "${test_root}/bin/git"

run_case() {
  local case_name="$1" arch="$2" branch="$3" expected="$4"
  shift 4
  local case_dir="${test_root}/${case_name}"
  mkdir -p "${case_dir}/assets" "${case_dir}/app"
  cp "${repo_root}/release.sh" "${repo_root}/utils.sh" "${case_dir}/"
  echo '{"version":"3.0.40"}' > "${case_dir}/app/package.json"
  local asset
  for asset in "$@"; do
    touch "${case_dir}/assets/${asset}"
    echo 'test-sha1' > "${case_dir}/assets/${asset}.sha1"
    echo 'test-sha256' > "${case_dir}/assets/${asset}.sha256"
  done
  (
    cd "${case_dir}"
    local result=0
    env -i PATH="${test_root}/bin:${PATH}" HOME="${HOME}" \
      APP_DIR="${case_dir}/app" APP_BRANCH="${branch}" SHOULD_BUILD=yes \
      GITHUB_TOKEN=fixture BUILD_SOURCEVERSION=fixture VSCODE_PLATFORM=darwin \
      VSCODE_ARCH="${arch}" PUBLIC_DOWNLOAD_DOMAIN=downloads.example.test \
      VERSIONS_REPOSITORY=https://example.test/owner/versions-fixture \
      bash release.sh > release.log 2>&1 || result=$?
    local manifest="versions-fixture/stable/darwin/${arch}/latest.json"
    if [[ "${expected}" == FAIL ]]; then
      [[ "${result}" -ne 0 && ! -f "${manifest}" ]] || { cat release.log; exit 1; }
    else
      [[ "${result}" -eq 0 ]] || { cat release.log; exit 1; }
      jq -e --arg expected "${expected}" \
        '.url == ("https://downloads.example.test/Yuejuan/stable/3.0.40/darwin/" + $expected) and .hash == "test-sha1" and .sha256hash == "test-sha256"' \
        "${manifest}" > /dev/null
    fi
  )
  echo "PASS: ${case_name}"
}

run_case mixed-arm64 arm64 master QingLion-3.0.40-arm64.zip \
  QingLion-3.0.40-x64.zip QingLion-3.0.40-arm64.zip
run_case mixed-x64 x64 master QingLion-3.0.40-x64.zip \
  QingLion-3.0.40-arm64.zip QingLion-3.0.40-x64.zip
run_case wrong-arch arm64 master FAIL QingLion-3.0.40-x64.zip
run_case dmg-only arm64 master FAIL QingLion-3.0.40-arm64.dmg
run_case version-prefix arm64 master FAIL QingLion-3.0.400-arm64.zip
run_case branch-x64 x64 fix/arm64-updater QingLion-3.0.40-x64-fix-arm64-updater.zip \
  QingLion-3.0.40-arm64-fix-arm64-updater.zip QingLion-3.0.40-x64-fix-arm64-updater.zip
