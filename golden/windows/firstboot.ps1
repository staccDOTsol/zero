<#
  Zero golden image: one-time work on each laptop's first boot. It runs twice, and every step is
  idempotent:
    - in the specialize pass of the image's answer file (-InSpecialize, before the model service
      starts, so the per-machine API key exists when it does), and
    - as the scheduled task \Zero\Zero golden first boot (at startup, SYSTEM; installed by
      golden/windows/audit.ps1 before sysprep), which also covers an imaging service that applies its
      own answer file. The task removes itself when everything is done.

  1. C: grows to the end of the disk. The golden image is only as large as Windows + the tier's
     models; written onto a 1 TB / 2 TB NVMe the rest of the disk would otherwise sit unallocated.
     Windows Setup put its Recovery partition right after C:, which blocks that, so (as the task, in
     full Windows) WinRE is moved onto C: first: reagentc /disable (winre.wim goes back to
     C:\Windows\System32\Recovery), the Recovery partition is deleted, C: is extended, and
     reagentc /enable turns WinRE back on (it then lives in C:\Recovery\WindowsRE).
  2. The model files were written into C:\ProgramData\leCore+\models by the image build (offline, from
     Linux): their ACLs are reset to the folder's inherited ones (LOCAL SERVICE read, users read).
  3. The laptop's own Windows 11 Pro key from its firmware (OA3 / ACPI MSDM) is installed, if the
     firmware has one and it is not the installed key already. Activation then happens online by itself.
  4. The per-machine llama-server API key: 256 random bits made on this machine, readable only by the two
     Zero services, SYSTEM and Administrators (the same as windows/stack/install.ps1 Set-LlamaApiKey).
     The image carries none: golden/windows/audit.ps1 deleted the build VM's key before sysprep.
  5. Hibernation (and with it Fast Startup) back on: it was off only so the image carries no
     hiberfil.sys.
  6. The two Zero services are running (started if a busy first boot left one stopped).
  Then the task removes itself. Log: C:\ProgramData\leCore+\logs\golden-firstboot.log
#>
param([switch]$InSpecialize)   # run from the answer file's specialize pass (image applied with DISM, no task)
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
if (-not $InSpecialize -and ($state -eq 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' -or $state -eq 'IMAGE_STATE_UNDEPLOYABLE')) {
    # the specialize pass has not finished yet: next boot
    Say 'Windows Setup is still in its specialize pass; running at the next boot'
    exit 0
}
# (golden test hook point: the build's throwaway verification overlay adds a line here)

# 1. C: to the end of the disk --------------------------------------------------------------------------
$reDisabled = $false
if (-not $InSpecialize) {
    # 1a. the Recovery partition right after C: (GPT type de94bba4-...) moves onto C:
    try {
        $c = Get-Partition -DriveLetter C
        $after = @(Get-Partition -DiskNumber $c.DiskNumber | Where-Object { $_.Offset -gt $c.Offset } | Sort-Object Offset)
        $rec = @($after | Where-Object { $_.GptType -eq '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}' })
        if ($after.Count -eq 1 -and $rec.Count -eq 1) {
            Say ("Recovery partition {0} ({1:N2} GB) after C:; reagentc /info: {2}" -f $rec[0].PartitionNumber, ($rec[0].Size / 1e9),
                ((& reagentc.exe /info 2>&1 | Where-Object { $_ -match 'status|location' }) -join ' ' -replace '\s+', ' '))
            $o = (& reagentc.exe /disable 2>&1) -join ' '
            Say "reagentc /disable: exit $LASTEXITCODE $o"
            if (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\Recovery\Winre.wim')) {
                $reDisabled = $true
                Remove-Partition -DiskNumber $c.DiskNumber -PartitionNumber $rec[0].PartitionNumber -Confirm:$false
                Say "deleted the Recovery partition; WinRE image is in C:\Windows\System32\Recovery"
            } else {
                Say 'WinRE image is not back on C: after reagentc /disable; Recovery partition kept'
                $ok = $false
            }
        }
    } catch { $ok = $false; Say "moving WinRE onto C: failed: $($_.Exception.Message)" }
}
$extended = $false
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
    $extended = $true
} catch { Say "Resize-Partition failed: $($_.Exception.Message)" }
if (-not $extended) {
    # same thing with diskpart (works in every Windows Setup pass)
    $dp = Join-Path $env:TEMP 'zero-extend.txt'
    Set-Content -LiteralPath $dp -Value "rescan`r`nselect volume C`r`nextend`r`nexit" -Encoding ascii
    $o = & diskpart.exe /s $dp 2>&1 | Out-String
    Say ("diskpart extend: exit {0}: {1}" -f $LASTEXITCODE, ($o -replace "`r?`n", ' '))
    if ($LASTEXITCODE -ne 0 -and $o -notmatch 'not enough usable free space|no usable free extent') { $ok = $false }
}

