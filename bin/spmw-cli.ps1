param(
    [Parameter(Position = 0)]
    [ValidateSet("update", "install", "prune", "source")]
    [string]$Command,
    [Parameter(Position = 1)]
    [string]$SourceCommand,
    [Parameter(Position = 2)]
    [string]$SourceName,
    [Parameter(Position = 3)]
    [string]$SourceSpec,
    [switch]$Help,
    [switch]$Prepare,
    [switch]$Pkgs,
    [switch]$Fonts,
    [switch]$Cache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Script:ToolRoot = $PSScriptRoot
$Script:ConfigRoot = Join-Path $env:USERPROFILE ".spmw"
$Script:ObjectRoot = Join-Path $Script:ConfigRoot "object"
$Script:PackageRoot = Join-Path $Script:ObjectRoot "pkgs"
$Script:FontRoot = Join-Path $Script:ObjectRoot "fonts"
$Script:DownloadRoot = Join-Path $Script:ObjectRoot "dl"
$Script:StateRoot = Join-Path $Script:ConfigRoot "state"
$Script:PlanRoot = Join-Path $Script:StateRoot "plan"
$Script:ScratchRoot = Join-Path $Script:ConfigRoot ".tmp"
$Script:SourcesPath = Join-Path $env:USERPROFILE "sources.spmw.json"
$Script:NextPlanPath = Join-Path $Script:StateRoot "next-plan.json"
$Script:LockPath = Join-Path $Script:StateRoot "lock.json"

$Script:Roots = @{
    user = $env:USERPROFILE
    apps = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\SPMW"
    bin = Join-Path $env:USERPROFILE ".local\bin"
}

function Ensure-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command: $Name"
    }
}

function Show-Help {
    Write-Host @"
spmw-cli.ps1 update
spmw-cli.ps1 install [-Prepare]
spmw-cli.ps1 prune [-Pkgs] [-Fonts] [-Cache]
spmw-cli.ps1 source add <name> gh-src:<OWNER>/<REPO>/<BRANCH>|http(s)://<CHANNEL.txt>[#<config-rpath>]
spmw-cli.ps1 -Help

Commands:
  update   Resolve config and variables, then write next-plan.json.
  install  Install next-plan.json and activate it unless -Prepare is set.
  prune    Remove unused plans/resources; scope with -Pkgs, -Fonts, -Cache.
  source   Manage local source refs.

Options:
  -Prepare           Install objects without activation.
"@
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Clear-Scratch {
    if (Test-Path -LiteralPath $Script:ScratchRoot) {
        Remove-Item -LiteralPath $Script:ScratchRoot -Recurse -Force
    }
    Ensure-Directory $Script:ScratchRoot
}

function Join-PathParts {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Relative
    )

    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -eq ".") {
        return $Root
    }

    return Join-Path $Root ($Relative -replace "/", "\")
}

function Test-Property {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    return $Value.PSObject.Properties.Name -contains $Name
}

function Test-MapKey {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map.Contains($Key)
    }

    return $Map.PSObject.Properties.Name -contains $Key
}

function Get-MapValue {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$Key
    )

    if ($Map -is [System.Collections.IDictionary]) {
        return $Map[$Key]
    }

    $property = $Map.PSObject.Properties[$Key]
    if ($null -eq $property) {
        throw "Missing map key: $Key"
    }
    return $property.Value
}

function Test-PackageKey {
    param([Parameter(Mandatory)][string]$Name)

    return $Name -match "^[A-Za-z0-9][A-Za-z0-9._-]*$"
}

function Test-SourceKey {
    param([Parameter(Mandatory)][string]$Name)

    return $Name -match "^source\.[A-Za-z0-9][A-Za-z0-9._-]*$"
}

function Assert-PackageKey {
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$AllowSource
    )

    if (-not (Test-PackageKey -Name $Name)) {
        throw "Invalid package key: $Name"
    }
    if (-not $AllowSource -and $Name.StartsWith("source.")) {
        throw "Normal package key must not start with source.: $Name"
    }
}

function Assert-SourceKey {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Test-SourceKey -Name $Name)) {
        throw "Invalid source key: $Name"
    }
}

function Test-SourceName {
    param([Parameter(Mandatory)][string]$Name)

    return $Name -match "^[A-Za-z0-9][A-Za-z0-9._-]*$"
}

function Get-Json {
    param([Parameter(Mandatory)][string]$Path)

    return Get-Content -Raw -Path $Path | ConvertFrom-Json
}

function ConvertTo-Hashtable {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = $Value[$key]
        }
        return $result
    }

    $table = [ordered]@{}
    foreach ($property in $Value.PSObject.Properties) {
        $table[$property.Name] = $property.Value
    }
    return $table
}

function Save-JsonAtomic {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    Ensure-Directory (Split-Path -Parent $Path)
    $name = Split-Path -Leaf $Path
    $tmp = Join-Path (Split-Path -Parent $Path) ".tmp.$name"
    Set-Content -Encoding UTF8 -Path $tmp -Value (ConvertTo-PrettyJson -Value $Value)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function ConvertTo-PrettyJson {
    param(
        $Value,
        [int]$Level = 0
    )

    $indent = "  " * $Level
    $childIndent = "  " * ($Level + 1)

    if ($null -eq $Value) {
        return "null"
    }

    if ($Value -is [string]) {
        return ConvertTo-JsonString -Text $Value
    }

    if ($Value -is [bool]) {
        if ($Value) { return "true" }
        return "false"
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0}", $Value))
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            return "[]"
        }
        $lines = @("[")
        for ($i = 0; $i -lt $items.Count; $i++) {
            $suffix = if ($i -lt $items.Count - 1) { "," } else { "" }
            $lines += $childIndent + (ConvertTo-PrettyJson -Value $items[$i] -Level ($Level + 1)) + $suffix
        }
        $lines += "$indent]"
        return ($lines -join "`n")
    }

    $props = if ($Value -is [System.Collections.IDictionary]) {
        $Value.Keys | ForEach-Object {
            [pscustomobject]@{ Name = $_; Value = $Value[$_] }
        }
    } else {
        $Value.PSObject.Properties |
            Where-Object { $_.MemberType -eq "NoteProperty" -or $_.MemberType -eq "Property" }
    }
    $props = @($props)
    if ($props.Count -eq 0) {
        return "{}"
    }

    $lines = @("{")
    for ($i = 0; $i -lt $props.Count; $i++) {
        $property = $props[$i]
        $suffix = if ($i -lt $props.Count - 1) { "," } else { "" }
        $name = ConvertTo-JsonString -Text ([string]$property.Name)
        $valueJson = ConvertTo-PrettyJson -Value $property.Value -Level ($Level + 1)
        $lines += "$childIndent$name`: $valueJson$suffix"
    }
    $lines += "$indent}"
    return ($lines -join "`n")
}

