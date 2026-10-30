#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin" "${test_root}/renderer/dist/electron" "${test_root}/renderer/static"

# Exercise the real staging/build script without installing dependencies or signing.
for tool in python3 npm yarn; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "${test_root}/bin/${tool}"
done
cat > "${test_root}/bin/npx" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "electron-builder --mac --${VSCODE_ARCH}" ]]
mkdir -p build
cp package.json "build/QingLion-${RELEASE_VERSION}-${VSCODE_ARCH}.zip"
MOCK
chmod +x "${test_root}/bin/"*

for quality in stable insider; do
  cat > "${test_root}/renderer/package.json" <<JSON
{"version":"3.0.40","product":{"quality":"${quality}","arch":"x64"},"build":{"productName":"青狮阅卷"},"devDependencies":{"node-sass":"^4.0.0"}}
JSON
  tar -czf "${test_root}/renderer.tar.gz" -C "${test_root}/renderer" package.json dist/electron static
  for arch in arm64 x64; do
    case_dir="${test_root}/${quality}-${arch}"
    mkdir -p "${case_dir}/app"
    cp "${repo_root}/build.sh" "${repo_root}/utils.sh" "${case_dir}/"
    cp "${test_root}/renderer/package.json" "${case_dir}/app/"
    (
      cd "${case_dir}"
      env -i PATH="${test_root}/bin:${PATH}" HOME="${HOME}" \
        APP_DIR="${case_dir}/app" OS_NAME=osx VSCODE_ARCH="${arch}" \
        APP_QUALITY="${quality}" BUILD_STAGE=package-only \
        RENDERER_DIST_TARBALL="${test_root}/renderer.tar.gz" \
        bash build.sh > build.log 2>&1
      node - "assets/QingLion-3.0.40-${arch}.zip" "${arch}" "${quality}" <<'JS'
const assert = require('assert')
const fs = require('fs')
const [asset, arch, quality] = process.argv.slice(2)
const pkg = JSON.parse(fs.readFileSync(asset, 'utf8'))
assert.strictEqual(pkg.product.arch, arch, 'packaging must use target arch after tar extraction')
assert.strictEqual(pkg.product.quality, quality)
assert.strictEqual(pkg.build.productName, quality === 'insider' ? '青狮阅卷Beta' : '青狮阅卷')
assert.ok(!pkg.devDependencies['node-sass'])
JS
    )
    echo "PASS: ${quality}/${arch} packaging metadata"
  done
done
