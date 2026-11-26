[CmdletBinding()]
param(
    [ValidateSet('rt', 'raster', 'both')]
    [string]$Pack = 'rt',

    [string]$Tag = 'latest',

    [string]$Instance = '',

    [string]$TargetDir = '',

    [switch]$Local,

    [string]$Repo = 'scomicon/Zenith'
)

$ErrorActionPreference = 'Stop'

# Ensure TLS 1.2+ on Windows PowerShell 5.1 when downloading from GitHub.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
}

function Resolve-HorizonDir {
    $isWin = ($env:OS -eq 'Windows_NT') -or ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows)
    if ($isWin) {
        $appData = if ($env:APPDATA) { $env:APPDATA } else { Join-Path $HOME 'AppData\Roaming' }
        return (Join-Path $appData 'horizon')
    }
    if ($IsMacOS) {
        return (Join-Path $HOME 'Library/Application Support/horizon')
    }
    $xdgData = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
    return (Join-Path $xdgData 'horizon')
}

function Resolve-ShaderpacksDir {
    param(
        [string]$HorizonDir,
        [string]$InstanceName,
        [string]$ExplicitDir
    )
    if (-not [string]::IsNullOrWhiteSpace($ExplicitDir)) {
        return [System.IO.Path]::GetFullPath($ExplicitDir)
    }
    if (-not [string]::IsNullOrWhiteSpace($InstanceName) -and $InstanceName -ne 'horizon') {
        return (Join-Path (Join-Path (Join-Path $HorizonDir 'instances') $InstanceName) 'shaderpacks')
    }
    return (Join-Path $HorizonDir 'shaderpacks')
}

function Find-LocalRepo {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $parent = Split-Path -Parent $PSScriptRoot
        if ($parent) { $candidates.Add($parent) }
    }
    if ($Local) {
        $candidates.Add((Get-Location).Path)
    }
    foreach ($dir in $candidates) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $hasPack = Test-Path (Join-Path $dir 'pack\zenith\horizon-shaders.toml')
        $hasRt = Test-Path (Join-Path $dir 'variants\zenith-rt')
        if ($hasPack -and $hasRt) {
            return [System.IO.Path]::GetFullPath($dir)
        }
    }
    return $null
}

function Move-ToBackup {
    param(
        [string]$SourcePath,
        [string]$BackupDir
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) { return $null }
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $leaf = Split-Path -Leaf $SourcePath
    $dest = Join-Path $BackupDir $leaf
    $n = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $BackupDir "$leaf.$n"
        $n++
    }
    Move-Item -LiteralPath $SourcePath -Destination $dest
    return $dest
}

function Get-GitHubRelease {
    param(
        [string]$RepoSlug,
        [string]$ReleaseTag
    )
    $headers = @{
        'User-Agent' = 'Zenith-Quick-Installer/1.0'
        'Accept'     = 'application/vnd.github+json'
    }
    $apiUrl = if ($ReleaseTag -eq 'latest') {
        "https://api.github.com/repos/$RepoSlug/releases/latest"
    } else {
        "https://api.github.com/repos/$RepoSlug/releases/tags/$ReleaseTag"
    }
    return Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
}

function Install-RemoteHshader {
    param(
        [object]$Release,
        [string]$AssetPattern,
        [string]$PackLabel,
        [string]$TempDir
    )
    $asset = $Release.assets | Where-Object { $_.name -match $AssetPattern } | Select-Object -First 1
    if (-not $asset) {
        throw "Release '$($Release.tag_name)' has no asset matching '$AssetPattern' for $PackLabel."
    }

    $destTemp = Join-Path $TempDir $asset.name
    Write-Host "Downloading $($asset.name) from release $($Release.tag_name)..." -ForegroundColor Cyan
    $headers = @{ 'User-Agent' = 'Zenith-Quick-Installer/1.0' }
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $destTemp -Headers $headers -UseBasicParsing

    $bytes = [System.IO.File]::ReadAllBytes($destTemp)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
        throw "Downloaded file '$($asset.name)' is not a valid .hshader archive."
    }

    $actualHash = (Get-FileHash -LiteralPath $destTemp -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($asset.digest -and ($asset.digest -match '^sha256:([0-9a-fA-F]{64})$')) {
        $expectedHash = $Matches[1].ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw "SHA-256 mismatch for $($asset.name): expected $expectedHash, got $actualHash"
        }
    }

    return @{
        Kind       = 'file'
        Name       = $asset.name
        TempPath   = $destTemp
        Sha256     = $actualHash
        ReleaseTag = $Release.tag_name
        Label      = $PackLabel
    }
}