function ConvertTo-JsonString {
    param([Parameter(Mandatory)][string]$Text)

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$builder.Append('\"') }
            '\' { [void]$builder.Append('\\') }
            "`b" { [void]$builder.Append('\b') }
            "`f" { [void]$builder.Append('\f') }
            "`n" { [void]$builder.Append('\n') }
            "`r" { [void]$builder.Append('\r') }
            "`t" { [void]$builder.Append('\t') }
            default {
                if ([int][char]$ch -lt 0x20) {
                    [void]$builder.Append('\u{0:x4}' -f [int][char]$ch)
                } else {
                    [void]$builder.Append($ch)
                }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $sha.Dispose()
    }
}

function ConvertTo-StableJson {
    param($Value)

    if ($null -eq $Value) {
        return "null"
    }

    if ($Value -is [string]) {
        return ConvertTo-JsonString -Text $Value
    }

    if ($Value -is [bool]) {
        if ($Value) { return "true" }
        return "false"
    }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        return ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0}", $Value))
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
        $items = @($Value | ForEach-Object { ConvertTo-StableJson $_ })
        return "[" + ($items -join ",") + "]"
    }

    $props = if ($Value -is [System.Collections.IDictionary]) {
        $Value.Keys | Sort-Object | ForEach-Object {
            [pscustomobject]@{ Name = $_; Value = $Value[$_] }
        }
    } else {
        $Value.PSObject.Properties |
            Where-Object { $_.MemberType -eq "NoteProperty" -or $_.MemberType -eq "Property" } |
            Sort-Object Name
    }

    $pairs = @($props | ForEach-Object {
        (ConvertTo-JsonString -Text ([string]$_.Name)) + ":" + (ConvertTo-StableJson $_.Value)
    })
    return "{" + ($pairs -join ",") + "}"
}

function Normalize-Value {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = Normalize-Value -Value $Value[$key]
        }
        if ($result.Contains("src") -and -not $result.Contains("ty")) {
            $result["ty"] = "Text"
        }
        return $result
    }

    if ($Value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = Normalize-Value -Value $property.Value
        }
        if ($result.Contains("src") -and -not $result.Contains("ty")) {
            $result["ty"] = "Text"
        }
        return [pscustomobject]$result
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        return @($Value | ForEach-Object { Normalize-Value -Value $_ })
    }

    return $Value
}

function Normalize-Package {
    param([Parameter(Mandatory)]$Package)

    return Normalize-Value -Value $Package
}

function Expand-Template {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)]$Variables
    )

    return [regex]::Replace($Text, "<([^>]+)>", {
        param($Match)

        $name = $Match.Groups[1].Value
        if (-not (Test-MapKey -Map $Variables -Key $name)) {
            throw "Unknown variable <$name> in template: $Text"
        }
        return [string]$Variables[$name]
    })
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

    $args = @("-fL", "--progress-bar", "--retry", "3", "--connect-timeout", "20", "-o", $tmp, $Url)

    Write-Host "fetching $Url ..."
    & curl.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Url"
    }

    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

function Invoke-CurlText {
    param([Parameter(Mandatory)][string]$Url)

    Write-Host "reading $Url ..."
    $text = & curl.exe -fLsS --retry 3 --connect-timeout 20 $Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed for $Url"
    }
    return ([string]::Join("`n", @($text))).Trim()
}

function Normalize-RemoteTextVariable {
    param([Parameter(Mandatory)][string]$Text)

    $trimmed = $Text.Trim()
    $sha256 = [regex]::Match($trimmed, "^(?<sha256>[0-9a-fA-F]{64})(\s|$)")
    if ($sha256.Success) {
        return $sha256.Groups["sha256"].Value.ToLowerInvariant()
    }
    return $trimmed
}

function Resolve-RemoteVariable {
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$Ty
    )

    $text = Invoke-CurlText -Url $Src
    switch ($Ty) {
        "Text" {
            return Normalize-RemoteTextVariable -Text $text
        }
        "UrlReference" {
            $baseUri = [System.Uri]::new($Src)
            $resolved = [System.Uri]::new($baseUri, $text.Trim())
            if ($resolved.Scheme -ne "http" -and $resolved.Scheme -ne "https") {
                throw "Package $PackageName variable $Name resolved to unsupported URL scheme: $resolved"
            }
            return $resolved.AbsoluteUri
        }
        "CommitFromGithubAtom" {
            $match = [regex]::Match($text, "Commit/(?<sha>[0-9a-fA-F]{40})")
            if (-not $match.Success) {
                throw "Package $PackageName variable $Name could not read GitHub commit from Atom feed: $Src"
            }
            return $match.Groups["sha"].Value.ToLowerInvariant()
        }
        default {
            throw "Package $PackageName variable $Name has unsupported resolver type: $Ty"
        }
    }
}

function Resolve-Sha256Spec {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)]$Variables
    )

    if ($Spec -is [string]) {
        return (Expand-Template -Text $Spec -Variables $Variables).ToLowerInvariant()
    }

    if (Test-Property -Value $Spec -Name "src") {
        $src = Expand-Template -Text ([string]$Spec.src) -Variables $Variables
        return Normalize-RemoteTextVariable -Text (Invoke-CurlText -Url $src)
    }

    throw "Unsupported sha256 verify spec"
}

function Get-UrlBaseName {
    param([Parameter(Mandatory)][string]$Url)

    $withoutQuery = ($Url -split "[?#]", 2)[0]
    $name = [System.IO.Path]::GetFileName($withoutQuery)
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Cannot derive file name from URL: $Url"
    }
    return $name
}

function New-VersionedFileName {
    param(
        [Parameter(Mandatory)][string]$BaseName,
        [Parameter(Mandatory)][string]$VariableName
    )

    $archiveExts = @(".tar.gz", ".tar.xz", ".tar.bz2", ".tgz", ".zip", ".7z")
    foreach ($ext in $archiveExts) {
        if ($BaseName.EndsWith($ext, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $BaseName.Substring(0, $BaseName.Length - $ext.Length) + "-<$VariableName>" + $ext
        }
    }

    $extName = [System.IO.Path]::GetExtension($BaseName)
    if ([string]::IsNullOrEmpty($extName)) {
        return "$BaseName-<$VariableName>"
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($BaseName) + "-<$VariableName>" + $extName
}

function Get-DownloadPath {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$File
    )

    $srcHash = (Get-TextSha256 -Text $Src).Substring(0, 16)
    return Join-Path $Script:DownloadRoot "$srcHash-$File"
}

function Get-Download {
    param(
        [Parameter(Mandatory)][string]$Src,
        [Parameter(Mandatory)][string]$File,
        $Verify
    )

    $path = Get-DownloadPath -Src $Src -File $File
    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-CurlDownload -Url $Src -OutFile $path
    }

    $actualSha256 = Get-FileSha256 -Path $path
    $verifySha256 = $null
    if ($null -ne $Verify -and (Test-Property -Value $Verify -Name "sha256")) {
        $verifySha256 = [string]$Verify.sha256
        if ($actualSha256 -ne $verifySha256.ToLowerInvariant()) {
            Remove-Item -LiteralPath $path -Force
            throw "sha256 mismatch for $Src`: expected $verifySha256, got $actualSha256"
        }
    }

    return [pscustomobject]@{
        src = $Src
        file = $File
        object = "object:dl/$((Split-Path -Leaf $path) -replace "\\", "/")"
        path = $path
        sha256 = $actualSha256
        verify = if ($verifySha256) { [ordered]@{ sha256 = $verifySha256 } } else { $null }
    }
}

