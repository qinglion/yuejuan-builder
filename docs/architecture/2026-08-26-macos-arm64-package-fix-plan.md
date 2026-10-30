# macOS ARM64 Package Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use box:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the feat/macos-arm64-staged-build workflow produce verified x64 and native arm64 macOS packages without pushing or merging into main.

**Architecture:** Keep the existing staged pipeline: build renderer assets once on Intel/Node 14, then package independently on x64 and arm64/Node 20 runners. Preserve optional-dependency exclusion when installing the required DMG license helper so unsupported optional nodejieba is never reintroduced, and let critical install failures stop the job.

**Tech Stack:** Bash, Yarn 1, npm, Electron Builder 24, GitHub Actions, GitHub CLI, macOS lipo/codesign/spctl.

---

### Task 1: Add a regression check for package-only dependency policy

**Files:**
- Create: tests/test_macos_package_only_optional_deps.sh
- Test: tests/test_macos_package_only_optional_deps.sh

- [ ] **Step 1: Write the failing regression check**

~~~bash
#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
build_script="${repo_root}/build.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

require_literal() {
  local expected="$1"
  local message="$2"
  grep -Fq -- "${expected}" "${build_script}" || fail "${message}"
}

require_literal \
  'yarn add dmg-license --ignore-optional --network-timeout 600000' \
  'yarn dmg-license install must keep --ignore-optional'

require_literal \
  'npm install dmg-license --omit=optional --network-timeout=600000' \
  'npm dmg-license install must omit optional dependencies'

dmg_install_lines=$(grep -E '^[[:space:]]*(yarn add|npm install) dmg-license' "${build_script}")
if grep -Fq '2>/dev/null' <<<"${dmg_install_lines}" || grep -Fq '|| true' <<<"${dmg_install_lines}"; then
  fail 'dmg-license installation errors must not be suppressed'
fi

echo 'PASS: package-only dmg-license installs preserve optional dependency exclusion'
~~~

- [ ] **Step 2: Run the check and verify RED**

Run:

~~~bash
bash tests/test_macos_package_only_optional_deps.sh
~~~

Expected: exit 1 with FAIL: yarn dmg-license install must keep --ignore-optional because the current command re-enables optional dependencies.

- [ ] **Step 3: Verify the test script itself parses**

Run:

~~~bash
bash -n tests/test_macos_package_only_optional_deps.sh
~~~

Expected: exit 0 with no output.

### Task 2: Preserve optional-dependency exclusion for DMG packaging

**Files:**
- Modify: build.sh:121-136
- Test: tests/test_macos_package_only_optional_deps.sh

- [ ] **Step 1: Make the minimal Yarn and npm changes**

Replace the package-only macOS Yarn dependency block with:

~~~bash
    # dmg-license is optional to electron-builder but required for macOS .dmg packaging.
    # Keep optional deps excluded so pinyin cannot reintroduce unsupported nodejieba.
    if [[ "${BUILD_STAGE}" == "package-only" && "${OS_NAME}" == "osx" ]]; then
      yarn add dmg-license --ignore-optional --network-timeout 600000
    fi
~~~

Replace the npm fallback block with:

~~~bash
    if [[ "${BUILD_STAGE}" == "package-only" && "${OS_NAME}" == "osx" ]]; then
      npm install dmg-license --omit=optional --network-timeout=600000
    fi
~~~

- [ ] **Step 2: Run the regression check and verify GREEN**

Run:

~~~bash
bash tests/test_macos_package_only_optional_deps.sh
~~~

Expected: exit 0 with PASS: package-only dmg-license installs preserve optional dependency exclusion.

- [ ] **Step 3: Run shell syntax and whitespace checks**

Run:

~~~bash
bash -n build.sh tests/test_macos_package_only_optional_deps.sh
git diff --check
~~~

Expected: both commands exit 0 with no errors.

- [ ] **Step 4: Commit only the tested production fix**

~~~bash
git add build.sh tests/test_macos_package_only_optional_deps.sh
git commit -m "fix(build): keep optional deps excluded for dmg packaging"
~~~

Expected: a new commit on feat/macos-arm64-staged-build; main remains untouched.

### Task 3: Push only the feature branch and run GitHub Actions

**Files:**
- Verify: .github/workflows/build-macos.yml
- Verify: build.sh

- [ ] **Step 1: Enforce the branch guard before pushing**

Run:

~~~bash
test "$(git branch --show-current)" = "feat/macos-arm64-staged-build"
git status --short --branch
~~~

Expected: the assertion exits 0 and status shows feat/macos-arm64-staged-build, never main.

- [ ] **Step 2: Push explicitly to the feature branch**

Run:

~~~bash
git push origin HEAD:refs/heads/feat/macos-arm64-staged-build
~~~

Expected: only refs/heads/feat/macos-arm64-staged-build advances.

- [ ] **Step 3: Dispatch the feature-branch workflow**

Run:

~~~bash
run_url=$(gh workflow run build-macos.yml \
  --repo qinglion/yuejuan-builder \
  --ref feat/macos-arm64-staged-build \
  -f quality=insider \
  -f branch=master)
