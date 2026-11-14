/**
 * electron-builder configuration for an already signed QingClaw Windows tree.
 *
 * The DSH checkout owns the application, NSIS layout and installer artwork; this
 * wrapper keeps that configuration and replaces only the signer and update
 * target so yuejuan-builder can use SSL.com eSigner.
 */
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const dshRoot = process.env.QINGCLAW_DSH_ROOT
const output = process.env.QINGCLAW_WIN_OUTPUT
const signHook = process.env.QINGCLAW_WIN_SIGN_HOOK
const updateUrl = process.env.QINGCLAW_WIN_UPDATE_URL
const channel = process.env.QINGCLAW_CHANNEL || 'nightly'
const version = process.env.QINGCLAW_VERSION
if (!version) throw new Error('QINGCLAW_VERSION is required')

for (const [name, value] of Object.entries({ QINGCLAW_DSH_ROOT: dshRoot, QINGCLAW_WIN_OUTPUT: output,
  QINGCLAW_WIN_SIGN_HOOK: signHook, QINGCLAW_WIN_UPDATE_URL: updateUrl })) {
  if (value === undefined || value.trim() === '') throw new Error(`${name} is required`)
}

const [{ createElectronBuilderConfig }, { loadDesktopPackageEnvironment }, { default: eSigner }] = await Promise.all([
  import(pathToFileURL(resolve(dshRoot, 'apps/desktop/scripts/electron-builder-config.mjs')).href),
  import(pathToFileURL(resolve(dshRoot, 'apps/desktop/scripts/desktop-package-environment.mjs')).href),
  import(pathToFileURL(signHook).href),
])

export default async function qingclawWindowsConfig() {
  const baseEnv = loadDesktopPackageEnvironment('win32', process.env, resolve(dshRoot, 'apps/desktop'), { unsigned: true })
  baseEnv.DSH_DESKTOP_UNSIGNED = '1'
  baseEnv.DSH_DESKTOP_TARGET_PLATFORM = 'win32'
  baseEnv.DSH_DESKTOP_TARGET_ARCH = 'x64'
  const config = createElectronBuilderConfig(baseEnv, 'win32', 'x64')

  config.directories = { ...config.directories, output }
  // The DSH checkout keeps the product version (0.2.2-rc.3); the test build
  // version must reach the installer and the update feed so electron-updater
  // can order builds within the same base.
  config.extraMetadata = { ...config.extraMetadata, version }
  config.artifactName = `qingclaw-${version}-windows-x64.\${ext}`
  config.publish = [{ provider: 'generic', url: updateUrl, channel }]
  config.win = {
    ...config.win,
    forceCodeSigning: true,
    signtoolOptions: { sign: eSigner, signingHashAlgorithms: ['sha256'] },
  }
  delete config.win.sign
  return config
}
