#!/usr/bin/env bash
set -euo pipefail

workflow='.github/workflows/build-qingclaw-macos.yml'
config='scripts/qingclaw/write-packaging-config.mjs'
uploader='scripts/qingclaw/upload-desktop.sh'

grep -Fq 'repository: qinglion/qingclaw-dsh' "${workflow}"
grep -Fq "node-version: '24.9.0'" "${workflow}"
grep -Fq 'pnpm@11.28.5' "${workflow}"
grep -Fq 'package:desktop:mac:' "${workflow}"
grep -Fq 'scripts/qingclaw/upload-desktop.sh' "${workflow}"
grep -Fq 'QINGCLAW_QUALITY' "${workflow}"
grep -Fq 'persist-credentials: false' "${workflow}"
grep -Fq 'git merge-base --is-ancestor HEAD "origin/${trusted_ref}"' "${workflow}"
grep -Fq 'Production releases must use the stable updater channel' "${workflow}"
grep -Fq "trusted_ref='release'" "${workflow}"
grep -Fq 'Production releases must build the release branch or a dsh-v* tag' "${workflow}"
grep -Fq 'qingclaw-build-${{ inputs.version }}-${{ matrix.target }}' "${workflow}"
grep -Fq "vars.QINGCLAW_TEST_RELEASE_ID" "${workflow}"
grep -Fq 'https://d.qinglion.com' "${config}"
if [[ "$(grep -Fc 'upload-desktop.sh' "${workflow}")" -ne 1 ]]; then
  echo 'the package job must upload each architecture exactly once' >&2
  exit 1
fi
if grep -Fq 'publish:desktop:builder:release' "${workflow}"; then
  echo 'the Linux aggregate publisher must not be part of the macOS workflow' >&2
  exit 1
fi
if grep -Fq "printf '%s' '\${{ inputs.version }}'" "${workflow}"; then
  echo 'workflow_dispatch version input must not be embedded in shell source' >&2
  exit 1
fi
if grep -Fq 'download.qingclaw.com' "${workflow}" "${config}" "${uploader}"; then
  echo 'legacy QingClaw download origin is not allowed' >&2
  exit 1
fi
if grep -Fq 'OSS_ACCESS_KEY_SECRET=${OSS_ACCESS_KEY_SECRET:0:' upload_to_oss.sh; then
  echo 'legacy uploader still logs an OSS secret prefix' >&2
  exit 1
fi

config_root="$(mktemp -d)"
trap 'rm -rf -- "${config_root}"' EXIT
QINGCLAW_CONFIG_DIR="${config_root}" \
QINGCLAW_DEPLOYMENT=test \
QINGCLAW_TEST_RELEASE_ID=0123456789abcdef0123456789abcdef \
QINGCLAW_PUBLISH_ONLY=1 \
node "${config}" >/dev/null
test -f "${config_root}/presets/test.env"
test ! -e "${config_root}/secrets"
test ! -e "${config_root}/certificates"
node --input-type=module -e '
  import { readFile } from "node:fs/promises"
  import { parseEnv } from "node:util"
  const values = parseEnv(await readFile(process.argv[1], "utf8"))
  if (values.DSH_DESKTOP_UPDATE_ROOT !== "qingclaw/beta/desktop") {
    throw new Error("test preset did not set the shared update root")
  }
  const policy = JSON.parse(values.DSH_DESKTOP_MANDATORY_UPDATE_CONFIG)
  if (policy.allowedAuthOrigins?.[0] !== "https://beta.qingclaw.com") {
    throw new Error("test policy did not round-trip through node:util.parseEnv")
  }
' "${config_root}/presets/test.env"

signing_root="$(mktemp -d)"
trap 'rm -rf -- "${config_root}" "${signing_root}"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes \
  -subj '/CN=Developer ID Application: Example Co., Ltd. (ABCDEFGHIJ)' \
  -keyout "${signing_root}/key.pem" -out "${signing_root}/cert.pem" -days 1 >/dev/null 2>&1
openssl pkcs12 -export -out "${signing_root}/developer-id.p12" \
  -inkey "${signing_root}/key.pem" -in "${signing_root}/cert.pem" \
  -passout 'pass:test-pass#1' >/dev/null 2>&1
