#!/usr/bin/env node
import { mkdir, writeFile } from 'node:fs/promises'
import { isAbsolute, join } from 'node:path'
import { execFileSync } from 'node:child_process'
import { X509Certificate } from 'node:crypto'

function required(name) {
  const value = process.env[name]?.trim()
  if (!value) throw new Error(`${name} is required`)
  return value
}

function line(name, value) {
  if (value.includes('\0')) throw new Error(`${name} cannot contain a NUL byte`)
  // node:util.parseEnv does not interpret JavaScript-style \" escapes inside a
  // double-quoted dotenv value. Prefer an unquoted value whenever it is exact;
  // this is also the only lossless representation for our JSON policy value.
  if (!/[\r\n#]/u.test(value) && value.trim() === value) return `${name}=${value}`
  if (!value.includes("'")) return `${name}='${value}'`
  if (!value.includes('"')) return `${name}="${value}"`
  throw new Error(`${name} cannot be represented safely in a dotenv file`)
}

const root = required('QINGCLAW_CONFIG_DIR')
if (!isAbsolute(root)) throw new Error('QINGCLAW_CONFIG_DIR must be absolute')
const deployment = required('QINGCLAW_DEPLOYMENT')
if (deployment !== 'test' && deployment !== 'production') throw new Error('QINGCLAW_DEPLOYMENT must be test or production')
const publishOnlyValue = process.env.QINGCLAW_PUBLISH_ONLY?.trim()
if (publishOnlyValue !== undefined && publishOnlyValue !== '' && publishOnlyValue !== '1') {
  throw new Error('QINGCLAW_PUBLISH_ONLY must be 1 when set')
}
const publishOnly = publishOnlyValue === '1'
const releaseId = process.env.QINGCLAW_TEST_RELEASE_ID?.trim() ?? ''
if (deployment === 'test' && !/^[a-f0-9]{32}$/u.test(releaseId)) {
  throw new Error('QINGCLAW_TEST_RELEASE_ID must contain 32 lowercase hexadecimal characters')
}

const presets = join(root, 'presets')
const secrets = join(root, 'secrets')
const certificates = join(root, 'certificates')
await mkdir(presets, { recursive: true, mode: 0o700 })

const common = [
  line('DSH_DESKTOP_APP_ID', deployment === 'test' ? 'com.qinglion.qingclaw.test' : 'com.qinglion.qingclaw'),
  line('DSH_DESKTOP_AUTO_UPDATE_ENV', deployment),
  line(deployment === 'test' ? 'DOWNLOAD_TEST_ORIGIN' : 'DOWNLOAD_PROD_ORIGIN', 'https://d.qinglion.com'),
  line('DSH_DESKTOP_MACOS_PACK_CONCURRENCY', '4'),
  line('DSH_DESKTOP_MACOS_ZIP_COMPRESSION_LEVEL', '3'),
  line('DSH_DESKTOP_MACOS_DOWNLOAD_PROXY', ''),
  line('DSH_DESKTOP_MACOS_NOTARIZATION_PROXY', ''),
]
const preset = deployment === 'test'
  ? [...common,
      line('DOWNLOAD_TEST_RELEASE_ID', releaseId),
      line('DSH_DESKTOP_MANDATORY_UPDATE_TEST_ORIGIN', 'https://beta.qingclaw.com'),
      line('DSH_DESKTOP_MANDATORY_UPDATE_CONFIG', JSON.stringify({ allowedAuthOrigins: ['https://beta.qingclaw.com'] }))]
  : [...common, line('DSH_DESKTOP_MANDATORY_UPDATE_PROD_ORIGIN', 'https://qingclaw.com')]

await writeFile(join(presets, `${deployment}.env`), `${preset.join('\n')}\n`, { mode: 0o600 })
if (!publishOnly) {
  const certificate = Buffer.from(required('CERTIFICATE_OSX_P12_DATA'), 'base64')
  if (certificate.length === 0) throw new Error('CERTIFICATE_OSX_P12_DATA decoded to an empty certificate')
  const teamId = required('CERTIFICATE_OSX_TEAM_ID')
  if (!/^[A-Z0-9]{10}$/u.test(teamId)) throw new Error('CERTIFICATE_OSX_TEAM_ID must contain 10 uppercase letters or digits')
  await Promise.all([secrets, certificates].map(path => mkdir(path, { recursive: true, mode: 0o700 })))
  const certificatePath = join(certificates, 'developer-id.p12')
  await writeFile(certificatePath, certificate, { mode: 0o600 })

  let signingIdentity = process.env.QINGCLAW_MACOS_SIGNING_IDENTITY?.trim()
  if (!signingIdentity) {
    let pem
    try {
      pem = execFileSync('/usr/bin/openssl', ['pkcs12', '-in', certificatePath, '-clcerts', '-nokeys',
        '-passin', 'env:CERTIFICATE_OSX_P12_PASSWORD'], { encoding: 'utf8', env: process.env, stdio: ['ignore', 'pipe', 'ignore'] })
    } catch {
      throw new Error('cannot read the Developer ID certificate from CERTIFICATE_OSX_P12_DATA')
    }
    const certificatePem = pem.match(/-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----/u)?.[0]
    if (!certificatePem) throw new Error('the P12 does not contain a readable signing certificate')
    const commonName = new X509Certificate(certificatePem).subject.split('\n')
      .find(value => value.startsWith('CN=Developer ID Application: '))
    signingIdentity = commonName?.slice('CN=Developer ID Application: '.length)
    if (!signingIdentity) throw new Error('the P12 does not contain a Developer ID Application certificate')
  }
  if (!signingIdentity.endsWith(`(${teamId})`)) {
    throw new Error('Developer ID signing identity does not match CERTIFICATE_OSX_TEAM_ID')
  }

  const signing = [
    line('DSH_DESKTOP_MACOS_SIGNING_IDENTITY', signingIdentity),
    line('DSH_DESKTOP_MACOS_TEAM_ID', teamId),
    line('CSC_LINK', '../certificates/developer-id.p12'),
    line('CSC_KEY_PASSWORD', required('CERTIFICATE_OSX_P12_PASSWORD')),
    line('APPLE_ID', required('CERTIFICATE_OSX_ID')),
    line('APPLE_APP_SPECIFIC_PASSWORD', required('CERTIFICATE_OSX_APP_PASSWORD')),
    line('APPLE_TEAM_ID', teamId),
  ]
  await writeFile(join(secrets, 'macos-signing.env'), `${signing.join('\n')}\n`, { mode: 0o600 })
}
process.stdout.write(`Prepared QingClaw ${deployment} ${publishOnly ? 'publication' : 'packaging'} configuration\n`)
