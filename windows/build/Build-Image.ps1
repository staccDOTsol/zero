<#
.SYNOPSIS
  Builds the Zero (leCore+) Windows 11 Pro install ISO for one target. CI runner only.

  1. copies the official Microsoft ISO's files, exports ONLY the "Windows 11 Pro" edition
  2. offline-services that install.wim with DISM: injects the target's OEM driver pack + current GPU
     driver (Get-Drivers.ps1 output), pre-applies the zero-egress lockdown to the image's hives
     (lockdown.ps1 -OfflineImage), removes Copilot/Recall/cloud-only apps, and stages the stack
     installer + SetupComplete.cmd under C:\Windows\Setup\Scripts
  3. injects storage drivers into boot.wim (Windows Setup) so the installer sees the NVMe disk
  4. re-exports install.wim (max compression) and splits it into install.swm parts < 4 GB (FAT32 USB)
  5. adds autounattend.xml, rebuilds a UEFI+BIOS bootable ISO with oscdimg, and verifies it
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$Iso,
    [Parameter(Mandatory = $true)][string]$StackZip,
    [Parameter(Mandatory = $true)][string]$DriversRoot,
    [string]$Oscdimg = $env:OSCDIMG,
    [string]$WorkDir = 'C:\zb\img',
    [string]$OutDir = 'C:\zb\out',
    [string]$Tag = 'local'
)
. (Join-Path $PSScriptRoot 'common.ps1')
$winDir = Split-Path -Parent $PSScriptRoot
$cfg = (Get-Content -Raw -LiteralPath (Join-Path $winDir 'drivers.json') | ConvertFrom-Json).targets.$Target
if (-not $cfg) { throw "unknown target $Target" }
$drv = Get-Content -Raw -LiteralPath (Join-Path $DriversRoot 'drivers-report.json') | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $Oscdimg)) { throw "oscdimg not found: $Oscdimg" }