function Resolve-Variables {
    param(
        [Parameter(Mandatory)][string]$PackageName,
        [Parameter(Mandatory)]$Package
    )

    $normalizedPackage = Normalize-Package -Package $Package
    $variables = [ordered]@{}
    $variables["manifest-digest"] = Get-TextSha256 -Text (ConvertTo-StableJson $normalizedPackage)

    if (Test-Property -Value $normalizedPackage -Name "variables") {
        throw "Package $PackageName uses obsolete declaration field: variables; use defs"
    }

    if (Test-Property -Value $normalizedPackage -Name "defs") {
        foreach ($group in @($normalizedPackage.defs)) {
            $bindings = @($group.PSObject.Properties)
            if ($bindings.Count -ne 1) {
                throw "Package $PackageName defs groups must contain exactly one binding"
            }

            $binding = $bindings[0]
            $name = $binding.Name
            if (Test-MapKey -Map $variables -Key $name) {
                throw "Package $PackageName redefines variable: $name"
            }

            $value = $binding.Value
            if ($value -is [string]) {
                $variables[$name] = Expand-Template -Text $value -Variables $variables
            } elseif (Test-Property -Value $value -Name "src") {
                $src = Expand-Template -Text ([string]$value.src) -Variables $variables
                $ty = if (Test-Property -Value $value -Name "ty") { [string]$value.ty } else { "Text" }
                $variables[$name] = Resolve-RemoteVariable -PackageName $PackageName -Name $name -Src $src -Ty $ty
            } else {
                throw "Package $PackageName has unsupported variable binding: $name"
            }
        }
    }

    $variables["variable-digest"] = Get-TextSha256 -Text (ConvertTo-StableJson $variables)
    $variables["path"] = "pkgs/$PackageName.$($variables["variable-digest"].Substring(0, 16))"
    return $variables
}

function Assert-SourceDefinition {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Definition
    )

    Assert-SourceKey -Name $Name
    if (Test-Property -Value $Definition -Name "variables") {
        throw "Source $Name uses obsolete declaration field: variables; use defs"
    }
    if (-not (Test-Property -Value $Definition -Name "install")) {
        throw "Source $Name is missing install"
    }
    foreach ($action in @($Definition.install)) {
        if ([string]$action.action -ne "Unpack") {
            throw "Source $Name only supports Unpack install action"
        }
    }
}

function Expand-ArchiveWithTar {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    Ensure-Directory $Destination

    & tar.exe -xf $Archive -C $Destination
    if ($LASTEXITCODE -ne 0) {
        throw "tar failed for $Archive"
    }
}

function Copy-StrippedExtractedItems {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][int]$Strip
    )

    $sourcePrefix = [System.IO.Path]::GetFullPath($Source).TrimEnd("\") + "\"
    foreach ($item in Get-ChildItem -LiteralPath $Source -Recurse -Force) {
        $relative = $item.FullName.Substring($sourcePrefix.Length)
        $parts = $relative -split "[\\/]+"
        if ($parts.Count -le $Strip) {
            continue
        }

        $stripped = [System.IO.Path]::Combine([string[]]$parts[$Strip..($parts.Count - 1)])
        $target = Join-Path $Destination $stripped
        if ($item.PSIsContainer) {
            Ensure-Directory $target
        } else {
            Ensure-Directory (Split-Path -Parent $target)
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

function Copy-DirectoryContents {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    Ensure-Directory $Destination
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
    }
}

function Commit-PackageDirectory {
    param(
        [Parameter(Mandatory)][string]$TempPath,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)]$Metadata
    )

    $spmwDir = Join-Path $TempPath ".spmw"
    Ensure-Directory $spmwDir
    Save-JsonAtomic -Value $Metadata -Path (Join-Path $spmwDir "metadata.json")
    Set-Content -Path (Join-Path $TempPath ".READY") -Value ""

    Ensure-Directory (Split-Path -Parent $FinalPath)
    if (Test-Path -LiteralPath $FinalPath) {
        Remove-Item -LiteralPath $TempPath -Recurse -Force
        return
    }

    Move-Item -LiteralPath $TempPath -Destination $FinalPath
}

function New-HardLinkOrCopy {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Target
    )

    Ensure-Directory (Split-Path -Parent $Path)
    if (Test-Path -LiteralPath $Path) {
        return
    }

    try {
        New-Item -ItemType HardLink -Path $Path -Target $Target | Out-Null
    } catch {
        Copy-Item -LiteralPath $Target -Destination $Path -Force
    }
}

function Install-FontsFromArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$PackageName,
        [int]$Strip = 0
    )

    $hash = (Get-FileSha256 -Path $Archive).Substring(0, 16)
    $extract = Join-Path $Script:ScratchRoot "$PackageName-fonts-$hash"
    Expand-ArchiveWithTar -Archive $Archive -Destination $extract
    if ($Strip -gt 0) {
        $stripped = Join-Path $Script:ScratchRoot "$PackageName-fonts-stripped-$hash"
        if (Test-Path -LiteralPath $stripped) {
            Remove-Item -LiteralPath $stripped -Recurse -Force
        }
        Ensure-Directory $stripped
        Copy-StrippedExtractedItems -Source $extract -Destination $stripped -Strip $Strip
        $extract = $stripped
    }

    $resources = @()
    $fontRefs = @()
    $fontFiles = Get-ChildItem -LiteralPath $extract -Recurse -File |
        Where-Object { $_.Extension -in @(".ttf", ".otf", ".ttc") }

    foreach ($font in $fontFiles) {
        Write-Host "installing font object $($font.Name) ..."
        $fontHash = (Get-FileSha256 -Path $font.FullName).Substring(0, 16)
        $fontFile = "$($font.BaseName).$fontHash$($font.Extension)"
        $fontPath = Join-Path $Script:FontRoot $fontFile
        New-HardLinkOrCopy -Path $fontPath -Target $font.FullName

        $fontType = switch ($font.Extension.ToLowerInvariant()) {
            ".otf" { "OpenType" }
            ".ttc" { "TrueType Collection" }
            default { "TrueType" }
        }
        $regName = "$($font.BaseName) ($fontType)"
        $fontObject = "object:fonts/$fontFile"
        $fontRefs += $fontObject
        $resources += [pscustomobject]@{
            kind = "reg"
            key = "reg:HKCU/Software/Microsoft/Windows NT/CurrentVersion/Fonts/$regName"
            type = "REG_SZ"
            data = $fontObject
        }
    }

    return [pscustomobject]@{
        resources = @($resources)
        fonts = @($fontRefs)
    }
}

function Resolve-VRootPath {
    param([Parameter(Mandatory)][string]$Spec)

    if ($Spec -notmatch "^([^:]+):(.*)$") {
        throw "Invalid rooted path: $Spec"
    }

    $rootName = $Matches[1]
    $relative = $Matches[2]
    if (-not $Script:Roots.ContainsKey($rootName)) {
        throw "Unknown path root: $rootName"
    }

    return Join-PathParts -Root $Script:Roots[$rootName] -Relative $relative
}

