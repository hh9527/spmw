$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$spmwRoot = Join-Path $env:USERPROFILE ".spmw"
$bootstrapRoot = Join-Path $spmwRoot "bootstrap"
$userBinRoot = Join-Path $env:USERPROFILE ".local\bin"

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Invoke-CurlDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )

    Ensure-Directory (Split-Path -Parent $OutFile)
    $tmp = "$OutFile.tmp"
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }
    & curl.exe -fL --progress-bar --retry 3 --connect-timeout 20 -o $tmp $Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Url"
    }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

function Get-Text {
    param([Parameter(Mandatory)][string]$Url)

    $text = & curl.exe -fLsS --retry 3 --connect-timeout 20 $Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Url"
    }
    return ([string]::Join("`n", @($text))).Trim()
}

function Resolve-UrlReference {
    param(
        [Parameter(Mandatory)][string]$BaseUrl,
        [Parameter(Mandatory)][string]$Reference
    )

    $baseUri = [System.Uri]::new($BaseUrl)
    $resolved = [System.Uri]::new($baseUri, $Reference.Trim())
    if ($resolved.Scheme -ne "http" -and $resolved.Scheme -ne "https") {
        throw "resolved URL must use http or https: $resolved"
    }
    return $resolved.AbsoluteUri
}

function Ensure-UserPathEntry {
    param([Parameter(Mandatory)][string]$Path)

    Ensure-Directory $Path
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd("\")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = @()
    if (-not [string]::IsNullOrWhiteSpace($userPath)) {
        $entries = @($userPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $exists = $false
    foreach ($entry in $entries) {
        try {
            $entryFullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entry)).TrimEnd("\")
        } catch {
            $entryFullPath = $entry.TrimEnd("\")
        }
        if ([string]::Equals($entryFullPath, $fullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }

    if (-not $exists) {
        $newUserPath = if ($entries.Count -gt 0) {
            (@($entries) + $fullPath) -join ";"
        } else {
            $fullPath
        }
        [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
    }

    $processEntries = @($env:PATH -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $processExists = $false
    foreach ($entry in $processEntries) {
        try {
            $entryFullPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($entry)).TrimEnd("\")
        } catch {
            $entryFullPath = $entry.TrimEnd("\")
        }
        if ([string]::Equals($entryFullPath, $fullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $processExists = $true
            break
        }
    }
    if (-not $processExists) {
        $env:PATH = if ([string]::IsNullOrWhiteSpace($env:PATH)) { $fullPath } else { "$env:PATH;$fullPath" }
    }
}

Ensure-Directory $bootstrapRoot
Ensure-UserPathEntry -Path $userBinRoot

$sourceUrl = [string]$env:SPMW_SOURCE_URL
if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
    $sourceUrl = "https://hh9527.github.io/spmw/channels/latest.txt"
}
$sourceUrl = $sourceUrl.Trim()
if ($sourceUrl -notmatch "^https?://") {
    throw "SPMW_SOURCE_URL must be an http(s) channel URL: $sourceUrl"
}
$sourceParts = $sourceUrl -split "#", 2
$channelUrl = $sourceParts[0]
$tarballUrl = Resolve-UrlReference -BaseUrl $channelUrl -Reference (Get-Text -Url $channelUrl)
$tarball = Join-Path $bootstrapRoot "spmw.tar.gz"
$extractRoot = Join-Path $bootstrapRoot ".extract"

Invoke-CurlDownload -Url $tarballUrl -OutFile $tarball

if (Test-Path -LiteralPath $extractRoot) {
    Remove-Item -LiteralPath $extractRoot -Recurse -Force
}
Ensure-Directory $extractRoot
& tar.exe -xf $tarball -C $extractRoot
if ($LASTEXITCODE -ne 0) {
    throw "tar failed for $tarball"
}

$payloadRoot = $extractRoot
if (-not (Test-Path -LiteralPath (Join-Path $payloadRoot "bin\spmw-cli.ps1"))) {
    $candidates = @(Get-ChildItem -LiteralPath $extractRoot -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName "bin\spmw-cli.ps1")
    })
    if ($candidates.Count -ne 1) {
        throw "tarball must contain bin\spmw-cli.ps1 at root or inside one top-level directory: $tarballUrl"
    }
    $payloadRoot = $candidates[0].FullName
}

if (Test-Path -LiteralPath (Join-Path $bootstrapRoot "bin")) {
    Remove-Item -LiteralPath (Join-Path $bootstrapRoot "bin") -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $bootstrapRoot "config.spmw.json")) {
    Remove-Item -LiteralPath (Join-Path $bootstrapRoot "config.spmw.json") -Force
}
Copy-Item -LiteralPath (Join-Path $payloadRoot "bin") -Destination $bootstrapRoot -Recurse -Force
if (Test-Path -LiteralPath (Join-Path $payloadRoot "config.spmw.json")) {
    Copy-Item -LiteralPath (Join-Path $payloadRoot "config.spmw.json") -Destination $bootstrapRoot -Force
}
Remove-Item -LiteralPath $extractRoot -Recurse -Force

$bootstrapCli = Join-Path $bootstrapRoot "bin\spmw-cli.ps1"
& powershell.exe -ExecutionPolicy Bypass -File $bootstrapCli source add spmw $sourceUrl
if ($LASTEXITCODE -ne 0) {
    throw "spmw source add failed"
}
& powershell.exe -ExecutionPolicy Bypass -File $bootstrapCli update
if ($LASTEXITCODE -ne 0) {
    throw "spmw update failed"
}
& powershell.exe -ExecutionPolicy Bypass -File $bootstrapCli install
if ($LASTEXITCODE -ne 0) {
    throw "spmw install failed"
}

$cli = Join-Path $userBinRoot "spmw-cli.ps1"
& powershell.exe -ExecutionPolicy Bypass -File $cli update
if ($LASTEXITCODE -ne 0) {
    throw "formal spmw update failed"
}
& powershell.exe -ExecutionPolicy Bypass -File $cli install
if ($LASTEXITCODE -ne 0) {
    throw "formal spmw install failed"
}
