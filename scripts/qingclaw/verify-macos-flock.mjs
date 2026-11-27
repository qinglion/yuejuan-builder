import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { closeSync, mkdtempSync, openSync, realpathSync, rmSync } from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join, resolve, sep } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const [bundle, expectedArch = process.arch] = process.argv.slice(2)
if (!bundle) throw new Error('Usage: node verify-macos-flock.mjs <app bundle> [arm64|x64]')
const contents = realpathSync(resolve(bundle, 'Contents'))

if (!process.versions.electron) {
  const executable = execFileSync('/usr/bin/plutil', [
    '-extract', 'CFBundleExecutable', 'raw', '-o', '-', join(contents, 'Info.plist'),
  ], { encoding: 'utf8' }).trim()
  const env = { ...process.env, ELECTRON_RUN_AS_NODE: '1' }
  delete env.NODE_PATH
  delete env.NODE_OPTIONS
  execFileSync(join(contents, 'MacOS', executable), [fileURLToPath(import.meta.url), resolve(bundle), expectedArch], {
    env,
    stdio: 'inherit',
    timeout: 30_000,
  })
} else {
  assert.equal(process.arch, expectedArch, 'Unexpected packaged Electron architecture')
  const asar = join(contents, 'Resources', 'app.asar')
  const hostRequire = createRequire(join(asar, 'dsh', 'package.json'))
  const entry = hostRequire.resolve('@deepseek-ai/node-addon-system/flock')
  const manifest = createRequire(entry).resolve(`@deepseek-ai/node-addon-system-darwin-${process.arch}/package.json`)
  for (const path of [entry, manifest]) {
    assert.ok(path.startsWith(asar + sep) || path.startsWith(asar + '.unpacked' + sep), `Resolved outside bundle: ${path}`)
  }
  const { tryLockExclusive } = await import(pathToFileURL(entry).href)
  const directory = mkdtempSync(join(tmpdir(), 'qingclaw-flock-'))
  try {
    const lockFile = join(directory, 'session.lock')
    const owner = openSync(lockFile, 'wx', 0o600)
    try {
      await tryLockExclusive(owner)
      const contender = openSync(lockFile, 'r+')
      try {
        await assert.rejects(tryLockExclusive(contender), error => ['EAGAIN', 'EWOULDBLOCK'].includes(error.code))
      } finally {
        closeSync(contender)
      }
    } finally {
      closeSync(owner)
    }
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
  console.log(`Verified session flock in packaged Electron for macOS ${process.arch}`)
}