function Resolve-ObjectPath {
    param([Parameter(Mandatory)][string]$Spec)

    if ($Spec -notmatch "^object:(.*)$") {
        throw "Invalid object path: $Spec"
    }

    return Join-PathParts -Root $Script:ObjectRoot -Relative $Matches[1]
}

function Resolve-ActivationPath {
    param([Parameter(Mandatory)][string]$Spec)

    if ($Spec.StartsWith("object:")) {
        return Resolve-ObjectPath $Spec
    }

    return Resolve-VRootPath $Spec
}

function Convert-PackageTargetToObjectSpec {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)]$PackageObjects
    )

    if ($Spec -match "^pkgs\.([^:]+)$") {
        $name = $Matches[1]
        if (-not (Test-MapKey -Map $PackageObjects -Key $name)) {
            throw "Unknown package target: $name"
        }
        return $PackageObjects[$name]
    }

    if ($Spec -match "^pkgs\.([^:]+):(.*)$") {
        $name = $Matches[1]
        $relative = $Matches[2]
        if (-not (Test-MapKey -Map $PackageObjects -Key $name)) {
            throw "Unknown package target: $name"
        }
        return "$($PackageObjects[$name])/$($relative -replace "\\", "/")"
    }

    return $Spec
}

function Test-PackageTargetAvailable {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)]$PackageObjects
    )

    if ($Spec -match "^pkgs\.([^:]+)(:.*)?$") {
        return Test-MapKey -Map $PackageObjects -Key $Matches[1]
    }

    return $true
}

function Set-ManagedLink {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )

    Ensure-Directory (Split-Path -Parent $Link)
    $existing = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            Remove-Item -LiteralPath $Link -Recurse -Force
        } elseif (-not $existing.PSIsContainer) {
            Remove-Item -LiteralPath $Link -Force
        } else {
            throw "Refusing to replace non-link directory: $Link"
        }
    }

    $targetItem = Get-Item -LiteralPath $Target -Force
    if ($targetItem.PSIsContainer) {
        try {
            New-Item -ItemType SymbolicLink -Path $Link -Target $Target | Out-Null
        } catch {
            New-Item -ItemType Junction -Path $Link -Target $Target | Out-Null
        }
    } else {
        try {
            New-Item -ItemType SymbolicLink -Path $Link -Target $Target | Out-Null
        } catch {
            New-HardLinkOrCopy -Path $Link -Target $Target
        }
    }
}

function Set-ManagedShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Program,
        [string]$Cwd
    )

    if (-not $Path.EndsWith(".lnk", [System.StringComparison]::OrdinalIgnoreCase)) {
        $Path = "$Path.lnk"
    }

    Ensure-Directory (Split-Path -Parent $Path)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = $Program
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        $shortcut.WorkingDirectory = $Cwd
    }
    $shortcut.Save()
}

function Convert-RegistryPath {
    param([Parameter(Mandatory)][string]$Key)

    $path = $Key.Substring("reg:".Length)
    $lastSlash = $path.LastIndexOf("/")
    if ($lastSlash -lt 0) {
        throw "Invalid registry resource key: $Key"
    }

    $regPath = $path.Substring(0, $lastSlash) -replace "/", "\"
    $name = $path.Substring($lastSlash + 1)
    if ($regPath.StartsWith("HKCU\")) {
        $regPath = "HKCU:\" + $regPath.Substring(5)
    } elseif ($regPath.StartsWith("HKLM\")) {
        $regPath = "HKLM:\" + $regPath.Substring(5)
    } else {
        throw "Unsupported registry hive in $Key"
    }

    return [pscustomobject]@{ Path = $regPath; Name = $name }
}

function Set-ManagedRegistryValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)][string]$Data
    )

    if ($Type -ne "REG_SZ") {
        throw "Unsupported registry value type: $Type"
    }

    $resolved = Convert-RegistryPath -Key $Key
    $value = if ($Data -match "^(object|user|apps|bin):") {
        Resolve-ActivationPath $Data
    } else {
        $Data
    }

    New-Item -Path $resolved.Path -Force | Out-Null
    New-ItemProperty -Path $resolved.Path -Name $resolved.Name -Value $value -PropertyType String -Force | Out-Null
}

function Remove-ManagedRegistryValue {
    param([Parameter(Mandatory)][string]$Key)

    $resolved = Convert-RegistryPath -Key $Key
    if (Test-Path -LiteralPath $resolved.Path) {
        Remove-ItemProperty -Path $resolved.Path -Name $resolved.Name -ErrorAction SilentlyContinue
    }
}

function Send-FontChanged {
    if (-not ("WindowsSetup.NativeMethods" -as [type])) {
        Add-Type -Namespace WindowsSetup -Name NativeMethods -MemberDefinition @"
            [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
            public static extern System.IntPtr SendMessageTimeout(
                System.IntPtr hWnd,
                uint Msg,
                System.UIntPtr wParam,
                string lParam,
                uint fuFlags,
                uint uTimeout,
                out System.UIntPtr lpdwResult);
"@
    }

    $result = [System.UIntPtr]::Zero
    [WindowsSetup.NativeMethods]::SendMessageTimeout(
        [System.IntPtr]0xffff,
        0x001D,
        [System.UIntPtr]::Zero,
        "Font",
        0x0002,
        5000,
        [ref]$result) | Out-Null
}

function Apply-Resources {
    param([Parameter(Mandatory)]$Resources)

    $fontChanged = $false
    foreach ($resource in @($Resources)) {
        switch ([string]$resource.kind) {
            "link" {
                $key = [string]$resource.key
                if (-not $key.StartsWith("link:")) {
                    throw "Invalid link key: $key"
                }
                $link = Resolve-VRootPath -Spec ($key.Substring(5))
                $target = Resolve-ActivationPath ([string]$resource.target)
                Set-ManagedLink -Link $link -Target $target
            }
            "reg" {
                Set-ManagedRegistryValue -Key ([string]$resource.key) -Type ([string]$resource.type) -Data ([string]$resource.data)
                if ([string]$resource.key -like "reg:HKCU/Software/Microsoft/Windows NT/CurrentVersion/Fonts/*") {
                    $fontChanged = $true
                }
            }
            "shortcut" {
                $key = [string]$resource.key
                if (-not $key.StartsWith("shortcut:")) {
                    throw "Invalid shortcut key: $key"
                }
                $path = Resolve-VRootPath -Spec ($key.Substring("shortcut:".Length))
                $program = Resolve-ActivationPath ([string]$resource.program)
                $cwd = if (Test-Property -Value $resource -Name "cwd") {
                    Resolve-ActivationPath ([string]$resource.cwd)
                } else {
                    $null
                }
                Set-ManagedShortcut -Path $path -Program $program -Cwd $cwd
            }
            default {
                throw "Unsupported resource kind: $($resource.kind)"
            }
        }
    }

    if ($fontChanged) {
        Send-FontChanged
    }
}

function Remove-Resources {
    param([Parameter(Mandatory)]$Keys)

    $fontChanged = $false
    foreach ($key in @($Keys)) {
        if ([string]$key -like "link:*") {
            $path = Resolve-VRootPath -Spec (([string]$key).Substring(5))
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Recurse -Force
            }
        } elseif ([string]$key -like "reg:*") {
            Remove-ManagedRegistryValue -Key ([string]$key)
            if ([string]$key -like "reg:HKCU/Software/Microsoft/Windows NT/CurrentVersion/Fonts/*") {
                $fontChanged = $true
            }
        } elseif ([string]$key -like "shortcut:*") {
            $path = Resolve-VRootPath -Spec (([string]$key).Substring("shortcut:".Length))
            if (-not $path.EndsWith(".lnk", [System.StringComparison]::OrdinalIgnoreCase)) {
                $path = "$path.lnk"
            }
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }

    if ($fontChanged) {
        Send-FontChanged
    }
}

function Get-LockState {
    if (-not (Test-Path -LiteralPath $Script:LockPath)) {
        return [ordered]@{ schema = 1; plan = $null; refs = @() }
    }

    return Get-Json -Path $Script:LockPath
}

function Get-ResourceKeys {
    param([Parameter(Mandatory)]$PlanObject)

    $keys = @()
    foreach ($link in @($PlanObject.resources.links)) {
        $keys += [string]$link.key
    }
    if (Test-Property -Value $PlanObject.resources -Name "shortcuts") {
        foreach ($shortcut in @($PlanObject.resources.shortcuts)) {
            $keys += [string]$shortcut.key
        }
    }
    foreach ($reg in @($PlanObject.resources.regs)) {
        $keys += [string]$reg.key
    }
    return @($keys | Sort-Object -Unique)
}

function Initialize-Workspace {
    Ensure-Command curl.exe
    Ensure-Command tar.exe
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw "Missing required environment variable: APPDATA"
    }
    foreach ($dir in @($Script:ObjectRoot, $Script:PackageRoot, $Script:FontRoot, $Script:DownloadRoot, $Script:StateRoot, $Script:PlanRoot, $Script:ScratchRoot)) {
        Ensure-Directory $dir
    }
    foreach ($root in $Script:Roots.Values) {
        Ensure-Directory $root
    }
}