if ($reDisabled -or (-not $InSpecialize -and ((& reagentc.exe /info 2>&1) -join ' ') -match 'Windows RE status:\s*Disabled')) {
    $o = (& reagentc.exe /enable 2>&1) -join ' '
    Say "reagentc /enable: exit $LASTEXITCODE $o"
    $info = (& reagentc.exe /info 2>&1 | Where-Object { $_ -match 'status|location' }) -join ' ' -replace '\s+', ' '
    Say "reagentc /info: $info"
    if ($info -notmatch 'status:\s*Enabled') { $ok = $false }
}

# 2. model file ACLs ------------------------------------------------------------------------------------
try {
    # (the build also wrote C:\Windows\Setup\Scripts\zero-golden offline: same treatment)
    # the files only: the models folder keeps the LOCAL SERVICE read grant install.ps1 put on it
    foreach ($p in (Join-Path $data 'models\*'), (Join-Path $data 'model.txt'), (Join-Path $data 'models.json'), (Join-Path $env:WINDIR 'Setup\Scripts\zero-golden')) {
        if (Test-Path -Path $p) {
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

# 4. per-machine llama-server API key ----------------------------------------------------------------------
$key = Join-Path $data 'secret\llama-api-key'
try {
    if (-not (Test-Path -LiteralPath $key) -or (Get-Item -LiteralPath $key).Length -lt 64) {
        $dir = Split-Path -Parent $key
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' `
            'NT SERVICE\lecore-llama:(OI)(CI)RX' 'NT SERVICE\lecore-chat:(OI)(CI)RX' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $dir" }
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        [IO.File]::WriteAllText($key, (-join ($bytes | ForEach-Object { $_.ToString('x2') })), (New-Object Text.ASCIIEncoding))
        & icacls.exe $key /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' 'NT SERVICE\lecore-llama:R' 'NT SERVICE\lecore-chat:R' /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls failed on $key" }
        Say "llama-server API key generated for this machine ($key)"
    } else { Say 'llama-server API key present' }
} catch { $ok = $false; Say "API key: $($_.Exception.Message)" }

# 5. hibernation / Fast Startup back to the Windows default (the VM build turned it off for the capture) -------
if (-not $InSpecialize) {
    & powercfg.exe /hibernate on 2>&1 | Out-Null
    Say ("powercfg /hibernate on: exit {0}" -f $LASTEXITCODE)
}

# 6. the Zero services are running ---------------------------------------------------------------------------
if (-not $InSpecialize) {
    foreach ($id in 'lecore-llama', 'lecore-chat') {
        $svc = Get-Service -Name $id -ErrorAction SilentlyContinue
        if (-not $svc) { $ok = $false; Say "service $id is missing"; continue }
        if ($svc.Status -ne 'Running') {
            Say "service $id is $($svc.Status); starting it"
            try { Start-Service -Name $id; Say "service $id started" } catch { $ok = $false; Say "starting $id failed: $($_.Exception.Message)" }
        }
    }
}

if ($ok) {
    Say 'done; removing the task'
    Set-Content -LiteralPath (Join-Path $data 'golden-firstboot.done') -Value (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') -Encoding ascii
    if (-not $InSpecialize) { Unregister-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero golden first boot' -Confirm:$false -ErrorAction SilentlyContinue }
} else {
    Say 'something failed; the task stays and runs again at the next boot'
}
