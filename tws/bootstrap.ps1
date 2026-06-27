Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:SPMW_DEV_HOST)) {
    throw "Missing required environment variable: SPMW_DEV_HOST"
}

$BaseUrl = "http://$env:SPMW_DEV_HOST"
$UserProfile = [Environment]::GetFolderPath("UserProfile")
$SpmwRoot = Join-Path $UserProfile ".spmw"
$BinRoot = Join-Path $SpmwRoot "bootstrap\bin"
$LocalConfigPath = Join-Path $UserProfile ".config.spmw.json"

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )

    Ensure-Directory (Split-Path -Parent $OutFile)
    $tmp = "$OutFile.tmp"
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Force
    }

    Write-Host "fetching $Url ..."
    & curl.exe -fL --progress-bar --retry 3 --connect-timeout 20 -o $tmp $Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Url"
    }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

function Invoke-ReadText {
    param([Parameter(Mandatory)][string]$Url)

    Write-Host "reading $Url ..."
    $text = & curl.exe -fLsS --retry 3 --connect-timeout 20 $Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Url"
    }
    return ([string]::Join("`n", @($text))).Trim()
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

Ensure-Directory $SpmwRoot
Ensure-Directory $BinRoot

$localConfigTemplate = Invoke-ReadText -Url "$BaseUrl/dev-config.spmw.json.txt"
$localConfig = $localConfigTemplate.Replace("SPMW_DEV_HOST", $env:SPMW_DEV_HOST)
Set-Content -Encoding UTF8 -Path $LocalConfigPath -Value $localConfig

$sha256 = Invoke-ReadText -Url "$BaseUrl/spmw.sha256.txt"

$tarball = Join-Path $SpmwRoot "bootstrap\spmw-$sha256.tar.gz"
Invoke-Download -Url "$BaseUrl/spmw-$sha256.tar.gz" -OutFile $tarball

$actual = Get-FileSha256 -Path $tarball
if ($actual -ne $sha256.ToLowerInvariant()) {
    throw "sha256 mismatch for spmw bootstrap: expected $sha256, got $actual"
}

$extract = Join-Path $SpmwRoot "bootstrap\extract"
if (Test-Path -LiteralPath $extract) {
    Remove-Item -LiteralPath $extract -Recurse -Force
}
Ensure-Directory $extract

& tar.exe -xf $tarball -C $extract
if ($LASTEXITCODE -ne 0) {
    throw "tar failed for $tarball"
}

$cli = Join-Path $extract "bin\spmw-cli.ps1"
if (-not (Test-Path -LiteralPath $cli)) {
    throw "Missing spmw cli in bootstrap tarball: $cli"
}

Copy-Item -LiteralPath $cli -Destination (Join-Path $BinRoot "spmw-cli.ps1") -Force
$installedCli = Join-Path $BinRoot "spmw-cli.ps1"

& powershell.exe -ExecutionPolicy Bypass -File $installedCli update
if ($LASTEXITCODE -ne 0) {
    throw "spmw update failed"
}

& powershell.exe -ExecutionPolicy Bypass -File $installedCli install
if ($LASTEXITCODE -ne 0) {
    throw "spmw install failed"
}

Write-Host "SPMW bootstrap complete"