function Merge-ConfigFragments {
    param([Parameter(Mandatory)]$Fragments)

    $packages = [ordered]@{}
    $links = [ordered]@{}
    $shortcuts = [ordered]@{}

    foreach ($fragment in @($Fragments)) {
        if (Test-Property -Value $fragment -Name "sources") {
            throw "source config must not contain sources"
        }
        if (Test-Property -Value $fragment -Name "packages") {
            foreach ($property in @($fragment.packages.PSObject.Properties | Sort-Object Name)) {
                Assert-PackageKey -Name $property.Name
                $packages[$property.Name] = $property.Value
            }
        }
        if (Test-Property -Value $fragment -Name "links") {
            foreach ($property in @($fragment.links.PSObject.Properties | Sort-Object Name)) {
                $links[$property.Name] = $property.Value
            }
        }
        if (Test-Property -Value $fragment -Name "shortcuts") {
            foreach ($property in @($fragment.shortcuts.PSObject.Properties | Sort-Object Name)) {
                $shortcuts[$property.Name] = $property.Value
            }
        }
    }

    return [pscustomobject]@{
        schema = 2
        packages = [pscustomobject]$packages
        links = [pscustomobject]$links
        shortcuts = [pscustomobject]$shortcuts
    }
}

function Resolve-SourceLocalPackageTarget {
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)][string]$SourceName
    )

    if ($Spec -match "^pkgs\.source($|:)") {
        return $Spec -replace "^pkgs\.source", "pkgs.$SourceName"
    }
    return $Spec
}

function Resolve-SourceLocalConfig {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SourceName
    )

    if (Test-Property -Value $Config -Name "links") {
        foreach ($property in @($Config.links.PSObject.Properties)) {
            $property.Value = Resolve-SourceLocalPackageTarget -Spec ([string]$property.Value) -SourceName $SourceName
        }
    }
    if (Test-Property -Value $Config -Name "shortcuts") {
        foreach ($property in @($Config.shortcuts.PSObject.Properties)) {
            $shortcut = $property.Value
            if (Test-Property -Value $shortcut -Name "program") {
                $shortcut.program = Resolve-SourceLocalPackageTarget -Spec ([string]$shortcut.program) -SourceName $SourceName
            }
            if (Test-Property -Value $shortcut -Name "cwd") {
                $shortcut.cwd = Resolve-SourceLocalPackageTarget -Spec ([string]$shortcut.cwd) -SourceName $SourceName
            }
        }
    }
    return $Config
}

function Get-SourcesFile {
    if (-not (Test-Path -LiteralPath $Script:SourcesPath)) {
        throw "Missing sources file: $Script:SourcesPath"
    }

    $sourcesFile = Get-Json -Path $Script:SourcesPath
    if (-not (Test-Property -Value $sourcesFile -Name "sources")) {
        throw "sources file is missing sources: $Script:SourcesPath"
    }
    return $sourcesFile
}

function Get-SourceDefinitions {
    param([Parameter(Mandatory)]$SourcesFile)

    $defs = [ordered]@{}
    $order = @()
    foreach ($source in @($SourcesFile.sources)) {
        if (-not (Test-Property -Value $source -Name "name")) {
            throw "source entry is missing name"
        }
        $name = [string]$source.name
        Assert-SourceKey -Name $name
        if (Test-MapKey -Map $defs -Key $name) {
            throw "Duplicate source: $name"
        }
        $definition = [ordered]@{}
        $definition["defs"] = if (Test-Property -Value $source -Name "defs") { @($source.defs) } else { @() }
        if (-not (Test-Property -Value $source -Name "install")) {
            throw "Source $name is missing install"
        }
        $definition["install"] = @($source.install)
        $objectDefinition = [pscustomobject]$definition
        Assert-SourceDefinition -Name $name -Definition $objectDefinition
        $defs[$name] = $objectDefinition
        $order += $name
    }
    if ($order.Count -eq 0) {
        throw "sources file must contain at least one source"
    }

    return [pscustomobject]@{
        order = @($order)
        definitions = $defs
    }
}

