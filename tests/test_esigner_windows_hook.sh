#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT

mkdir -p "${test_root}/tool/jar" "${test_root}/java/bin" "${test_root}/bin"
touch "${test_root}/tool/jar/code_sign_tool-1.3.0.jar"
touch "${test_root}/__uninstaller-nsis-com.qinglion.storm.exe"
touch "${test_root}/QingLionSetup-x64-3.1.1.exe"

cat > "${test_root}/java/bin/java.exe" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${JAVA_CALL_LOG}"
MOCK
chmod +x "${test_root}/java/bin/java.exe"

cat > "${test_root}/bin/powershell.exe" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"subject":"CN=Fixture Signer","timestampSubject":"CN=Fixture TSA"}'
MOCK
chmod +x "${test_root}/bin/powershell.exe"

cat > "${test_root}/run-hook.cjs" <<'NODE'
'use strict'

const sign = require(process.env.HOOK_PATH)

Promise.all([
  sign({ hash: 'sha256', path: process.env.UNINSTALLER_PATH }),
  sign({ hash: 'sha256', path: process.env.INSTALLER_PATH })
]).catch(error => {
  console.error(error)
  process.exitCode = 1
})
NODE

PATH="${test_root}/bin:${PATH}" \
  HOOK_PATH="${repo_root}/scripts/esigner-windows.cjs" \
  CODE_SIGN_TOOL_PATH="${test_root}/tool" \
  JAVA_HOME="${test_root}/java" \
  JAVA_CALL_LOG="${test_root}/java-calls.log" \
  ES_USERNAME=fixture-user \
  ES_PASSWORD=fixture-password \
  CREDENTIAL_ID=fixture-credential \
  ES_TOTP_SECRET=fixture-totp \
  ESIGNER_AUDIT_LOG="${test_root}/audit.jsonl" \
  UNINSTALLER_PATH="${test_root}/__uninstaller-nsis-com.qinglion.storm.exe" \
  INSTALLER_PATH="${test_root}/QingLionSetup-x64-3.1.1.exe" \
  node "${test_root}/run-hook.cjs"

test "$(wc -l < "${test_root}/java-calls.log" | tr -d ' ')" -eq 2
test "$(wc -l < "${test_root}/audit.jsonl" | tr -d ' ')" -eq 2
rg -q -- '-input_file_path=.*/__uninstaller-nsis-com.qinglion.storm.exe' "${test_root}/java-calls.log"
rg -q -- '-input_file_path=.*/QingLionSetup-x64-3.1.1.exe' "${test_root}/java-calls.log"
rg -q '__uninstaller-nsis-com.qinglion.storm.exe' "${test_root}/audit.jsonl"
rg -q 'QingLionSetup-x64-3.1.1.exe' "${test_root}/audit.jsonl"

echo 'PASS: eSigner hook serially signs and audits NSIS executables'
