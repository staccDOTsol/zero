<#
.SYNOPSIS
  Splits an ISO into parts of at most 1.9 GiB (GitHub release assets must be < 2 GiB), writes
  SHA256SUMS-<target>.txt (each part + the whole ISO), and uploads the parts and sums to the GitHub
  Release -Tag with gh (when -Tag is given). CI runner only.

  Reassemble on Windows:  copy /b name.iso.part01 + name.iso.part02 + ... name.iso   (or windows\make-usb.ps1)
  Reassemble on Linux/mac: cat name.iso.part* > name.iso
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Iso,
    [Parameter(Mandatory = $true)][string]$Target,
    [string]$Tag,
    [long]$PartBytes = 2040109465   # floor(1.9 GiB)
)
. (Join-Path $PSScriptRoot 'common.ps1')
$dir = Split-Path -Parent $Iso
$name = Split-Path -Leaf $Iso
$sums = Join-Path $dir "SHA256SUMS-$Target.txt"
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("$(Get-Sha256 $Iso)  $name")

Write-Step "Split $name into <= $PartBytes-byte parts"
$buf = New-Object byte[] (8MB)
$in = [IO.File]::OpenRead($Iso)
$parts = @()
try {
    $i = 0
    while ($in.Position -lt $in.Length) {
        $i++
        $part = Join-Path $dir ('{0}.part{1:D2}' -f $name, $i)
        $out = [IO.File]::Create($part)
        try {
            $left = [Math]::Min($PartBytes, $in.Length - $in.Position)
            while ($left -gt 0) {
                $n = $in.Read($buf, 0, [int][Math]::Min($buf.Length, $left))
                if ($n -le 0) { throw 'unexpected end of file' }
                $out.Write($buf, 0, $n); $left -= $n
            }
        } finally { $out.Close() }
        $parts += $part
        $lines.Add("$(Get-Sha256 $part)  $(Split-Path -Leaf $part)")
        Write-Host ("  {0} {1:N0} bytes" -f (Split-Path -Leaf $part), (Get-Item $part).Length)
    }
} finally { $in.Close() }
[IO.File]::WriteAllLines($sums, [string[]]$lines)
Get-Content $sums | ForEach-Object { Write-Host "  $_" }
if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value "ZERO_SUMS=$sums" }

if ($Tag) {
    Write-Step "Upload to release $Tag"
    foreach ($f in @($parts + $sums)) {
        for ($try = 1; $try -le 4; $try++) {
            & gh release upload $Tag $f --clobber
            if ($LASTEXITCODE -eq 0) { break }
            Write-Warning "upload of $f failed (try $try)"; Start-Sleep -Seconds (20 * $try)
        }
        if ($LASTEXITCODE -ne 0) { throw "gh release upload failed for $f" }
        if ($f -ne $sums) { Remove-Item -Force $f }
    }
}