certificate_data="$(base64 < "${signing_root}/developer-id.p12" | tr -d '\n')"
QINGCLAW_CONFIG_DIR="${signing_root}/config" \
QINGCLAW_DEPLOYMENT=production \
CERTIFICATE_OSX_P12_DATA="${certificate_data}" \
CERTIFICATE_OSX_P12_PASSWORD='test-pass#1' \
CERTIFICATE_OSX_ID='builder@example.com' \
CERTIFICATE_OSX_APP_PASSWORD='app-password' \
CERTIFICATE_OSX_TEAM_ID=ABCDEFGHIJ \
node "${config}" >/dev/null
node --input-type=module -e '
  import { readFile } from "node:fs/promises"
  import { parseEnv } from "node:util"
  const preset = parseEnv(await readFile(process.argv[1], "utf8"))
  if (preset.DSH_DESKTOP_UPDATE_ROOT !== "qingclaw/stable/desktop") {
    throw new Error("production preset did not set the shared update root")
  }
  const secrets = parseEnv(await readFile(process.argv[2], "utf8"))
  if (secrets.DSH_DESKTOP_MACOS_SIGNING_IDENTITY !== "Example Co., Ltd. (ABCDEFGHIJ)") {
    throw new Error("Developer ID common name punctuation did not round-trip")
  }
  if (secrets.CSC_KEY_PASSWORD !== "test-pass#1") {
    throw new Error("signing password punctuation did not round-trip")
  }
' "${signing_root}/config/presets/production.env" "${signing_root}/config/secrets/macos-signing.env"

# Computer Use helpers must be built from the QingClaw checkout and staged before
# the desktop package build, using the private QingClaw signing configuration.
grep -Fq 'scripts/cua-helper/package.ts --out dist/cua-helper' "${workflow}"
grep -Fq 'scripts/cua-helper/stage.ts --from dist/cua-helper/extracted' "${workflow}"
if ! awk '/name: Build and stage notarized Computer Use helpers/,/name: Package, sign, and notarize/' "${workflow}" | grep -Fq 'DSH_PACKAGING_CONFIG_DIR'; then
  echo 'the helper build must use the private QingClaw packaging configuration' >&2
  exit 1
fi
helper_line="$(grep -n 'stage.ts --from' "${workflow}" | head -1 | cut -d: -f1)"
package_line="$(grep -n 'package:desktop:mac:' "${workflow}" | head -1 | cut -d: -f1)"
if [[ "${helper_line}" -ge "${package_line}" ]]; then
  echo 'the notarized helper must be staged before the signed macOS package build' >&2
  exit 1
fi
patch='scripts/qingclaw/patches/dsh-packaging.patch'
if ! grep -Fq '+    <string>com.qinglion.qingclaw.computer-use</string>' "${patch}"; then
  echo 'the packaging patch must rebrand the Computer Use helper bundle identifier' >&2
  exit 1
fi
if ! grep -Fq 'access: AXAccess, element: AXUIElement' "${patch}"; then
  echo 'the packaging patch must carry the Swift 6.1/6.2 actor-closure compile fix' >&2
  exit 1
fi
if ! grep -Fq "join(application, 'Contents/MacOS/dsh-cua-native'), '-verify_arch'" "${patch}"; then
  echo 'the packaging patch must use the input-first lipo argument order' >&2
  exit 1
fi
if grep -Fq 'select-artifact.ts' "${workflow}"; then
  echo 'the QingClaw workflow must not reuse official DeepSeek helper artifacts' >&2
  exit 1
fi
windows_workflow='.github/workflows/build-qingclaw-windows.yml'
grep -Fq 'dotnet publish' "${windows_workflow}"
grep -Fq 'native/bin/win-x64' "${windows_workflow}"
win_helper_line="$(grep -n 'native/bin/win-x64' "${windows_workflow}" | head -1 | cut -d: -f1)"
win_package_line="$(grep -n 'package:win:x64:dir' "${windows_workflow}" | head -1 | cut -d: -f1)"
if [[ "${win_helper_line}" -ge "${win_package_line}" ]]; then
  echo 'the Windows helper must be staged before the unsigned win-unpacked build' >&2
  exit 1
fi