function Get-ConfigRPath {
    param([Parameter(Mandatory)]$Variables)

    $rpath = if (Test-MapKey -Map $Variables -Key "config-rpath") {
        [string]$Variables["config-rpath"]
    } else {
        "config.spmw.json"
    }
    if ([string]::IsNullOrWhiteSpace($rpath)) {
        throw "config-rpath must not be empty"
    }
    if ($rpath.StartsWith("/") -or $rpath.StartsWith("\")) {
        throw "config-rpath must be relative: $rpath"
    }
    if ($rpath -match "^[A-Za-z]:") {
        throw "config-rpath must not contain a drive letter: $rpath"
    }
    $parts = @($rpath -split "[\\/]+")
    if ($parts -contains "..") {
        throw "config-rpath must not contain .. segment: $rpath"
    }
    return $rpath
}

function Get-SourceConfigPath {
    param([Parameter(Mandatory)]$Variables)

    if (-not (Test-MapKey -Map $Variables -Key "path")) {
        throw "source variables missing path"
    }
    $base = Resolve-ObjectPath "object:$($Variables["path"])"
    $rpath = Get-ConfigRPath -Variables $Variables
    return Join-PathParts -Root $base -Relative $rpath
}

function Invoke-Update {
    Initialize-Workspace

    $packages = [ordered]@{}
    $fragments = @()
    $sourcesFile = Get-SourcesFile
    $sources = Get-SourceDefinitions -SourcesFile $sourcesFile

    foreach ($sourceName in @($sources.order)) {
        $definition = Normalize-Package -Package $sources.definitions[$sourceName]
        $variables = Resolve-Variables -PackageName $sourceName -Package $definition
        $result = Install-RegularPackage -Name $sourceName -Definition $definition -Variables $variables
        $packages[$sourceName] = [ordered]@{
            variables = $variables
        }

        $configPath = Get-SourceConfigPath -Variables $variables
        if (-not (Test-Path -LiteralPath $configPath)) {
            throw "Missing source config for $sourceName`: $configPath"
        }
        $fragments += Resolve-SourceLocalConfig -Config (Get-Json -Path $configPath) -SourceName $sourceName
    }

    $config = Merge-ConfigFragments -Fragments $fragments
    foreach ($packageProperty in @($config.packages.PSObject.Properties | Sort-Object Name)) {
        Assert-PackageKey -Name $packageProperty.Name
        $definition = Normalize-Package -Package $packageProperty.Value
        $variables = Resolve-Variables -PackageName $packageProperty.Name -Package $definition
        $packages[$packageProperty.Name] = [ordered]@{
            variables = $variables
        }
    }

    $nextPlan = [ordered]@{
        schema = 2
        sources = @($sources.order)
        packages = $packages
    }

    Save-JsonAtomic -Value $nextPlan -Path $Script:NextPlanPath
    Write-Host "wrote $Script:NextPlanPath"
    Clear-Scratch
}

function Get-ActionDownload {
    param(
        [Parameter(Mandatory)]$Action,
        [Parameter(Mandatory)]$Variables
    )

    $src = Expand-Template -Text ([string]$Action.src) -Variables $Variables
    $file = if (Test-Property -Value $Action -Name "file") {
        Expand-Template -Text ([string]$Action.file) -Variables $Variables
    } else {
        Get-UrlBaseName -Url $src
    }
    $verify = $null
    if (Test-Property -Value $Action -Name "verify") {
        $verifyValues = [ordered]@{}
        if (Test-Property -Value $Action.verify -Name "sha256") {
            $verifyValues["sha256"] = Resolve-Sha256Spec -Spec $Action.verify.sha256 -Variables $Variables
        }
        $verify = [pscustomobject]$verifyValues
    }

    return Get-Download -Src $src -File $file -Verify $verify
}

function Install-RegularPackage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)]$Variables
    )

    if (-not (Test-MapKey -Map $Variables -Key "path")) {
        throw "Package $Name variables missing path"
    }
    if (-not (Test-MapKey -Map $Variables -Key "variable-digest")) {
        throw "Package $Name variables missing variable-digest"
    }

    $hash = [string]$Variables["variable-digest"]
    $objectSpec = "object:$($Variables["path"])"
    $final = Resolve-ObjectPath $objectSpec
    if ((Test-Path -LiteralPath $final) -and (Test-Path -LiteralPath (Join-Path $final ".READY"))) {
        $metadataPath = Join-Path $final ".spmw\metadata.json"
        $metadataResources = @()
        if (Test-Path -LiteralPath $metadataPath) {
            $metadata = Get-Json -Path $metadataPath
            $metadataResources = @($metadata.resources)
        }
        return [pscustomobject]@{ name = $Name; object = $objectSpec; path = $final; variables = $Variables; resources = @($metadataResources) }
    }

    Write-Host "installing package $Name ..."
    $tmp = Join-Path $Script:PackageRoot ".tmp.$Name.$hash"
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force
    }
    Ensure-Directory $tmp

    $downloads = @()
    $resources = @()
    $fonts = @()
    if (Test-Property -Value $Definition -Name "install") {
        foreach ($action in @($Definition.install)) {
            $download = Get-ActionDownload -Action $action -Variables $Variables
            $downloads += $download
            $strip = if (Test-Property -Value $action -Name "strip") { [int]$action.strip } else { 0 }

            switch ([string]$action.action) {
                "Unpack" {
                    $extract = Join-Path $Script:ScratchRoot "$Name-$hash"
                    Expand-ArchiveWithTar -Archive $download.path -Destination $extract
                    if ($strip -gt 0) {
                        Copy-StrippedExtractedItems -Source $extract -Destination $tmp -Strip $strip
                    } else {
                        Copy-DirectoryContents -Source $extract -Destination $tmp
                    }
                }
                "InstallFonts" {
                    $result = Install-FontsFromArchive -Archive $download.path -PackageName $Name -Strip $strip
                    $resources += @($result.resources)
                    $fonts += @($result.fonts)
                }
                default {
                    throw "Unsupported install action: $($action.action)"
                }
            }
        }
    }

    $metadata = [ordered]@{
        schema = 1
        name = $Name
        variables = $Variables
        downloads = @($downloads | ForEach-Object {
            [ordered]@{ src = $_.src; file = $_.file; object = $_.object; sha256 = $_.sha256; verify = $_.verify }
        })
        resources = @($resources)
        fonts = @($fonts)
    }
    Commit-PackageDirectory -TempPath $tmp -FinalPath $final -Metadata $metadata
    return [pscustomobject]@{ name = $Name; object = $objectSpec; path = $final; variables = $Variables; resources = @($resources) }
}

