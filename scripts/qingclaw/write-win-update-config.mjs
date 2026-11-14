#!/usr/bin/env node
/** Write the updater feed configuration the unsigned DSH Windows build omits. */
import { mkdir, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const unpacked = process.env.QINGCLAW_WIN_UNPACKED
const updateUrl = process.env.QINGCLAW_WIN_UPDATE_URL
const channel = process.env.QINGCLAW_CHANNEL || 'nightly'
if (!unpacked || !updateUrl) throw new Error('QINGCLAW_WIN_UNPACKED and QINGCLAW_WIN_UPDATE_URL are required')
if (!['nightly', 'stable'].includes(channel)) throw new Error('QINGCLAW_CHANNEL must be nightly or stable')

const resources = join(unpacked, 'resources')
await mkdir(resources, { recursive: true })
await writeFile(join(resources, 'app-update.yml'), [
  'provider: generic',
  `url: ${updateUrl}`,
  `channel: ${channel}`,
  'updaterCacheDirName: qingclaw-updater',
  '',
].join('\n'))
process.stdout.write(`Wrote ${join(resources, 'app-update.yml')}\n`)
