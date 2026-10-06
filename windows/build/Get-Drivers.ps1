<#
.SYNOPSIS
  Downloads (pinned URL + sha256) and extracts the driver packages for one target from
  windows\drivers.json, then reports what is inside: INF count per device class, and which INFs match
  the target's GPU (hardware IDs + DriverVer). CI runner only.

  -AllowUnpinned  (probe runs) accept an entry with an empty sha256 and print its hash for pinning.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$WorkDir = 'C:\zb\drivers',
    [switch]$AllowUnpinned,
    [switch]$KeepDownloads
)
. (Join-Path $PSScriptRoot 'common.ps1')
$cfg = (Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'drivers.json') | ConvertFrom-Json).targets.$Target
if (-not $cfg) { throw "unknown target $Target" }

function Read-Inf([string]$Path) {
    $text = [IO.File]::ReadAllText($Path)   # detects UTF-16/UTF-8 BOMs (many vendor INFs are UTF-16LE)
    $class = ([regex]::Match($text, '(?im)^\s*Class\s*=\s*"?([A-Za-z0-9_]+)')).Groups[1].Value
    $ver = ([regex]::Match($text, '(?im)^\s*DriverVer\s*=\s*([^\r\n;]+)')).Groups[1].Value.Trim()
    [pscustomobject]@{ Path = $Path; Class = $class; DriverVer = $ver; Text = $text }
}

function Expand-Package($pkg, [string]$exe, [string]$dest) {
    if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    switch ($pkg.extract) {
        '7z' {
            $7z = Get-SevenZip
            Invoke-Native $7z @('x', '-y', '-bso0', '-bsp0', "-o$dest", $exe) | Out-Null
        }
        'hp-softpaq' {
            # HP: "spNNNNN.exe /s /e /f <dir>" = silent extract only (no install)
            $p = Start-Process -FilePath $exe -ArgumentList @('/s', '/e', '/f', "`"$dest`"") -PassThru -Wait
            Write-Host "  HP SoftPaq extractor exit $($p.ExitCode)"
        }
        'inno' {
            # Lenovo: "<pack>.exe /VERYSILENT /DIR=<dir> /EXTRACT=YES" = extract only (Lenovo package descriptors)
            $p = Start-Process -FilePath $exe -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$dest`"", '/EXTRACT="YES"') -PassThru -Wait
            Write-Host "  Inno extractor exit $($p.ExitCode)"
        }
        default { throw "unknown extract method $($pkg.extract)" }
    }
    $n = @(Get-ChildItem -Recurse -File -Path $dest -Filter *.inf -ErrorAction SilentlyContinue).Count
    if ($n -eq 0) { throw "no .inf files after extracting $($pkg.id) with method $($pkg.extract)" }
    return $n
}

$dl = Join-Path $WorkDir 'dl'
$root = Join-Path $WorkDir $Target
New-Item -ItemType Directory -Force -Path $dl, $root | Out-Null
$report = [ordered]@{ target = $Target; title = $cfg.title; packages = @(); gpu = @() }
$allInfs = @()

foreach ($pkg in $cfg.packages) {
    Write-Step "$($pkg.id): $($pkg.name)"
    $file = Join-Path $dl (([uri]$pkg.url).Segments[-1])
    $headers = @{}
    if ($pkg.PSObject.Properties['headers']) { foreach ($p in $pkg.headers.PSObject.Properties) { $headers[$p.Name] = $p.Value } }
    $hash = Invoke-PinnedDownload -Url $pkg.url -Dest $file -Sha256 $pkg.sha256 -Bytes $pkg.bytes -Headers $headers -AllowUnpinned:$AllowUnpinned
    $dest = Join-Path $root $pkg.id
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = Expand-Package $pkg $file $dest
    $size = (Get-ChildItem -Recurse -File $dest | Measure-Object -Property Length -Sum).Sum
    Write-Host ("  extracted {0} INFs, {1:N2} GB in {2:N0}s -> {3}" -f $n, ($size / 1GB), $sw.Elapsed.TotalSeconds, $dest)
    if (-not $KeepDownloads) { Remove-Item -Force $file }

    $injectRoots = @($dest)
    if ($pkg.PSObject.Properties['inject_dirs']) {
        $injectRoots = @()
        foreach ($d in $pkg.inject_dirs) {
            $hit = @(Get-ChildItem -Recurse -Directory -Path $dest | Where-Object { $_.FullName.EndsWith('\' + $d, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
            if ($hit.Count) { $injectRoots += $hit[0].FullName } else { Write-Warning "  inject dir '$d' not found in $($pkg.id)" }
        }
        if (-not $injectRoots) { throw "none of $($pkg.inject_dirs -join ', ') found in $($pkg.id)" }
    }
    $infs = @($injectRoots | ForEach-Object { Get-ChildItem -Recurse -File -Path $_ -Filter *.inf } | ForEach-Object { Read-Inf $_.FullName })
    $classes = $infs | Group-Object Class | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ("  INFs to inject: {0} ({1})" -f $infs.Count, ($classes -join ', '))
    $allInfs += @($infs | ForEach-Object { $_ | Add-Member -NotePropertyName Package -NotePropertyValue $pkg.id -PassThru })
    $report.packages += [ordered]@{
        id = $pkg.id; vendor = $pkg.vendor; name = $pkg.name; version = $pkg.version; url = $pkg.url; sha256 = $hash
        extracted_gb = [math]::Round($size / 1GB, 2)
        inf_count = $infs.Count; classes = $classes; inject_roots = $injectRoots
        inject_install = [bool]$pkg.inject_install
        inject_boot = [bool]($pkg.PSObject.Properties['inject_boot'] -and $pkg.inject_boot)
        boot_classes = $(if ($pkg.PSObject.Properties['boot_classes']) { @($pkg.boot_classes) } else { @() })
    }
}

Write-Step "GPU INFs matching $($cfg.gpu_device_ids -join ', ')"
foreach ($id in $cfg.gpu_device_ids) {
    $rx = 'PCI\\' + [regex]::Escape($id) + '[^\s,;"]*'
    foreach ($inf in $allInfs) {
        $ids = @([regex]::Matches($inf.Text, $rx, 'IgnoreCase') | ForEach-Object { $_.Value.ToUpperInvariant() } | Sort-Object -Unique)
        if (-not $ids.Count) { continue }
        Write-Host ("  {0} | {1} | class {2} | DriverVer {3} | {4}" -f $inf.Package, (Split-Path -Leaf $inf.Path), $inf.Class, $inf.DriverVer, ($ids -join ' '))
        $report.gpu += [ordered]@{ device = $id; package = $inf.Package; inf = $inf.Path.Substring($root.Length + 1); class = $inf.Class; driver_ver = $inf.DriverVer; hardware_ids = $ids }
    }
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'drivers-report.json') -Encoding utf8
$rows = $report.packages | ForEach-Object { "| $($_.vendor) | $($_.name) | $($_.version) | $($_.inf_count) | ``$($_.sha256)`` |" }
$gpuRows = $report.gpu | ForEach-Object { "| $($_.package) | $(Split-Path -Leaf $_.inf) | $($_.driver_ver) | $($_.hardware_ids -join ' ') |" }
Write-Summary (@("### Drivers: $Target", '', '| Vendor | Package | Version | INFs | sha256 |', '|---|---|---|---|---|') + $rows +
    @('', '| GPU package | INF | DriverVer | Hardware IDs |', '|---|---|---|---|') + $gpuRows -join "`n")
Show-Disk 'after drivers'
