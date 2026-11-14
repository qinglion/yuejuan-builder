#!/usr/bin/env bash
set -euo pipefail

workflow='.github/workflows/build-qingclaw-macos.yml'
config='scripts/qingclaw/write-packaging-config.mjs'

grep -Fq 'repository: qinglion/qingclaw-dsh' "${workflow}"
grep -Fq "node-version: '24.9.0'" "${workflow}"
grep -Fq 'pnpm@11.28.5' "${workflow}"
grep -Fq 'package:desktop:mac:' "${workflow}"
grep -Fq 'publish:desktop:builder:release -- mac-arm64 mac-x64 --with-latest' "${workflow}"
grep -Fq 'persist-credentials: ${{ inputs.deployment == '\''production'\'' }}' "${workflow}"
grep -Fq 'git merge-base --is-ancestor HEAD "origin/${trusted_ref}"' "${workflow}"
grep -Fq 'needs: [request, package]' "${workflow}"
grep -Fq 'Production releases must use the stable updater channel' "${workflow}"
grep -Fq 'qingclaw-build-${{ inputs.version }}-mac-arm64' "${workflow}"
grep -Fq 'qingclaw-build-${{ inputs.version }}-mac-x64' "${workflow}"
grep -Fq "QINGCLAW_PUBLISH_ONLY: '1'" "${workflow}"
grep -Fq 'group: qingclaw-publish-${{ inputs.deployment }}-${{ inputs.channel }}' "${workflow}"
grep -Fq 'vars.QINGCLAW_TEST_RELEASE_ID' "${workflow}"
grep -Fq "vars.QINGCLAW_OSS_REGION || 'oss-cn-hangzhou'" "${workflow}"
grep -Fq 'https://d.qinglion.com' "${config}"
if [[ "$(grep -Fc 'pnpm run publish:desktop:builder:release' "${workflow}")" -ne 1 ]]; then
  echo 'aggregate publication must run exactly once after both macOS targets complete' >&2
  exit 1
fi
if grep -Fq "printf '%s' '\${{ inputs.version }}'" "${workflow}"; then
  echo 'workflow_dispatch version input must not be embedded in shell source' >&2
  exit 1
fi
if grep -Fq 'download.qingclaw.com' "${workflow}" "${config}"; then
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
  const policy = JSON.parse(values.DSH_DESKTOP_MANDATORY_UPDATE_CONFIG)
  if (policy.allowedAuthOrigins?.[0] !== "https://beta.qingclaw.com") {
    throw new Error("test policy did not round-trip through node:util.parseEnv")
  }
' "${config_root}/presets/test.env"
