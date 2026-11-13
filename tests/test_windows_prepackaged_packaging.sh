#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT

mkdir -p "${test_root}/app/build" "${test_root}/signed-app" "${test_root}/bin"
echo '{"version":"3.1.1"}' > "${test_root}/app/package.json"
touch "${test_root}/app/build/stale-unsigned.exe"
touch "${test_root}/signed-app/青狮阅卷.exe"
touch "${test_root}/sign-hook.cjs"

cat > "${test_root}/bin/npx" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
expected="${PREPACKAGED_APP_DIR}"
hook="${WINDOWS_SIGN_HOOK}"
[[ "$*" == *"--no-install electron-builder --win nsis --x64 --prepackaged ${expected} --config.win.sign=${hook} --publish never"* ]]
[[ ! -f build/stale-unsigned.exe ]]
touch "build/青狮阅卷Setup-x64-3.1.1.exe"
touch "build/青狮阅卷Setup-x64-3.1.1.exe.blockmap"
MOCK
chmod +x "${test_root}/bin/npx"

run_case() {
  local case_name="$1" branch="$2" expected_installer="$3" expected_blockmap="$4"
  local case_root="${test_root}/${case_name}"
  mkdir -p "${case_root}"
  cp "${repo_root}/package_windows_prepackaged.sh" "${repo_root}/utils.sh" "${case_root}/"
  (
    cd "${case_root}"
    PATH="${test_root}/bin:${PATH}" \
      APP_DIR="${test_root}/app" \
      APP_BRANCH="${branch}" \
      VSCODE_ARCH=x64 \
      PREPACKAGED_APP_DIR="${test_root}/signed-app" \
      WINDOWS_SIGN_HOOK="${test_root}/sign-hook.cjs" \
      bash package_windows_prepackaged.sh
    test -f "assets/${expected_installer}"
    test -f "assets/${expected_blockmap}"
    test "$(find assets -maxdepth 1 -type f | wc -l | tr -d ' ')" -eq 2
  )
  rm -f "${test_root}/app/build/青狮阅卷Setup-x64-3.1.1.exe" \
    "${test_root}/app/build/青狮阅卷Setup-x64-3.1.1.exe.blockmap"
  touch "${test_root}/app/build/stale-unsigned.exe"
  echo "PASS: ${case_name}"
}

run_case master master \
  QingLionSetup-x64-3.1.1.exe \
  QingLionSetup-x64-3.1.1.exe.blockmap
run_case feature 'fix/windows signing' \
  QingLionSetup-x64-3.1.1-fix-windows-signing.exe \
  QingLionSetup-x64-3.1.1.exe-fix-windows-signing.blockmap