run_id=${run_url##*/}
printf 'run_id=%s\nrun_url=%s\n' "${run_id}" "${run_url}"
printf '%s\n' "${run_id}" > .git/codex-macos-run-id
~~~

Expected: a numeric run ID and a GitHub Actions URL for feat/macos-arm64-staged-build.

- [ ] **Step 4: Monitor the run to completion**

Run:

~~~bash
run_id=$(<.git/codex-macos-run-id)
gh run watch "${run_id}" --repo qinglion/yuejuan-builder --exit-status --interval 10
~~~

Expected: exit 0; Prepare renderer (Node 14), Package x64, and Package arm64 all conclude successfully. If it exits nonzero, capture the failed job log, return to systematic root-cause investigation, and revise this plan before another production change.

### Task 4: Verify the ARM64 artifact and release metadata

**Files:**
- Verify: GitHub artifact yuejuan-macos-arm64
- Verify: qinglion/yuejuan-versions path insider/darwin/arm64/latest.json

- [ ] **Step 1: Download the arm64 artifact into an isolated temporary directory**

Run:

~~~bash
run_id=$(<.git/codex-macos-run-id)
artifact_dir=$(mktemp -d /tmp/yuejuan-arm64-artifact.XXXXXX)
gh run download "${run_id}" \
  --repo qinglion/yuejuan-builder \
  --name yuejuan-macos-arm64 \
  --dir "${artifact_dir}"
find "${artifact_dir}" -maxdepth 2 -type f -print
~~~

Expected: the directory contains arm64 .zip and .dmg installers plus .sha1 and .sha256 files.

- [ ] **Step 2: Verify the ZIP checksum**

Run:

~~~bash
arm64_zip=$(find "${artifact_dir}" -maxdepth 2 -type f -name '*arm64*.zip' -print -quit)
test -n "${arm64_zip}"
expected_sha256=$(awk '{print $1}' "${arm64_zip}.sha256")
actual_sha256=$(shasum -a 256 "${arm64_zip}" | awk '{print $1}')
test "${actual_sha256}" = "${expected_sha256}"
~~~

Expected: all assertions exit 0.

- [ ] **Step 3: Verify the packaged app is native arm64 and correctly signed**

Run:

~~~bash
mkdir -p "${artifact_dir}/unpacked"
ditto -x -k "${arm64_zip}" "${artifact_dir}/unpacked"
arm64_app=$(find "${artifact_dir}/unpacked" -type d -name '*.app' -print -quit)
test -n "${arm64_app}"
bundle_executable=$(plutil -extract CFBundleExecutable raw "${arm64_app}/Contents/Info.plist")
app_binary="${arm64_app}/Contents/MacOS/${bundle_executable}"
test "$(lipo -archs "${app_binary}")" = "arm64"
while IFS= read -r native_module; do
  lipo -archs "${native_module}" | grep -qw arm64
done < <(find "${arm64_app}" -type f -name '*.node' -print)
codesign --verify --deep --strict --verbose=2 "${arm64_app}"
spctl --assess --type execute -vv "${arm64_app}"
~~~

Expected: the main executable reports only arm64; every packaged native module includes arm64; code-signature and Gatekeeper assessment exit 0.

- [ ] **Step 4: Verify arm64 update metadata and its published download URL**

Run:

~~~bash
latest_json=$(gh api \
  'repos/qinglion/yuejuan-versions/contents/insider/darwin/arm64/latest.json' \
  --jq .content | base64 --decode)
printf '%s\n' "${latest_json}" | jq -e '.url | contains("arm64")'
download_url=$(printf '%s\n' "${latest_json}" | jq -r .url)
curl -fsIL "${download_url}"
~~~

Expected: metadata URL contains arm64 and the published installer responds successfully.

### Task 5: Final branch-safety and completion audit

**Files:**
- Verify: docs/architecture/macos-arm64-build.md
- Verify: Git history and GitHub Actions result

- [ ] **Step 1: Re-run local verification from the feature branch**

Run:

~~~bash
test "$(git branch --show-current)" = "feat/macos-arm64-staged-build"
bash tests/test_macos_package_only_optional_deps.sh
bash -n build.sh tests/test_macos_package_only_optional_deps.sh
git diff --check
git status --short --branch
~~~

Expected: all checks pass and the worktree is clean on feat/macos-arm64-staged-build.

- [ ] **Step 2: Confirm authoritative CI conclusions**

Run:

~~~bash
run_id=$(<.git/codex-macos-run-id)
gh run view "${run_id}" \
  --repo qinglion/yuejuan-builder \
  --json headBranch,headSha,status,conclusion,jobs,url
~~~

Expected: headBranch is feat/macos-arm64-staged-build, overall conclusion is success, and all three jobs are successful.

- [ ] **Step 3: Confirm the remote feature branch contains the fix without updating main**

Run:

~~~bash
git fetch origin main feat/macos-arm64-staged-build
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/feat/macos-arm64-staged-build)"
git log --oneline origin/main..origin/feat/macos-arm64-staged-build
~~~

Expected: local HEAD equals the remote feature branch and the fix commits are listed only in the feature-branch range.
