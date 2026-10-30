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
