<#
  Zero golden image: one-time work on each laptop's first boot. Scheduled task
  \Zero\Zero golden first boot (at startup, SYSTEM), installed by golden/windows/audit.ps1 before
  sysprep. It does not depend on the image's answer file, so it also runs when an imaging service
  applies its own unattend.xml.

  1. C: grows to the end of the disk. The golden image is only as large as Windows + the tier's
     models; written onto a 1 TB / 2 TB NVMe the rest of the disk would otherwise sit unallocated.
  2. The model files were written into C:\ProgramData\leCore+\models by the image build (offline, from
     Linux): their ACLs are reset to the folder's inherited ones (LOCAL SERVICE read, users read).
  3. The laptop's own Windows 11 Pro key from its firmware (OA3 / ACPI MSDM) is installed, if the
     firmware has one and it is not the installed key already. Activation then happens online by itself.
  4. The per-machine llama-server API key exists (the specialize pass makes it; if an imaging
     service replaced our answer file, install.ps1 is run here instead).
  5. Hibernation (and with it Fast Startup) back on: it was off only so the image carries no
     hiberfil.sys.
  Then the task removes itself. Log: C:\ProgramData\leCore+\logs\golden-firstboot.log
#>
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$data = Join-Path $env:ProgramData 'leCore+'
$root = Join-Path $env:ProgramFiles 'leCore+'
New-Item -ItemType Directory -Force -Path (Join-Path $data 'logs') | Out-Null
$log = Join-Path $data 'logs\golden-firstboot.log'
function Say([string]$m) { $l = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m; Add-Content -LiteralPath $log -Value $l -Encoding utf8; Write-Output $l }
$ok = $true
$state = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction SilentlyContinue).ImageState
Say "Zero golden first boot (image state $state)"
if ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -or $state -eq 'IMAGE_STATE_UNDEPLOYABLE') {
    # the specialize pass has not finished yet (it installs the stack and the API key): next boot
    Say 'Windows Setup is still in its specialize pass; running at the next boot'
    exit 0
}

# 1. C: to the end of the disk --------------------------------------------------------------------------
try {
    Update-HostStorageCache -ErrorAction SilentlyContinue
    $c = Get-Partition -DriveLetter C
    Update-Disk -Number $c.DiskNumber -ErrorAction SilentlyContinue
    $c = Get-Partition -DriveLetter C
    $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
    $disk = Get-Disk -Number $c.DiskNumber
    Say ("disk {0}: {1:N1} GB; C: {2:N1} GB, can grow to {3:N1} GB" -f $c.DiskNumber, ($disk.Size / 1e9), ($c.Size / 1e9), ($max / 1e9))
    if ($max - $c.Size -gt 1GB) {
        Resize-Partition -DriveLetter C -Size $max
        Say ("C: is now {0:N1} GB" -f ((Get-Partition -DriveLetter C).Size / 1e9))
    }
} catch { $ok = $false; Say "extend C: failed: $($_.Exception.Message)" }

# 2. model file ACLs ------------------------------------------------------------------------------------
try {
    # (the build also wrote C:\Windows\Setup\Scripts\zero-golden offline: same treatment)
    foreach ($p in (Join-Path $data 'models'), (Join-Path $data 'model.txt'), (Join-Path $data 'models.json'), (Join-Path $env:WINDIR 'Setup\Scripts\zero-golden')) {
        if (Test-Path -LiteralPath $p) {
            & icacls.exe $p /reset /T /C /Q | Out-Null
            Say ("icacls /reset {0}: exit {1}" -f $p, $LASTEXITCODE)
        }
    }
} catch { $ok = $false; Say "ACL reset failed: $($_.Exception.Message)" }

# 3. the laptop's own product key from firmware ------------------------------------------------------------
try {
    $sls = Get-CimInstance -ClassName SoftwareLicensingService
    $fw = $sls.OA3xOriginalProductKey
    if ($fw) {
        $installed = @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | ForEach-Object { $_.PartialProductKey })
        if ($installed -contains $fw.Substring($fw.Length - 5)) { Say 'firmware (OA3) product key already installed' }
        else {
            $r = Invoke-CimMethod -InputObject $sls -MethodName InstallProductKey -Arguments @{ ProductKey = $fw }
            Say ("installed the firmware (OA3) product key ending {0}: return {1}" -f $fw.Substring($fw.Length - 5), $r.ReturnValue)
            try { Invoke-CimMethod -InputObject $sls -MethodName RefreshLicenseStatus | Out-Null } catch { }
        }
    } else { Say 'no OA3 product key in the firmware (not a licensed laptop, or a VM)' }
} catch { Say "firmware key: $($_.Exception.Message)" }

# 4. per-machine llama-server API key ------------------------------------------------------------------------
$key = Join-Path $data 'secret\llama-api-key'
if (-not (Test-Path -LiteralPath $key)) {
    Say 'llama-server API key missing (answer file replaced?): running install.ps1'
    try {
        & (Join-Path $root 'setup\install.ps1') -Phase golden-firstboot *>&1 | ForEach-Object { Say "  $_" }
    } catch { $ok = $false; Say "install.ps1 failed: $($_.Exception.Message)" }
}
if (Test-Path -LiteralPath $key) { Say 'llama-server API key present' } else { $ok = $false; Say 'llama-server API key STILL missing' }

# 5. hibernation / Fast Startup back to the Windows default ----------------------------------------------------
& powercfg.exe /hibernate on 2>&1 | Out-Null
Say ("powercfg /hibernate on: exit {0}" -f $LASTEXITCODE)

if ($ok) {
    Say 'done; removing the task'
    Set-Content -LiteralPath (Join-Path $data 'golden-firstboot.done') -Value (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -Encoding ascii
    Unregister-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero golden first boot' -Confirm:$false -ErrorAction SilentlyContinue
} else {
    Say 'something failed; the task stays and runs again at the next boot'
}