function Stage-LocalPack {
    param(
        [string]$RepoRoot,
        [ValidateSet('rt', 'raster')]
        [string]$Which,
        [string]$TempDir
    )
    if ($Which -eq 'raster') {
        $src = Join-Path $RepoRoot 'pack\zenith'
        if (-not (Test-Path (Join-Path $src 'horizon-shaders.toml'))) {
            throw "Local Zenith raster pack not found at $src"
        }
        $dst = Join-Path $TempDir 'zenith'
        Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
        return @{
            Kind     = 'dir'
            Name     = 'zenith'
            TempPath = $dst
            Label    = 'Zenith'
        }
    }

    $prebuilt = Join-Path $RepoRoot 'outputs\zenith-rt\zenith_rt'
    $dst = Join-Path $TempDir 'zenith_rt'
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) {
        $buildRel = ".tmp-zenith-rt-install-$PID"
        $buildDir = Join-Path (Join-Path $RepoRoot 'outputs') $buildRel
        $buildPack = Join-Path $buildDir 'zenith_rt'
        try {
            New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
            Write-Host "Building Zenith RT locally with Node.js..." -ForegroundColor Cyan
            & $nodeCmd.Source (Join-Path $RepoRoot 'tools\build-zenith-rt.mjs') $buildPack | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path (Join-Path $buildPack 'horizon-shaders.toml'))) {
                throw "tools/build-zenith-rt.mjs failed with exit code $LASTEXITCODE"
            }
            Copy-Item -LiteralPath $buildPack -Destination $dst -Recurse -Force
        } finally {
            if (Test-Path -LiteralPath $buildDir) {
                Remove-Item -LiteralPath $buildDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } elseif (Test-Path (Join-Path $prebuilt 'horizon-shaders.toml')) {
        Write-Host "Using existing local build at $prebuilt..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $prebuilt -Destination $dst -Recurse -Force
    } else {
        throw "Cannot build Zenith RT locally: Node.js was not found and $prebuilt does not exist."
    }

    return @{
        Kind     = 'dir'
        Name     = 'zenith_rt'
        TempPath = $dst
        Label    = 'Zenith RT'
    }
}

$horizonDir = Resolve-HorizonDir
$shaderpacksDir = Resolve-ShaderpacksDir -HorizonDir $horizonDir -InstanceName $Instance -ExplicitDir $TargetDir
$localRepo = Find-LocalRepo
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path (Join-Path $horizonDir '.zenith-install-backups') $timestamp
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "zenith-install-$PID-$timestamp"

New-Item -ItemType Directory -Force -Path $shaderpacksDir | Out-Null
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$staged = New-Object System.Collections.Generic.List[hashtable]
$backedUp = New-Object System.Collections.Generic.List[string]

