[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet('Prepare', 'RestoreAndVerify', 'VerifyTree')]
  [string]$Mode,

  [Parameter(Mandatory = $true)]
  [string]$SourceRoot,

  [string]$StagingDir,
  [string]$SignedDir,
  [string]$MappingPath,
  [string[]]$Extensions = @('.exe', '.dll')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedExtensions {
  param([string[]]$Values)

  return @($Values | ForEach-Object {
    $value = $_.Trim().ToLowerInvariant()
    if (-not $value.StartsWith('.')) {
      $value = ".${value}"
    }
    $value
  } | Sort-Object -Unique)
}

function Get-SignableFiles {
  param(
    [string]$Root,
    [string[]]$AllowedExtensions
  )

  return @(Get-ChildItem -LiteralPath $Root -Recurse -File |
    Where-Object { $AllowedExtensions -contains $_.Extension.ToLowerInvariant() } |
    Sort-Object FullName)
}

function Assert-RootExecutable {
  param(
    [string]$Root,
    [System.IO.FileInfo[]]$Files
  )

  $rootExecutables = @($Files | Where-Object {
    $_.Extension.Equals('.exe', [System.StringComparison]::OrdinalIgnoreCase) -and
      [System.StringComparer]::OrdinalIgnoreCase.Equals($_.Directory.FullName, $Root)
  })

  if ($rootExecutables.Count -eq 0) {
    throw "No root application executable found in: $Root"
  }

  Write-Host "Root application executable(s): $($rootExecutables.Name -join ', ')"
}

function Assert-ValidSignature {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Signed file is missing: $Path"
  }

  $signature = Get-AuthenticodeSignature -LiteralPath $Path
  if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "Invalid Authenticode signature for '$Path': $($signature.Status) $($signature.StatusMessage)"
  }
  if ($null -eq $signature.SignerCertificate) {
    throw "Signer certificate is missing for: $Path"
  }
  if ($null -eq $signature.TimeStamperCertificate) {
    throw "Timestamp certificate is missing for: $Path"
  }

  Write-Host "Verified: $Path"
  Write-Host "  signer: $($signature.SignerCertificate.Subject)"
  Write-Host "  timestamp: $($signature.TimeStamperCertificate.Subject)"
}

$sourceRootPath = (Resolve-Path -LiteralPath $SourceRoot).Path
$normalizedExtensions = Get-NormalizedExtensions -Values $Extensions

switch ($Mode) {
  'Prepare' {
    if ([string]::IsNullOrWhiteSpace($StagingDir)) {
      throw 'StagingDir is required in Prepare mode.'
    }
    if ([string]::IsNullOrWhiteSpace($MappingPath)) {
      throw 'MappingPath is required in Prepare mode.'
    }

    $stagingDirPath = [System.IO.Path]::GetFullPath($StagingDir)
    $mappingPathFull = [System.IO.Path]::GetFullPath($MappingPath)

    Remove-Item -LiteralPath $stagingDirPath -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stagingDirPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $mappingPathFull) -Force | Out-Null

    $files = Get-SignableFiles -Root $sourceRootPath -AllowedExtensions $normalizedExtensions
    if ($files.Count -eq 0) {
      throw "No signable files found in: $sourceRootPath"
    }
    if ($files.Count -gt 100) {
      throw "SSL.com batch_sign supports at most 100 files; found $($files.Count) in: $sourceRootPath"
    }
    Assert-RootExecutable -Root $sourceRootPath -Files $files

    $entries = @()
    for ($index = 0; $index -lt $files.Count; $index++) {
      $file = $files[$index]
      $stagedName = 'payload-{0:D4}{1}' -f $index, $file.Extension.ToLowerInvariant()
      $relativePath = [System.IO.Path]::GetRelativePath($sourceRootPath, $file.FullName)
      Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stagingDirPath $stagedName) -Force
      $entries += [ordered]@{
        stagedName = $stagedName
        relativePath = $relativePath
      }
    }

    $manifest = [ordered]@{
      schemaVersion = 1
      sourceRoot = $sourceRootPath
      extensions = $normalizedExtensions
      files = $entries
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mappingPathFull -Encoding utf8
    Write-Host "Prepared $($files.Count) file(s) for signing."
  }

  'RestoreAndVerify' {
    if ([string]::IsNullOrWhiteSpace($SignedDir)) {
      throw 'SignedDir is required in RestoreAndVerify mode.'
    }
    if ([string]::IsNullOrWhiteSpace($MappingPath)) {
      throw 'MappingPath is required in RestoreAndVerify mode.'
    }

    $signedDirPath = (Resolve-Path -LiteralPath $SignedDir).Path
    $mappingPathFull = (Resolve-Path -LiteralPath $MappingPath).Path
    $manifest = Get-Content -LiteralPath $mappingPathFull -Raw | ConvertFrom-Json
    $entries = @($manifest.files)
    if ($entries.Count -eq 0) {
      throw "Signing manifest contains no files: $mappingPathFull"
    }

    foreach ($entry in $entries) {
      $signedPath = Join-Path $signedDirPath $entry.stagedName
      $destinationPath = Join-Path $sourceRootPath $entry.relativePath
      if (-not (Test-Path -LiteralPath $signedPath -PathType Leaf)) {
        throw "Signing service did not return: $($entry.stagedName)"
      }
      Copy-Item -LiteralPath $signedPath -Destination $destinationPath -Force
      Assert-ValidSignature -Path $destinationPath
    }

    $allFiles = Get-SignableFiles -Root $sourceRootPath -AllowedExtensions $normalizedExtensions
    Assert-RootExecutable -Root $sourceRootPath -Files $allFiles
    if ($allFiles.Count -ne $entries.Count) {
      throw "Signable file count changed during signing: expected $($entries.Count), found $($allFiles.Count)"
    }
    Write-Host "Restored and verified $($entries.Count) signed file(s)."
  }

  'VerifyTree' {
    $files = Get-SignableFiles -Root $sourceRootPath -AllowedExtensions $normalizedExtensions
    if ($files.Count -eq 0) {
      throw "No signable files found in: $sourceRootPath"
    }
    Assert-RootExecutable -Root $sourceRootPath -Files $files
    foreach ($file in $files) {
      Assert-ValidSignature -Path $file.FullName
    }
    Write-Host "Verified $($files.Count) signed file(s) in: $sourceRootPath"
  }
}