$isoDir = Join-Path $WorkDir 'iso'
$mount = Join-Path $WorkDir 'mount'
$bootMount = Join-Path $WorkDir 'bootmount'
$proWim = Join-Path $WorkDir 'pro.wim'
$finalWim = Join-Path $WorkDir 'install.wim'
foreach ($d in $WorkDir, $OutDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
foreach ($d in $isoDir, $mount, $bootMount) { if (Test-Path $d) { Remove-Item -Recurse -Force $d }; New-Item -ItemType Directory -Force -Path $d | Out-Null }
Show-Disk 'start'
$t0 = Get-Date
function Lap([string]$m) { Write-Host ("  [{0:hh\:mm\:ss}] {1}" -f ((Get-Date) - $t0), $m) }

Write-Step 'Copy the ISO files'
$img = Mount-DiskImage -ImagePath $Iso -PassThru
try {
    $src = "$(($img | Get-Volume).DriveLetter):\"
    & robocopy.exe $src $isoDir /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
} finally { Dismount-DiskImage -ImagePath $Iso | Out-Null }
Get-ChildItem -Recurse -File $isoDir | Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
Lap 'copied'

Write-Step 'Export Windows 11 Pro only'
$srcWim = @(Get-ChildItem (Join-Path $isoDir 'sources') -File | Where-Object { $_.Name -in 'install.wim', 'install.esd' })[0].FullName
$pro = Get-WindowsImage -ImagePath $srcWim | Where-Object { $_.ImageName -eq 'Windows 11 Pro' }
if (-not $pro) { throw "no 'Windows 11 Pro' index in $srcWim" }
if (Test-Path $proWim) { Remove-Item -Force $proWim }
# fast compression here: this file is re-exported with max compression after servicing
Export-WindowsImage -SourceImagePath $srcWim -SourceIndex $pro.ImageIndex -DestinationImagePath $proWim -CompressionType fast | Out-Null
Remove-Item -Force $srcWim
$info = Get-WindowsImage -ImagePath $proWim -Index 1
$winVer = "$($info.Version)"
Write-Host ("  {0} {1} (index {2} of the Microsoft image), {3:N2} GB" -f $info.ImageName, $winVer, $pro.ImageIndex, ((Get-Item $proWim).Length / 1GB))
Lap 'exported'

Write-Step 'Mount install image'
Mount-WindowsImage -ImagePath $proWim -Index 1 -Path $mount | Out-Null
$saved = $false
try {
    Write-Step 'Inject drivers into install.wim'
    $added = @()
    foreach ($p in $drv.packages) {
        if (-not $p.inject_install) { continue }
        foreach ($r in $p.inject_roots) {
            Lap "Add-WindowsDriver $($p.id) <- $r"
            $res = @(Add-WindowsDriver -Path $mount -Driver $r -Recurse -ErrorAction Stop)
            Write-Host ("    {0} driver packages added" -f $res.Count)
            $added += $res.Count
        }
    }
    $installed = @(Get-WindowsDriver -Path $mount)
    $installed | Select-Object Driver, OriginalFileName, ClassName, ProviderName, Date, Version |
        Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $OutDir "drivers-$Target.csv")
    $byClass = $installed | Group-Object ClassName | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ("  third-party drivers in the image: {0} ({1})" -f $installed.Count, ($byClass -join ', '))
    $display = @($installed | Where-Object { $_.ClassName -eq 'Display' })
    foreach ($d in $display) { Write-Host ("  Display: {0} {1} {2} {3}" -f $d.ProviderName, $d.Version, $d.Date, (Split-Path -Leaf $d.OriginalFileName)) }
    Lap 'drivers injected'

    Write-Step 'Pre-apply the zero-egress lockdown to the offline image'
    $stage = Join-Path $WorkDir 'stack'
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    Expand-Archive -LiteralPath $StackZip -DestinationPath $stage
    $stackSrc = Join-Path $stage 'lecore-plus-windows-stack'
    & (Join-Path $stackSrc 'lockdown.ps1') -OfflineImage $mount
    Lap 'offline lockdown applied'

    Write-Step 'Stage the stack installer (runs in the specialize pass) + SetupComplete.cmd fallback'
    $scripts = Join-Path $mount 'Windows\Setup\Scripts'
    New-Item -ItemType Directory -Force -Path (Join-Path $scripts 'lecore-plus') | Out-Null
    & robocopy.exe $stackSrc (Join-Path $scripts 'lecore-plus') /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy of the stack failed ($LASTEXITCODE)" }
    Copy-Item -Force (Join-Path $stackSrc 'SetupComplete.cmd') (Join-Path $scripts 'SetupComplete.cmd')
    $buildInfo = [ordered]@{
        product = 'Zero'; target = $Target; title = $cfg.title; tiers = $cfg.tiers; release = $Tag
        windows = [ordered]@{ edition = $info.ImageName; version = $winVer; iso = (Split-Path -Leaf $Iso) }
        drivers = @($drv.packages | ForEach-Object { [ordered]@{ id = $_.id; vendor = $_.vendor; name = $_.name; version = $_.version; sha256 = $_.sha256 } })
        display_drivers_in_image = @($display | ForEach-Object { "$($_.ProviderName) $($_.Version) $(Split-Path -Leaf $_.OriginalFileName)" })
        built_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); source_commit = $env:GITHUB_SHA
    }
    $bi = $buildInfo | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText((Join-Path $scripts 'lecore-plus\zero-image.json'), $bi, (New-Object Text.UTF8Encoding($false)))

    Write-Step 'Commit install image'
    Dismount-WindowsImage -Path $mount -Save | Out-Null
    $saved = $true
    Lap 'committed'
} finally {
    if (-not $saved) { Dismount-WindowsImage -Path $mount -Discard -ErrorAction SilentlyContinue | Out-Null }
}

Write-Step 'Re-export install.wim (max compression, drops superseded blobs)'
if (Test-Path $finalWim) { Remove-Item -Force $finalWim }
Export-WindowsImage -SourceImagePath $proWim -SourceIndex 1 -DestinationImagePath $finalWim -CompressionType max | Out-Null
Remove-Item -Force $proWim
Write-Host ("  install.wim {0:N2} GB" -f ((Get-Item $finalWim).Length / 1GB))
Lap 'exported'
Show-Disk 'after install.wim'

Write-Step 'boot.wim (Windows Setup, index 2): storage drivers so Setup sees the disk'
$bootWim = Join-Path $isoDir 'sources\boot.wim'
$setupIdx = (Get-WindowsImage -ImagePath $bootWim | Where-Object { $_.ImageName -match 'Setup' } | Select-Object -First 1).ImageIndex
if (-not $setupIdx) { $setupIdx = 2 }
Mount-WindowsImage -ImagePath $bootWim -Index $setupIdx -Path $bootMount | Out-Null
$bootSaved = $false
try {
    $n = 0
    foreach ($p in $drv.packages) {
        if ($p.inject_boot) {
            foreach ($r in $p.inject_roots) { $n += @(Add-WindowsDriver -Path $bootMount -Driver $r -Recurse -ErrorAction Stop).Count }
        }
        if ($p.boot_classes -and @($p.boot_classes).Count) {
            foreach ($r in $p.inject_roots) {
                Get-ChildItem -Recurse -File -Path $r -Filter *.inf | ForEach-Object {
                    $text = [IO.File]::ReadAllText($_.FullName)
                    $class = ([regex]::Match($text, '(?im)^\s*Class\s*=\s*"?([A-Za-z0-9_]+)')).Groups[1].Value
                    if (@($p.boot_classes) -contains $class) {
                        try { $n += @(Add-WindowsDriver -Path $bootMount -Driver $_.FullName -ErrorAction Stop).Count; Write-Host "    + $class $($_.Name)" }
                        catch { Write-Warning "    boot.wim: $($_.Exception.Message)" }
                    }
                }
            }
        }
    }
    Write-Host "  $n driver packages added to boot.wim index $setupIdx"
    Dismount-WindowsImage -Path $bootMount -Save | Out-Null
    $bootSaved = $true
} finally {
    if (-not $bootSaved) { Dismount-WindowsImage -Path $bootMount -Discard -ErrorAction SilentlyContinue | Out-Null }
}
Lap 'boot.wim done'