function Invoke-Install {
    Initialize-Workspace
    if (-not (Test-Path -LiteralPath $Script:NextPlanPath)) {
        throw "Missing next plan: $Script:NextPlanPath"
    }

    $input = Get-Json -Path $Script:NextPlanPath
    if (-not (Test-Property -Value $input -Name "schema") -or [int]$input.schema -ne 2) {
        throw "Unsupported next plan schema: $($input.schema)"
    }
    if (-not (Test-Property -Value $input -Name "sources")) {
        throw "next plan is missing sources"
    }
    if (-not (Test-Property -Value $input -Name "packages")) {
        throw "next plan is missing packages"
    }

    $sourceKeys = @{}
    $fragments = @()
    $packageObjects = [ordered]@{}
    $planPackages = [ordered]@{}
    $resources = @()
    foreach ($sourceName in @($input.sources)) {
        $sourceKey = [string]$sourceName
        Assert-SourceKey -Name $sourceKey
        if ($sourceKeys.ContainsKey($sourceKey)) {
            throw "next plan contains duplicate source: $sourceKey"
        }
        $sourceKeys[$sourceKey] = $true
        if (-not (Test-Property -Value $input.packages -Name $sourceKey)) {
            throw "next plan source is missing from packages: $sourceKey"
        }
        $sourceEntry = Get-MapValue -Map $input.packages -Key $sourceKey
        if (-not (Test-Property -Value $sourceEntry -Name "variables")) {
            throw "next plan source is missing variables: $sourceKey"
        }
        $sourceVariables = ConvertTo-Hashtable -Value $sourceEntry.variables
        $sourcePath = Resolve-ObjectPath "object:$($sourceVariables["path"])"
        if (-not (Test-Path -LiteralPath (Join-Path $sourcePath ".READY"))) {
            throw "source package is not ready: $sourceKey"
        }
        $sourceObject = "object:$($sourceVariables["path"])"
        $packageObjects[$sourceKey] = $sourceObject
        $planPackages[$sourceKey] = [ordered]@{
            object = $sourceObject
            variables = $sourceVariables
        }
        $configPath = Get-SourceConfigPath -Variables $sourceVariables
        if (-not (Test-Path -LiteralPath $configPath)) {
            throw "Missing source config for $sourceKey`: $configPath"
        }
        $fragments += Resolve-SourceLocalConfig -Config (Get-Json -Path $configPath) -SourceName $sourceKey
    }
    $config = Merge-ConfigFragments -Fragments $fragments

    foreach ($packageProperty in @($input.packages.PSObject.Properties | Sort-Object Name)) {
        $name = $packageProperty.Name
        Assert-PackageKey -Name $name -AllowSource
        if ($sourceKeys.ContainsKey($name)) {
            continue
        }
        $entry = $packageProperty.Value
        if (-not (Test-Property -Value $config.packages -Name $name)) {
            throw "next plan package is missing from config: $name"
        }

        $definition = Normalize-Package -Package (Get-MapValue -Map $config.packages -Key $name)
        $variables = ConvertTo-Hashtable -Value $entry.variables
        $result = Install-RegularPackage -Name $name -Definition $definition -Variables $variables
        $packageObjects[$name] = $result.object
        $planPackages[$name] = [ordered]@{
            object = $result.object
            variables = $variables
        }
        $resources += @($result.resources)
    }

    $inputLinks = if (Test-Property -Value $config -Name "links") { $config.links } else { [pscustomobject]@{} }
    $links = @()
    foreach ($link in @($inputLinks.PSObject.Properties | Sort-Object Name)) {
        if (-not (Test-PackageTargetAvailable -Spec ([string]$link.Value) -PackageObjects $packageObjects)) {
            Write-Warning "Skipping link $($link.Name): target package is not in next plan"
            continue
        }

        $links += [pscustomobject]@{
            kind = "link"
            key = "link:$($link.Name)"
            target = Convert-PackageTargetToObjectSpec -Spec ([string]$link.Value) -PackageObjects $packageObjects
        }
    }

    $shortcuts = @()
    if (Test-Property -Value $config -Name "shortcuts") {
        foreach ($shortcut in @($config.shortcuts.PSObject.Properties | Sort-Object Name)) {
            $shortcutValue = $shortcut.Value
            if (-not (Test-PackageTargetAvailable -Spec ([string]$shortcutValue.program) -PackageObjects $packageObjects)) {
                Write-Warning "Skipping shortcut $($shortcut.Name): program package is not in next plan"
                continue
            }
            if ((Test-Property -Value $shortcutValue -Name "cwd") -and
                -not (Test-PackageTargetAvailable -Spec ([string]$shortcutValue.cwd) -PackageObjects $packageObjects)) {
                Write-Warning "Skipping shortcut $($shortcut.Name): cwd package is not in next plan"
                continue
            }

            $shortcutResource = [ordered]@{
                kind = "shortcut"
                key = "shortcut:$($shortcut.Name)"
                program = Convert-PackageTargetToObjectSpec -Spec ([string]$shortcutValue.program) -PackageObjects $packageObjects
            }
            if (Test-Property -Value $shortcutValue -Name "cwd") {
                $shortcutResource["cwd"] = Convert-PackageTargetToObjectSpec -Spec ([string]$shortcutValue.cwd) -PackageObjects $packageObjects
            }
            $shortcuts += [pscustomobject]$shortcutResource
        }
    }

    $planBody = [ordered]@{
        schema = 2
        plan = [ordered]@{
            packages = $planPackages
        }
        resources = [ordered]@{
            links = @($links)
            shortcuts = @($shortcuts)
            regs = @($resources | Where-Object { [string]$_.kind -eq "reg" })
        }
    }
    $id = (Get-TextSha256 -Text (ConvertTo-StableJson $planBody)).Substring(0, 16)
    $planObject = [ordered]@{
        schema = 2
        id = $id
        plan = $planBody.plan
        resources = $planBody.resources
    }

    $planPath = Join-Path $Script:PlanRoot "$id.json"
    Save-JsonAtomic -Value $planObject -Path $planPath
    Write-Host "wrote $planPath"

    if (-not $Prepare) {
        Invoke-ActivatePlan -PlanPath $planPath
    }

    Clear-Scratch
    return [pscustomobject]@{
        id = $id
        path = $planPath
    }
}

function Invoke-ActivatePlan {
    param([Parameter(Mandatory)][string]$PlanPath)

    Initialize-Workspace
    if (-not (Test-Path -LiteralPath $PlanPath)) {
        throw "Missing plan: $PlanPath"
    }

    $planObject = Get-Json -Path $PlanPath
    $allResources = @($planObject.resources.links)
    if (Test-Property -Value $planObject.resources -Name "shortcuts") {
        $allResources += @($planObject.resources.shortcuts)
    }
    $allResources += @($planObject.resources.regs)
    Apply-Resources -Resources $allResources

    $lock = Get-LockState
    $refs = @(@($lock.refs) + (Get-ResourceKeys -PlanObject $planObject) | Sort-Object -Unique)
    $newLock = [ordered]@{
        schema = 1
        plan = [string]$planObject.id
        refs = $refs
    }
    Save-JsonAtomic -Value $newLock -Path $Script:LockPath
    Write-Host "activated plan $($planObject.id)"
}

