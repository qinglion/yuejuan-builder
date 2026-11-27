#!/usr/bin/env node
/**
 * Pin the desktop product and its DSH packages to the requested release version.
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
import { readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const repo = process.cwd()
const target = process.env.QINGCLAW_PRODUCT_VERSION?.trim()
if (target === undefined || target === '') throw new Error('QINGCLAW_PRODUCT_VERSION is required')
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/u.test(target)) {
  throw new Error(`QINGCLAW_PRODUCT_VERSION must be a release version without build metadata, got ${target}`)
}

const check = process.argv.includes('--check')
const { releasedManifests } = await import(pathToFileURL(join(repo, 'scripts/verify-version-sync.ts')).href)
const manifests = ['package.json', ...releasedManifests(repo)]

const changed = []
for (const path of manifests) {
  const file = join(repo, path)
  const text = await readFile(file, 'utf8')
  const manifest = JSON.parse(text)
  if (typeof manifest.version !== 'string') throw new Error(`Missing product version in ${path}`)
  if (manifest.version === target) continue
  if (check) {
    changed.push(`${path}: ${manifest.version} -> ${target}`)
    continue
  }
  manifest.version = target
  await writeFile(file, `${JSON.stringify(manifest, null, 2)}\n`)
  changed.push(path)
}

if (check) {
  if (changed.length > 0) {
    console.error('pin-product-version: these manifests still carry another version:')
    for (const path of changed) console.error(`  ${path}`)
    process.exitCode = 1
  } else {
    console.log(`pin-product-version: all product manifests carry ${target}`)
  }
} else {
  console.log(`pin-product-version: pinned ${changed.length} manifest(s) to ${target}`)
}
