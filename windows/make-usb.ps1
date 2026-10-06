<#
.SYNOPSIS
  Makes a bootable Zero install USB stick from a release's ISO parts (or a whole ISO).

.DESCRIPTION
  1. Reassembles <name>.iso from <name>.iso.part01, .part02, ... (if -Iso is not given) and checks
     every part and the whole ISO against SHA256SUMS.
  2. ERASES the USB disk -DiskNumber, creates one FAT32 partition (31 GB max, GPT, UEFI boot) and
     copies the ISO's files onto it. install.wim is already split into install.swm parts < 4 GB, so
     everything fits FAT32.

  Run elevated on Windows 10/11. Find the disk number with Get-Disk (BusType USB).

.EXAMPLE
  .\make-usb.ps1 -Parts D:\release -DiskNumber 3
.EXAMPLE
  .\make-usb.ps1 -Iso D:\zero-hp-zbook-ultra-g1a-win11pro-10.0.26200.6584.iso -DiskNumber 3
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Parts = (Get-Location).Path,
    [string]$Iso,
    [string]$Name,
    [Parameter(Mandatory = $true)][int]$DiskNumber,
    [switch]$AllowNonUsb
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
function Get-Sha256([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }

$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run make-usb.ps1 from an elevated PowerShell.' }

if (-not $Iso) {
    $first = @(Get-ChildItem -LiteralPath $Parts -Filter '*.iso.part01' | Where-Object { -not $Name -or $_.Name -eq "$Name.part01" })
    if ($first.Count -ne 1) { throw "found $($first.Count) '*.iso.part01' files in $Parts; pass -Name <file>.iso" }
    $isoName = $first[0].Name -replace '\.part01$', ''
    $all = @(Get-ChildItem -LiteralPath $Parts -Filter "$isoName.part*" | Sort-Object Name)
    $sumsFile = @(Get-ChildItem -LiteralPath $Parts -Filter 'SHA256SUMS*' | Select-Object -First 1)
    $sums = @{}
    foreach ($s in $sumsFile) { Get-Content -LiteralPath $s.FullName | ForEach-Object { if ($_ -match '^([0-9a-fA-F]{64})\s+\*?(.+)$') { $sums[$matches[2].Trim()] = $matches[1].ToLowerInvariant() } } }
    if (-not $sums.Count) { Write-Warning 'no SHA256SUMS next to the parts: parts are NOT verified' }
    foreach ($f in $all) {
        if ($sums.ContainsKey($f.Name)) {
            if ((Get-Sha256 $f.FullName) -ne $sums[$f.Name]) { throw "$($f.Name) is corrupt (sha256 mismatch)" }
            Write-Host "ok  $($f.Name)"
        }
    }
    $Iso = Join-Path $Parts $isoName
    Write-Host "reassembling $Iso from $($all.Count) parts"
    $out = [IO.File]::Create($Iso)
    try { foreach ($f in $all) { $in = [IO.File]::OpenRead($f.FullName); try { $in.CopyTo($out, 8MB) } finally { $in.Close() } } } finally { $out.Close() }
    if ($sums.ContainsKey($isoName)) {
        if ((Get-Sha256 $Iso) -ne $sums[$isoName]) { throw "$isoName is corrupt after reassembly" }
        Write-Host "ok  $isoName"
    }
}

$disk = Get-Disk -Number $DiskNumber
if ($disk.IsBoot -or $disk.IsSystem) { throw "disk $DiskNumber is this computer's boot/system disk" }
if ($disk.BusType -ne 'USB' -and -not $AllowNonUsb) { throw "disk $DiskNumber is $($disk.BusType), not USB (use -AllowNonUsb to override)" }
$desc = "disk $DiskNumber ($($disk.FriendlyName), {0:N1} GB)" -f ($disk.Size / 1GB)
if (-not $PSCmdlet.ShouldProcess($desc, 'ERASE and write the Zero installer')) { return }

Write-Host "erasing $desc"
if ($disk.PartitionStyle -ne 'RAW') { Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false }
if ((Get-Disk -Number $DiskNumber).PartitionStyle -eq 'RAW') { Initialize-Disk -Number $DiskNumber -PartitionStyle GPT }
$size = [Math]::Min($disk.Size - 64MB, 31GB)   # Windows formats FAT32 only up to 32 GB
$part = New-Partition -DiskNumber $DiskNumber -Size $size -AssignDriveLetter -GptType '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$vol = Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'ZERO' -Confirm:$false
$usb = "$($vol.DriveLetter):\"

$m = Mount-DiskImage -ImagePath (Resolve-Path $Iso).Path -PassThru
try {
    $src = "$(($m | Get-Volume).DriveLetter):\"
    Write-Host "copying $src -> $usb"
    & robocopy.exe $src $usb /E /R:1 /W:1 /NFL /NDL /NJH /NP | Out-Host
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
} finally { Dismount-DiskImage -ImagePath (Resolve-Path $Iso).Path | Out-Null }
foreach ($f in 'autounattend.xml', 'efi\boot\bootx64.efi', 'sources\boot.wim') { if (-not (Test-Path (Join-Path $usb $f))) { throw "USB is missing $f" } }
Write-Host "done: $usb is a UEFI-bootable Zero installer (boot the laptop from it; Secure Boot can stay on)."