function Invoke-Prune {
    Initialize-Workspace
    $lock = Get-LockState
    if (-not $lock.plan) {
        Write-Host "no active plan"
        return
    }

    $currentPlanPath = Join-Path $Script:PlanRoot "$($lock.plan).json"
    if (-not (Test-Path -LiteralPath $currentPlanPath)) {
        throw "Active plan file is missing: $currentPlanPath"
    }
    $currentPlan = Get-Json -Path $currentPlanPath
    $wanted = @{}
    foreach ($key in Get-ResourceKeys -PlanObject $currentPlan) {
        $wanted[$key] = $true
    }

    $obsolete = @($lock.refs | Where-Object { -not $wanted.ContainsKey([string]$_) })
    if ($obsolete.Count -gt 0) {
        Remove-Resources -Keys $obsolete
    }
    $newRefs = @($lock.refs | Where-Object { $wanted.ContainsKey([string]$_) } | Sort-Object -Unique)
    Save-JsonAtomic -Value ([ordered]@{ schema = 1; plan = $lock.plan; refs = $newRefs }) -Path $Script:LockPath

    foreach ($planFile in @(Get-ChildItem -LiteralPath $Script:PlanRoot -Filter "*.json" -File)) {
        if ($planFile.FullName -ne $currentPlanPath) {
            Remove-Item -LiteralPath $planFile.FullName -Force
        }
    }

    $reachablePkgs = @{}
    foreach ($package in @($currentPlan.plan.packages.PSObject.Properties)) {
        $reachablePkgs[[string]$package.Value.object] = $true
    }

    foreach ($pkgDir in @(Get-ChildItem -LiteralPath $Script:PackageRoot -Directory)) {
        if ($pkgDir.Name.StartsWith(".tmp.")) {
            Remove-Item -LiteralPath $pkgDir.FullName -Recurse -Force
            continue
        }
        $spec = "object:pkgs/$($pkgDir.Name)"
        if ($Pkgs -and -not $reachablePkgs.ContainsKey($spec)) {
            Remove-Item -LiteralPath $pkgDir.FullName -Recurse -Force
        }
    }

    if ($Fonts -or $Cache) {
        $reachableFonts = @{}
        $reachableDownloads = @{}
        foreach ($spec in $reachablePkgs.Keys) {
            $pkgPath = Resolve-ObjectPath $spec
            $metadataPath = Join-Path $pkgPath ".spmw\metadata.json"
            if (Test-Path -LiteralPath $metadataPath) {
                $metadata = Get-Json -Path $metadataPath
                foreach ($font in @($metadata.fonts)) {
                    $reachableFonts[[string]$font] = $true
                }
                foreach ($download in @($metadata.downloads)) {
                    $reachableDownloads[[string]$download.object] = $true
                }
            }
        }

        if ($Fonts) {
            foreach ($fontFile in @(Get-ChildItem -LiteralPath $Script:FontRoot -File)) {
                $spec = "object:fonts/$($fontFile.Name)"
                if (-not $reachableFonts.ContainsKey($spec)) {
                    Remove-Item -LiteralPath $fontFile.FullName -Force
                }
            }
        }

        if ($Cache) {
            foreach ($downloadFile in @(Get-ChildItem -LiteralPath $Script:DownloadRoot -File)) {
                $spec = "object:dl/$($downloadFile.Name)"
                if (-not $reachableDownloads.ContainsKey($spec)) {
                    Remove-Item -LiteralPath $downloadFile.FullName -Force
                }
            }
        }
    }

    Write-Host "prune complete"
}

function Split-ChannelSpec {
    param([Parameter(Mandatory)][string]$Spec)

    $uri = [System.Uri]::new($Spec)
    if ($uri.Scheme -ne "http" -and $uri.Scheme -ne "https") {
        throw "Channel source must use http or https: $Spec"
    }

    $builder = [System.UriBuilder]::new($uri)
    $fragment = $builder.Fragment
    $builder.Fragment = ""
    $channelUrl = $builder.Uri.AbsoluteUri
    $configRPath = $null
    if (-not [string]::IsNullOrEmpty($fragment)) {
        $configRPath = [System.Uri]::UnescapeDataString($fragment.TrimStart("#"))
        if ([string]::IsNullOrWhiteSpace($configRPath)) {
            throw "config-rpath fragment must not be empty: $Spec"
        }
    }

    return [pscustomobject]@{
        channelUrl = $channelUrl
        configRPath = $configRPath
    }
}

function New-ChannelSourceDefinition {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Spec
    )

    $channel = Split-ChannelSpec -Spec $Spec
    $defs = @(
        [ordered]@{
            "tarball-url" = [ordered]@{
                src = $channel.channelUrl
                ty = "UrlReference"
            }
        }
    )
    if ($channel.configRPath) {
        $defs += [ordered]@{
            "config-rpath" = $channel.configRPath
        }
    }

    return [ordered]@{
        name = "source.$Name"
        defs = $defs
        install = @(
            [ordered]@{
                action = "Unpack"
                file = "$Name-<variable-digest>.tar.gz"
                src = "<tarball-url>"
                strip = 1
            }
        )
    }
}

function New-SourceDefinition {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Spec
    )

    if (-not (Test-SourceName -Name $Name)) {
        throw "Invalid source name: $Name"
    }
    if ($Spec -match "^https?://") {
        return New-ChannelSourceDefinition -Name $Name -Spec $Spec
    }
    if ($Spec -notmatch "^gh-src:([^/]+)/([^/]+)/([^/]+)$") {
        throw "Unsupported source spec: $Spec"
    }

    $owner = $Matches[1]
    $repo = $Matches[2]
    $branch = $Matches[3]
    $sourceName = "source.$Name"
    return [ordered]@{
        name = $sourceName
        defs = @(
            [ordered]@{
                commit = [ordered]@{
                    src = "https://github.com/$owner/$repo/commits/$branch.atom"
                    ty = "CommitFromGithubAtom"
                }
            }
        )
        install = @(
            [ordered]@{
                action = "Unpack"
                file = "$repo-<commit>.tar.gz"
                src = "https://github.com/$owner/$repo/archive/<commit>.tar.gz"
                strip = 1
            }
        )
    }
}

function Invoke-SourceAdd {
    Initialize-Workspace

    if ([string]::IsNullOrWhiteSpace($SourceName) -or [string]::IsNullOrWhiteSpace($SourceSpec)) {
        throw "usage: spmw-cli.ps1 source add <name> gh-src:<OWNER>/<REPO>/<BRANCH>|http(s)://<CHANNEL.txt>[#<config-rpath>]"
    }

    $newSource = New-SourceDefinition -Name $SourceName -Spec $SourceSpec
    $sourceKey = [string]$newSource.name
    $sources = @()
    if (Test-Path -LiteralPath $Script:SourcesPath) {
        $existing = Get-Json -Path $Script:SourcesPath
        if (Test-Property -Value $existing -Name "sources") {
            $sources = @($existing.sources)
        }
    }

    $replaced = $false
    $updated = @()
    foreach ($source in @($sources)) {
        if ((Test-Property -Value $source -Name "name") -and [string]$source.name -eq $sourceKey) {
            $updated += [pscustomobject]$newSource
            $replaced = $true
        } else {
            $updated += $source
        }
    }
    if (-not $replaced) {
        $updated += [pscustomobject]$newSource
    }

    $sourcesFile = [ordered]@{
        schema = 1
        sources = @($updated)
    }
    Save-JsonAtomic -Value $sourcesFile -Path $Script:SourcesPath
    if ($replaced) {
        Write-Host "updated $sourceKey in $Script:SourcesPath"
    } else {
        Write-Host "added $sourceKey to $Script:SourcesPath"
    }
}

function Invoke-Source {
    switch ($SourceCommand) {
        "add" { Invoke-SourceAdd }
        default { throw "usage: spmw-cli.ps1 source add <name> gh-src:<OWNER>/<REPO>/<BRANCH>|http(s)://<CHANNEL.txt>[#<config-rpath>]" }
    }
}

if ($Help -or [string]::IsNullOrWhiteSpace($Command)) {
    Show-Help
    exit 0
}

switch ($Command) {
    "update" { Invoke-Update }
    "install" { Invoke-Install }
    "prune" { Invoke-Prune }
    "source" { Invoke-Source }
}
