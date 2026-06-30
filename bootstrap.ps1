$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$spmwRoot = Join-Path $env:USERPROFILE ".spmw"
$bootstrapRoot = Join-Path $spmwRoot "bootstrap"
$userBinRoot = Join-Path $env:USERPROFILE ".local\bin"
$spmwBinRoot = Join-Path $spmwRoot "bin"

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

function Normalize-PathEntry {
    param([Parameter(Mandatory)][string]$Path)

    try {
        return [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd("\")
    } catch {
        return $Path.TrimEnd("\")
    }
}

function Set-PathOrder {
    param(
        [Parameter(Mandatory)][string[]]$Preferred
    )

    foreach ($path in $Preferred) {
        Ensure-Directory $path
    }

    $preferredFull = @($Preferred | ForEach-Object { Normalize-PathEntry -Path $_ })
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $entries = if ([string]::IsNullOrWhiteSpace($userPath)) {
        @()
    } else {
        @($userPath -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $kept = @()
    foreach ($entry in $entries) {
        $entryFull = Normalize-PathEntry -Path $entry
        $isPreferred = $false
        foreach ($path in $preferredFull) {
            if ([string]::Equals($entryFull, $path, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isPreferred = $true
                break
            }
        }
        if (-not $isPreferred) {
            $kept += $entry
        }
    }
    [Environment]::SetEnvironmentVariable("Path", (@($preferredFull) + $kept) -join ";", "User")

    $processEntries = if ([string]::IsNullOrWhiteSpace($env:PATH)) {
        @()
    } else {
        @($env:PATH -split ";" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $processKept = @()
    foreach ($entry in $processEntries) {
        $entryFull = Normalize-PathEntry -Path $entry
        $isPreferred = $false
        foreach ($path in $preferredFull) {
            if ([string]::Equals($entryFull, $path, [System.StringComparison]::OrdinalIgnoreCase)) {
                $isPreferred = $true
                break
            }
        }
        if (-not $isPreferred) {
            $processKept += $entry
        }
    }
    $env:PATH = (@($preferredFull) + $processKept) -join ";"
}

Ensure-Directory $bootstrapRoot
Set-PathOrder -Preferred @($userBinRoot, $spmwBinRoot)

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

$cli = Join-Path $spmwBinRoot "spmw-cli.cmd"
& $cli update
if ($LASTEXITCODE -ne 0) {
    throw "formal spmw update failed"
}
& $cli install
if ($LASTEXITCODE -ne 0) {
    throw "formal spmw install failed"
}
