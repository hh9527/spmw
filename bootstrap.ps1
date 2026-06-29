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
    $sourceUrl = "https://github.com/hh9527/spmw/releases/download/latest"
}
$sourceUrl = $sourceUrl.TrimEnd("/")
if ($sourceUrl -notmatch "^(https?://.+)/([^/]+)$") {
    throw "SPMW_SOURCE_URL must match http(s)://<BASE>/<VERSION>: $sourceUrl"
}
$baseUrl = $Matches[1]
$sourceVersion = $Matches[2]
$versionUrl = "$baseUrl/$sourceVersion/VERSION.txt"
$version = Get-Text -Url $versionUrl
$tarballUrl = "$baseUrl/$version/spmw.tar.gz"
$shaUrl = "$baseUrl/$version/spmw.tar.gz.sha256"
$tarball = Join-Path $bootstrapRoot "spmw.tar.gz"
$shaFile = Join-Path $bootstrapRoot "spmw.tar.gz.sha256"

Invoke-CurlDownload -Url $tarballUrl -OutFile $tarball
Invoke-CurlDownload -Url $shaUrl -OutFile $shaFile

$expectedSha = (Get-Content -Raw -Path $shaFile).Trim().Split()[0].ToLowerInvariant()
$actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $tarball).Hash.ToLowerInvariant()
if ($expectedSha -ne $actualSha) {
    throw "sha256 mismatch for $tarballUrl`: expected $expectedSha, got $actualSha"
}

if (Test-Path -LiteralPath (Join-Path $bootstrapRoot "bin")) {
    Remove-Item -LiteralPath (Join-Path $bootstrapRoot "bin") -Recurse -Force
}
& tar.exe -xf $tarball -C $bootstrapRoot
if ($LASTEXITCODE -ne 0) {
    throw "tar failed for $tarball"
}

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