try {
    $wantRt = ($Pack -eq 'rt') -or ($Pack -eq 'both')
    $wantRaster = ($Pack -eq 'raster') -or ($Pack -eq 'both')

    $useLocal = [bool]$Local
    $release = $null

    if (-not $useLocal) {
        try {
            $release = Get-GitHubRelease -RepoSlug $Repo -ReleaseTag $Tag
            if ($wantRt) {
                $staged.Add((Install-RemoteHshader -Release $release -AssetPattern '^zenith_rt-.*\.hshader$' -PackLabel 'Zenith RT' -TempDir $tempDir))
            }
            if ($wantRaster) {
                $staged.Add((Install-RemoteHshader -Release $release -AssetPattern '^zenith-[0-9].*\.hshader$' -PackLabel 'Zenith' -TempDir $tempDir))
            }
        } catch {
            if ($localRepo) {
                Write-Warning "Remote release install failed ($($_.Exception.Message)). Falling back to local repository at $localRepo."
                $staged.Clear()
                $useLocal = $true
            } else {
                throw
            }
        }
    }

    if ($useLocal) {
        if (-not $localRepo) {
            throw "Local mode requested, but no Zenith repository (pack/zenith + variants/zenith-rt) was found."
        }
        if ($wantRt) {
            $staged.Add((Stage-LocalPack -RepoRoot $localRepo -Which 'rt' -TempDir $tempDir))
        }
        if ($wantRaster) {
            $staged.Add((Stage-LocalPack -RepoRoot $localRepo -Which 'raster' -TempDir $tempDir))
        }
    }

    # Back up any misplaced full-repository extractions directly inside shaderpacks/
    # (for example, unpacking Zenith-main.zip into shaderpacks/ hides zenith_rt).
    Get-ChildItem -LiteralPath $shaderpacksDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $dirPath = $_.FullName
        $hasRootManifest = Test-Path (Join-Path $dirPath 'horizon-shaders.toml')
        $hasNestedRepo = Test-Path (Join-Path $dirPath 'pack\zenith\horizon-shaders.toml')
        if (-not $hasRootManifest -and $hasNestedRepo) {
            $moved = Move-ToBackup -SourcePath $dirPath -BackupDir $backupDir
            if ($moved) { $backedUp.Add("$dirPath -> $moved") }
        }
    }

    foreach ($item in $staged) {
        $patterns = if ($item.Label -eq 'Zenith RT') {
            @('zenith_rt', 'zenith_rt*.hshader')
        } else {
            @('zenith', 'zenith-*.hshader')
        }
        foreach ($pat in $patterns) {
            Get-ChildItem -LiteralPath $shaderpacksDir -Filter $pat -ErrorAction SilentlyContinue | ForEach-Object {
                $moved = Move-ToBackup -SourcePath $_.FullName -BackupDir $backupDir
                if ($moved) { $backedUp.Add("$($_.FullName) -> $moved") }
            }
        }

        $dest = Join-Path $shaderpacksDir $item.Name
        if ($item.Kind -eq 'file') {
            Copy-Item -LiteralPath $item.TempPath -Destination $dest -Force
        } else {
            Copy-Item -LiteralPath $item.TempPath -Destination $dest -Recurse -Force
        }
        $item.InstalledPath = $dest
    }
} finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host "Target directory: $shaderpacksDir"
foreach ($item in $staged) {
    $hashNote = if ($item.Sha256) { " (sha256: $($item.Sha256.Substring(0, 12))...)" } else { "" }
    Write-Host "  - $($item.Label): $($item.InstalledPath)$hashNote" -ForegroundColor White
}
if ($backedUp.Count -gt 0) {
    Write-Host ""
    Write-Host "Previous files / misplaced source folders moved to backup:" -ForegroundColor Yellow
    foreach ($entry in $backedUp) {
        Write-Host "  $entry" -ForegroundColor DarkGray
    }
}
Write-Host ""
Write-Host "Next steps in Horizon:" -ForegroundColor Cyan
Write-Host "  1. Open Shader Packs and select Zenith RT (or Zenith)."
if ($Pack -eq 'rt' -or $Pack -eq 'both') {
    Write-Host "  2. Restart Horizon after selecting Zenith RT so hardware ray queries are enabled."
    Write-Host "  3. Adjust RT quality under Effects -> Ray Tracing (Reflections / Reflections + Shadows / Full RT)."
}
