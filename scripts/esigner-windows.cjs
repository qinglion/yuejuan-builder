'use strict'

const fs = require('fs')
const path = require('path')
const { spawn } = require('child_process')

let signingQueue = Promise.resolve()
let stagingCounter = 0

function run(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      windowsHide: true,
      shell: false,
      ...options
    })
    let stdout = ''
    let stderr = ''

    child.stdout.on('data', chunk => { stdout += chunk.toString() })
    child.stderr.on('data', chunk => { stderr += chunk.toString() })

    const timer = setTimeout(() => {
      child.kill()
      reject(new Error(`Command timed out: ${path.basename(command)}`))
    }, 10 * 60 * 1000)

    child.on('error', error => {
      clearTimeout(timer)
      reject(error)
    })
    child.on('close', code => {
      clearTimeout(timer)
      if (code !== 0) {
        reject(new Error(`Command failed with exit code ${code}:\n${stdout}\n${stderr}`))
        return
      }
      resolve({ stdout, stderr })
    })
  })
}

function redact(value, secrets) {
  return secrets.reduce((text, secret) => {
    return secret ? text.split(secret).join('***') : text
  }, String(value))
}

function requiredEnvironment(name) {
  const value = process.env[name]
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`)
  }
  return value
}

async function signOne(configuration) {
  if (configuration.hash !== 'sha256') {
    throw new Error(`Unexpected signing hash algorithm: ${configuration.hash}`)
  }

  const target = path.resolve(configuration.path)
  if (!fs.existsSync(target)) {
    throw new Error(`Signing target is missing: ${target}`)
  }

  const toolRoot = requiredEnvironment('CODE_SIGN_TOOL_PATH')
  const username = requiredEnvironment('ES_USERNAME')
  const password = requiredEnvironment('ES_PASSWORD')
  const credentialId = requiredEnvironment('CREDENTIAL_ID')
  const totpSecret = requiredEnvironment('ES_TOTP_SECRET')
  const secrets = [username, password, credentialId, totpSecret]

  const jarDirectory = path.join(toolRoot, 'jar')
  const jarName = fs.readdirSync(jarDirectory)
    .find(name => /^code_sign_tool-.*\.jar$/i.test(name))
  if (!jarName) {
    throw new Error(`SSL.com CodeSignTool jar was not found in: ${jarDirectory}`)
  }

  const javaHome = process.env.JAVA_HOME
  const javaExecutable = javaHome
    ? path.join(javaHome, 'bin', 'java.exe')
    : 'java.exe'
  const extension = path.extname(target) || '.exe'
  const stagingPath = path.join(
    path.dirname(target),
    `.esigner-${process.pid}-${Date.now()}-${stagingCounter++}${extension}`
  )
  fs.copyFileSync(target, stagingPath)

  const javaArgs = [
    `-Xmx${process.env.ESIGNER_JVM_MAX_MEMORY || '1024M'}`,
    '-jar',
    path.join(jarDirectory, jarName),
    'sign',
    `-username=${username}`,
    `-password=${password}`,
    `-credential_id=${credentialId}`,
    `-totp_secret=${totpSecret}`,
    `-input_file_path=${stagingPath}`,
    '-override=true',
    '-malware_block=true'
  ]

  let result
  try {
    result = await run(javaExecutable, javaArgs, {
      cwd: toolRoot,
      env: process.env
    })
  } catch (error) {
    fs.rmSync(stagingPath, { force: true })
    throw new Error(redact(error && error.message ? error.message : error, secrets))
  }

  const toolOutput = `${result.stdout}\n${result.stderr}`
  if (/(Error|Exception|Missing required option|Unmatched argument)/.test(toolOutput)) {
    fs.rmSync(stagingPath, { force: true })
    throw new Error(redact(toolOutput, secrets))
  }

  fs.copyFileSync(stagingPath, target)
  fs.rmSync(stagingPath, { force: true })

  const verificationCommand = [
    "$ErrorActionPreference='Stop'",
    '$signature=Get-AuthenticodeSignature -LiteralPath $env:YUEJUAN_SIGN_TARGET',
    "if ($signature.Status -ne 'Valid') { throw ('Invalid Authenticode status: '+$signature.Status+' '+$signature.StatusMessage) }",
    "if ($null -eq $signature.SignerCertificate) { throw 'Signer certificate is missing' }",
    "if ($null -eq $signature.TimeStamperCertificate) { throw 'Timestamp certificate is missing' }",
    '[pscustomobject]@{subject=$signature.SignerCertificate.Subject;timestampSubject=$signature.TimeStamperCertificate.Subject}|ConvertTo-Json -Compress'
  ].join(';')
  const verification = await run(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', verificationCommand],
    {
      env: { ...process.env, YUEJUAN_SIGN_TARGET: target }
    }
  )
  const certificate = JSON.parse(verification.stdout.trim())
  const auditEntry = {
    path: target,
    subject: certificate.subject,
    timestampSubject: certificate.timestampSubject
  }

  if (process.env.ESIGNER_AUDIT_LOG) {
    fs.appendFileSync(process.env.ESIGNER_AUDIT_LOG, `${JSON.stringify(auditEntry)}\n`)
  }
  console.log(`Signed and verified ${path.basename(target)} (${auditEntry.subject})`)
}

function sign(configuration) {
  const task = signingQueue.then(() => signOne(configuration))
  signingQueue = task.catch(() => {})
  return task
}

module.exports = sign
module.exports.sign = sign
module.exports.default = sign
