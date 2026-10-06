<#
  Zero golden image, build VM only: runs once in AUDIT mode (auditUser pass of the build answer file,
  as the built-in Administrator), after Windows Setup and the ISO's specialize pass installed the Zero
  stack. It never runs on a laptop.

  1. checks the stack the specialize pass installed (services, payload marker, chat answering)
  2. installs the golden first-boot task (\Zero\Zero golden first boot -> firstboot.ps1)
  3. removes what must be unique per laptop: the llama-server API key (each laptop's specialize pass
     makes its own), this VM's service logs, hiberfil.sys
  4. writes C:\ProgramData\leCore+\golden.json
  5. sysprep /generalize /oobe /shutdown /unattend:<shipped answer file>

  Progress goes to COM1 (the build host reads the VM's serial port) and to audit.log next to this file.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$data = Join-Path $env:ProgramData 'leCore+'
$root = Join-Path $env:ProgramFiles 'leCore+'

$script:port = $null
try { $script:port = New-Object System.IO.Ports.SerialPort 'COM1', 115200; $script:port.Open() } catch { $script:port = $null }
function Say([string]$m) {
    $line = "[zero-golden audit {0:HH:mm:ss}] {1}" -f (Get-Date), $m
    Write-Host $line
    if ($script:port) { try { $script:port.WriteLine($line) } catch { } }
}
function Fail([string]$m) {
    Say "ZERO_AUDIT_FAIL: $m"
    Start-Sleep -Seconds 3
    Stop-Computer -Force
    exit 1
}
function Wait-Http([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri $Url; if ($r.StatusCode -eq 200) { return $r } } catch { }
        Start-Sleep -Seconds 3
    }
    return $null
}

Say 'ZERO_AUDIT_STARTED'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    Say ("{0} {1} build {2}, audit mode as {3}" -f $os.Caption, $os.Version, $os.BuildNumber, [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $state = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
    Say "image state: $state"

    # 1. the stack -----------------------------------------------------------------------------------
    $marker = Join-Path $root 'installed.json'
    if (-not (Test-Path -LiteralPath $marker)) {
        Say ((Get-Content -LiteralPath (Join-Path $env:WINDIR 'Setup\Scripts\lecore-plus-specialize.log') -Tail 60 -ErrorAction SilentlyContinue) -join "`n")
        Fail "the specialize pass did not install the stack ($marker missing)"
    }
    Say ("stack: " + ((Get-Content -Raw -LiteralPath $marker) -replace "`r?`n", ' '))
    foreach ($id in 'lecore-llama', 'lecore-chat') {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$id'"
        if (-not $svc) { Fail "service $id missing" }
        Say ("service {0}: {1}, {2}, start {3}" -f $id, $svc.State, $svc.StartName, $svc.StartMode)
        if ($svc.StartName -notmatch 'LocalService') { Fail "$id does not run as LOCAL SERVICE" }
    }
    $st = Wait-Http 'http://127.0.0.1:7860/zero/status' 300
    if (-not $st) { Fail 'the chat did not answer on 127.0.0.1:7860 within 300 s' }
    Say ("chat status: " + $st.Content)
    $rules = @(Get-NetFirewallRule -Name 'LecorePlus-Contain-*' -ErrorAction SilentlyContinue)
    Say ("containment firewall rules: {0}" -f $rules.Count)
    if ($rules.Count -lt 6) { Fail "expected 6 containment firewall rules, found $($rules.Count)" }

    # 2. golden first-boot task ----------------------------------------------------------------------
    $gdir = Join-Path $root 'golden'
    New-Item -ItemType Directory -Force -Path $gdir | Out-Null
    Copy-Item -Force (Join-Path $here 'firstboot.ps1') (Join-Path $gdir 'firstboot.ps1')
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $gdir 'firstboot.ps1'))
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable
    Register-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero golden first boot' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'Zero golden image: extends C: to the whole disk, resets the model files ACLs, installs the firmware product key, makes sure the per-machine llama-server key exists. Runs once, then removes itself.' -Force | Out-Null
    Say 'registered \Zero\Zero golden first boot'

    # 3. per-machine state out ------------------------------------------------------------------------
    $key = Join-Path $data 'secret\llama-api-key'
    $buildKeySha = $null
    if (Test-Path -LiteralPath $key) {
        $buildKeySha = (Get-FileHash -LiteralPath $key -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    foreach ($id in 'lecore-chat', 'lecore-llama') { Stop-Service -Name $id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    if (Test-Path -LiteralPath $key) { Remove-Item -Force -LiteralPath $key }
    Say ("build VM's llama-server API key removed (sha256 {0}); each laptop's specialize pass generates its own" -f $buildKeySha)
    Get-ChildItem -LiteralPath (Join-Path $data 'logs') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'lecore-*.log' -or $_.Name -like 'lecore-*.out.log*' -or $_.Name -like 'lecore-*.err.log*' -or $_.Name -like '*.wrapper.log' } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    & powercfg.exe /hibernate off | Out-Null
    Say 'hibernation off for the capture (firstboot.ps1 turns it back on)'

    # 4. record ----------------------------------------------------------------------------------------
    $g = [ordered]@{
        product = 'Zero'; golden = $true
        built_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        windows = "$($os.Caption) $($os.Version)"
        build_machine_sid = ((New-Object Security.Principal.NTAccount('Administrator')).Translate([Security.Principal.SecurityIdentifier]).AccountDomainSid.Value)
        build_api_key_sha256 = $buildKeySha
        image = (Get-Content -Raw -LiteralPath (Join-Path $env:WINDIR 'Setup\Scripts\lecore-plus\zero-image.json') -ErrorAction SilentlyContinue | ConvertFrom-Json)
    }
    [IO.File]::WriteAllText((Join-Path $data 'golden.json'), ($g | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    Say ("build SID {0}" -f $g.build_machine_sid)

    # 5. sysprep ---------------------------------------------------------------------------------------
    $unattend = Join-Path $here 'shipped-unattend.xml'
    if (-not (Test-Path -LiteralPath $unattend)) { Fail "$unattend missing" }
    Get-Process -Name sysprep -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Say 'ZERO_SYSPREP_RUN sysprep /generalize /oobe /shutdown /quiet'
    $sp = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\Sysprep\sysprep.exe') -PassThru -Wait `
        -ArgumentList @('/generalize', '/oobe', '/shutdown', '/quiet', "/unattend:$unattend")
    # sysprep shuts the VM down when it succeeds; reaching this line means it failed
    Start-Sleep -Seconds 60
    $err = Join-Path $env:WINDIR 'System32\Sysprep\Panther\setuperr.log'
    Say ("sysprep exit {0}; setuperr.log:`n{1}" -f $sp.ExitCode, ((Get-Content -LiteralPath $err -Tail 40 -ErrorAction SilentlyContinue) -join "`n"))
    Fail 'sysprep did not shut the machine down'
} catch {
    Fail ("{0} at {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
}
