#!/usr/bin/env node
/**
 * Pin every manifest to the product version this build publishes.
 *
 * The checkout is throwaway: the pinned version reaches electron-builder, the
 * update feed and the upload validation, and never returns to the repository.
 * Upstream keeps its own version line, so a sync never conflicts on these lines.
 *
 * QINGCLAW_PRODUCT_VERSION must be the release the build carries, for example
 * 2.0.0. The build version passed to packaging extends it, for example
 * 2.0.0-test.20260801.1.
 *
 * @module scripts/qingclaw/pin-product-version
 */
import { execFileSync } from 'node:child_process'
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const repo = process.cwd()
const target = process.env.QINGCLAW_PRODUCT_VERSION?.trim()
if (target === undefined || target === '') throw new Error('QINGCLAW_PRODUCT_VERSION is required')
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(target)) {
  throw new Error(`QINGCLAW_PRODUCT_VERSION must be a release version without build metadata, got ${target}`)
}

const check = process.argv.includes('--check')
const manifests = execFileSync('git', ['ls-files', '*package.json'], { cwd: repo, encoding: 'utf8' })
  .split('\n')
  .filter(path => path !== '' && !path.includes('node_modules/'))

const changed = []
for (const path of manifests) {
  const file = join(repo, path)
  const text = await readFile(file, 'utf8')
  const field = /"version"\s*:\s*"([^"]*)"/u.exec(text)
  if (field === null || field[1] === target) continue
  if (check) {
    changed.push(`${path}: ${field[1]} -> ${target}`)
    continue
  }
  // Replace the value only, so formatting and key order stay as the repository wrote them.
  await writeFile(file, text.replace(field[0], `"version": "${target}"`))
  changed.push(path)
}

if (check) {
  if (changed.length > 0) {
    console.error('pin-product-version: these manifests still carry another version:')
    for (const path of changed) console.error(`  ${path}`)
    process.exitCode = 1
  } else {
    console.log(`pin-product-version: every manifest carries ${target}`)
  }
} else {
  console.log(`pin-product-version: pinned ${changed.length} manifest(s) to ${target}`)
}
