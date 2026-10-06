<#
  Zero golden images, Windows step 1 of 2 (AWS, Windows Server EC2 instance, no VM needed).
  For each laptop model: the Zero ISO's install image (Windows 11 Pro with the laptop's drivers, the
  Zero stack staged and the privacy/containment registry pre-applied by windows/build/Build-Image.ps1)
  is applied with Microsoft's own tools onto a GPT disk, the way Microsoft documents deploying a
  generalized image: DISM /Apply-Image, bcdboot, answer file in \Windows\Panther. Microsoft's
  install.wim is a generalized image (sysprep /generalize), so on each laptop's first boot Windows runs
  specialize (new SID, Plug and Play on that laptop, the Zero stack install + a per-machine API key,
  golden\windows\firstboot.ps1) and then OOBE. Output: a dynamic VHDX per laptop model in
  s3://BUCKET/windows/<tag>/os/, which golden/aws/windows-assemble.sh turns into the tier images.

  Inputs (all from the private bucket, read with the instance profile; no tokens):
    base/windows/<tag>/...            ISO parts + SHA256SUMS-<laptop>.txt (golden-stage workflow)
    golden-src/<sha>/golden/...       this repo's golden/ at the commit being built
#>
param(
    [Parameter(Mandatory = $true)][string]$Bucket,
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Src,
    [string]$Work = 'C:\zero'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$log = Join-Path $Work 'windows-os.log'
Start-Transcript -LiteralPath $log -Force | Out-Null
function Say([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Run([string]$exe, [string[]]$a) {
    Say ("> {0} {1}" -f $exe, ($a -join ' '))
    & $exe @a 2>&1 | ForEach-Object { "  $_" } | Write-Host
    if ($LASTEXITCODE -ne 0) { throw "$exe exited $LASTEXITCODE" }
}
function Put-Log { try { Write-S3Object -BucketName $Bucket -Key "windows/$Tag/os/windows-os.log" -File $log } catch { } }
$result = 'FAIL'
try {
    Say "Zero golden Windows OS step: $Tag, source $Src"
    Read-S3Object -BucketName $Bucket -KeyPrefix "$Src/golden/windows/" -Folder (Join-Path $Work 'src') | Out-Null
    foreach ($t in 'hp-zbook-ultra-g1a', 'lenovo-p16-gen3') {
        Say "=== $t"
        $d = Join-Path $Work $t; New-Item -ItemType Directory -Force -Path $d | Out-Null
        $sums = Join-Path $d 'sums.txt'
        Read-S3Object -BucketName $Bucket -Key "base/windows/$Tag/SHA256SUMS-$t.txt" -File $sums | Out-Null
        $lines = Get-Content $sums | ForEach-Object { $h, $n = $_ -split '\s+', 2; [pscustomobject]@{ Hash = $h; Name = $n.Trim() } }
        $isoLine = $lines | Where-Object { $_.Name -match '\.iso$' }
        $iso = Join-Path $d $isoLine.Name
        $out = [IO.File]::Create($iso)
        try {
            foreach ($p in ($lines | Where-Object { $_.Name -match '\.iso\.part\d+$' } | Sort-Object Name)) {
                $pf = Join-Path $d $p.Name
                Read-S3Object -BucketName $Bucket -Key "base/windows/$Tag/$($p.Name)" -File $pf | Out-Null
                if ((Get-FileHash $pf -Algorithm SHA256).Hash.ToLower() -ne $p.Hash) { throw "$($p.Name): sha256 mismatch" }
                $in = [IO.File]::OpenRead($pf); try { $in.CopyTo($out, 16MB) } finally { $in.Close() }
                Remove-Item $pf
            }
        } finally { $out.Close() }
        if ((Get-FileHash $iso -Algorithm SHA256).Hash.ToLower() -ne $isoLine.Hash) { throw "$($isoLine.Name): sha256 mismatch" }
        Say "ISO ok: $($isoLine.Name)"
        $img = Mount-DiskImage -ImagePath $iso -PassThru
        $isoDrive = ($img | Get-Volume).DriveLetter + ':'
        $swm = Join-Path $isoDrive 'sources\install.swm'
        if (-not (Test-Path $swm)) { $swm = Join-Path $isoDrive 'sources\install.wim' }
        Get-WindowsImage -ImagePath $swm | Format-List ImageIndex, ImageName, ImageSize | Out-String | Write-Host

        # the laptop's answer file: the ISO's own autounattend.xml without windowsPE + the golden first-boot step
        $au = Join-Path $d 'unattend.xml'
        & (Join-Path $Work 'src\offline-unattend.ps1') -IsoAnswerFile (Join-Path $isoDrive 'autounattend.xml') -Out $au

        # GPT disk: ESP 260 MB, MSR 16 MB, Windows NTFS (48 GiB; grown to the tier size on Linux)
        $vhd = Join-Path $d "zero-$t-os.vhdx"
        if (Test-Path $vhd) { Remove-Item $vhd }
        $dp = Join-Path $d 'diskpart.txt'
        Set-Content -LiteralPath $dp -Encoding ascii -Value @"
create vdisk file="$vhd" maximum=49152 type=expandable
select vdisk file="$vhd"
attach vdisk
convert gpt
create partition efi size=260
format quick fs=fat32 label="System"
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label="Windows"
assign letter=W
exit
"@
        Run diskpart.exe @('/s', $dp)
        $dismArgs = @('/Apply-Image', "/ImageFile:$swm", '/Index:1', '/ApplyDir:W:\')
        if ($swm -like '*.swm') { $dismArgs += "/SWMFile:$(Join-Path $isoDrive 'sources\install*.swm')" }
        Run dism.exe $dismArgs
        # bcdboot from the applied Windows itself (the same version as the image)
        Run 'W:\Windows\System32\bcdboot.exe' @('W:\Windows', '/s', 'S:', '/f', 'UEFI')
        New-Item -ItemType Directory -Force -Path 'W:\Windows\Panther', 'W:\Windows\Setup\Scripts\zero-golden' | Out-Null
        Copy-Item -Force $au 'W:\Windows\Panther\unattend.xml'
        Copy-Item -Force (Join-Path $Work 'src\firstboot.ps1') 'W:\Windows\Setup\Scripts\zero-golden\firstboot.ps1'

        # checks
        Run bcdedit.exe @('/store', 'S:\EFI\Microsoft\Boot\BCD', '/enum', 'all')
        foreach ($f in 'S:\EFI\Boot\bootx64.efi', 'S:\EFI\Microsoft\Boot\bootmgfw.efi', 'W:\Windows\System32\winload.efi',
                       'W:\Windows\Setup\Scripts\lecore-plus\install.ps1', 'W:\Windows\Setup\Scripts\SetupComplete.cmd') {
            if (-not (Test-Path $f)) { throw "missing $f" }
        }
        Run reg.exe @('load', 'HKLM\ZGOLD', 'W:\Windows\System32\config\SOFTWARE')
        $state = (Get-ItemProperty 'HKLM:\ZGOLD\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
        $ed = (Get-ItemProperty 'HKLM:\ZGOLD\Microsoft\Windows NT\CurrentVersion').EditionID
        [gc]::Collect(); Start-Sleep 2
        Run reg.exe @('unload', 'HKLM\ZGOLD')
        Say "image state $state, edition $ed"
        if ($state -ne 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE') { throw "image is not generalized ($state)" }
        if ($ed -ne 'Professional') { throw "edition is $ed, not Professional" }
        $drv = @(Get-WindowsDriver -Path 'W:\')
        Say ("{0} third-party driver packages in the image; Display: {1}" -f $drv.Count, (($drv | Where-Object ClassName -eq 'Display' | ForEach-Object { "$($_.ProviderName) $($_.Version)" }) -join '; '))
        $disk = Get-Disk | Where-Object { $_.Location -eq $vhd -or $_.FriendlyName -match 'Virtual' } | Sort-Object Number | Select-Object -Last 1
        $parts = Get-Partition -DiskNumber $disk.Number | ForEach-Object { "{0} {1} {2} {3}" -f $_.PartitionNumber, $_.Type, $_.Guid, $_.Size }
        Say ("disk GUID {0}; partitions: {1}" -f $disk.Guid, ($parts -join ' | '))
        $used = (Get-Volume -DriveLetter W).Size - (Get-Volume -DriveLetter W).SizeRemaining
        Say ("Windows volume: {0:N1} GB used" -f ($used / 1e9))

        Set-Content -LiteralPath $dp -Encoding ascii -Value "select vdisk file=`"$vhd`"`r`ndetach vdisk`r`nexit"
        Run diskpart.exe @('/s', $dp)
        Dismount-DiskImage -ImagePath $iso | Out-Null
        Remove-Item $iso
        $h = (Get-FileHash $vhd -Algorithm SHA256).Hash.ToLower()
        Set-Content -LiteralPath "$vhd.sha256" -Value "$h  zero-$t-os.vhdx" -Encoding ascii
        Write-S3Object -BucketName $Bucket -Key "windows/$Tag/os/zero-$t-os.vhdx" -File $vhd
        Write-S3Object -BucketName $Bucket -Key "windows/$Tag/os/zero-$t-os.vhdx.sha256" -File "$vhd.sha256"
        Say ("uploaded zero-$t-os.vhdx ({0:N1} GB, sha256 {1})" -f ((Get-Item $vhd).Length / 1e9), $h)
        Remove-Item $vhd
    }
    $result = 'PASS'
} catch {
    Say ("ERROR: {0} at {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
} finally {
    Say "ZERO_WINDOWS_OS_RESULT: $result"
    Stop-Transcript | Out-Null
    Put-Log
}