Write-Step 'install.wim -> sources (split to .swm when > 4 GB, so the USB can be FAT32)'
$sources = Join-Path $isoDir 'sources'
if ((Get-Item $finalWim).Length -ge 4GB - 1) {
    Split-WindowsImage -ImagePath $finalWim -SplitImagePath (Join-Path $sources 'install.swm') -FileSize 3800 -CheckIntegrity | Out-Null
    Remove-Item -Force $finalWim
    Get-ChildItem $sources -Filter 'install*.swm' | ForEach-Object { Write-Host ("  {0} {1:N2} GB" -f $_.Name, ($_.Length / 1GB)) }
} else {
    Move-Item -Force $finalWim (Join-Path $sources 'install.wim')
}
$tooBig = @(Get-ChildItem -Recurse -File $isoDir | Where-Object { $_.Length -ge 4GB })
if ($tooBig.Count) { throw "files >= 4 GB would not fit FAT32: $($tooBig.FullName -join ', ')" }

Write-Step 'autounattend.xml'
$xml = (Get-Content -Raw -LiteralPath (Join-Path $winDir 'image\autounattend.xml')).Replace('@OEM_MODEL@', [Security.SecurityElement]::Escape($cfg.oem_model))
$null = [xml]$xml   # well-formed check
[IO.File]::WriteAllText((Join-Path $isoDir 'autounattend.xml'), $xml, (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $isoDir 'zero-image.json'), $bi, (New-Object Text.UTF8Encoding($false)))

Write-Step 'oscdimg'
$name = "zero-$Target-win11pro-$winVer"
$outIso = Join-Path $OutDir "$name.iso"
if (Test-Path $outIso) { Remove-Item -Force $outIso }
$etfs = Join-Path $isoDir 'boot\etfsboot.com'
$efi = Join-Path $isoDir 'efi\microsoft\boot\efisys.bin'
Invoke-Native $Oscdimg @('-m', '-o', '-u2', '-udfver102', "-l$($cfg.iso_label)", "-bootdata:2#p0,e,b$etfs#pEF,e,b$efi", $isoDir, $outIso) | Out-Null
Remove-Item -Recurse -Force $isoDir
Lap 'iso written'

Write-Step 'Verify the ISO'
$v = Mount-DiskImage -ImagePath $outIso -PassThru
try {
    $dl = "$(($v | Get-Volume).DriveLetter):"
    foreach ($f in 'autounattend.xml', 'setup.exe', 'sources\boot.wim', 'efi\boot\bootx64.efi') { if (-not (Test-Path "$dl\$f")) { throw "ISO is missing $f" } }
    $first = @(Get-ChildItem "$dl\sources" -File | Where-Object { $_.Name -in 'install.swm', 'install.wim' })[0].FullName
    $chk = Get-WindowsImage -ImagePath $first -Index 1
    Write-Host ("  {0}: {1} {2}, {3} index" -f (Split-Path -Leaf $first), $chk.ImageName, $chk.Version, @(Get-WindowsImage -ImagePath $first).Count)
    if ($chk.ImageName -ne 'Windows 11 Pro') { throw "unexpected edition in the ISO: $($chk.ImageName)" }
} finally { Dismount-DiskImage -ImagePath $outIso | Out-Null }

$isoHash = Get-Sha256 $outIso
$buildInfo['iso'] = [ordered]@{ file = "$name.iso"; bytes = (Get-Item $outIso).Length; sha256 = $isoHash }
[IO.File]::WriteAllText((Join-Path $OutDir "build-info-$Target.json"), ($buildInfo | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value "ZERO_ISO=$outIso" }
Write-Summary ("### Image: $Target`n`n``$name.iso`` {0:N2} GB, sha256 ``$isoHash```n`nWindows 11 Pro $winVer. Display drivers in the image: {1}`n" -f ((Get-Item $outIso).Length / 1GB), ($buildInfo.display_drivers_in_image -join '; '))
Lap "done: $outIso"
