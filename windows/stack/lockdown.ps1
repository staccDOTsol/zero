<#
.SYNOPSIS
  Zero model containment ("zero egress"): the model's input and output never leave the machine.
  The rest of Windows (Windows Update, Edge, the Store, time sync, Defender) uses the network normally.

.DESCRIPTION
  1. Firewall, per program. Windows Firewall stays on with DefaultOutboundAction = Allow on Domain,
     Private and Public. Two programs, and only these, may not talk to any non-loopback address, in
     either direction:
        C:\Program Files\leCore+\llama\llama-server.exe      (the model server)
        C:\Program Files\leCore+\python\python.exe / pythonw.exe   (leCore's own embedded Python; any
                                                                     other Python on the machine is not affected)
     Each gets an outbound and an inbound Block rule for every address except 127.0.0.0/8 and ::1.
     Block rules win over allow rules, so nothing that adds an allow rule later can open them.
     Both programs also listen on 127.0.0.1 only (llama-server --host 127.0.0.1, the chat binds
     127.0.0.1:7860). A boot-time task re-asserts the rules at every start.
  2. Crash dumps: Windows Error Reporting excludes llama-server.exe and python.exe, so a crash dump
     (process memory = prompts and answers) is never uploaded.
  3. Edge (the Zero app window): Edge features that send what you type or what the page shows to
     Microsoft are off: Microsoft Editor enhanced spell check (local Windows spell check stays),
     text prediction, and Copilot page context. Everything else in Edge is untouched.
  4. Privacy toggles (the OOBE privacy page, all off): location, Find my device, diagnostic data
     (Required only: AllowTelemetry 0, which Windows Pro treats as 1), inking & typing, online speech
     recognition, tailored experiences, advertising ID.
  Telemetry/remote fetching inside the stack is off by configuration (run-llama.ps1: --offline,
  --no-webui, --cors-origins localhost; lecore_plus_chat.py: Host/Origin checks, CSP; sitecustomize.py:
  NLTK/Hugging Face offline). Provisioning and model downloads run on the imaging station.

  Modes:
    (default)            the running Windows (Administrator/SYSTEM): all of the above.
    -OfflineImage <dir>  a DISM-mounted image: parts 2-4 (registry) into its hives. The firewall rules
                         are added when the stack is installed (specialize pass), because the
                         programs do not exist in the image before that.
    -FirewallOnly        part 1 only (the boot-time task; also what CI applies to its runner: it blocks
                         only the two inference programs).
    -WhatIf              print every action, change nothing.

  The full live mode refuses to run on a CI runner (GITHUB_ACTIONS / RUNNER_NAME / TF_BUILD / CI) because it
  changes machine policy; use -WhatIf there, or -FirewallOnly.

  Windows PowerShell 5.1 compatible.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OfflineImage,
    [switch]$FirewallOnly,
    [switch]$InstallBootTask,
    [string]$InstallRoot = (Join-Path $env:ProgramFiles 'leCore+'),
    [string]$DataRoot = (Join-Path $env:ProgramData 'leCore+')
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Cmdlet = $PSCmdlet

$Live = -not $OfflineImage
$DryRun = [bool]$WhatIfPreference

# ---- guard: no machine-policy changes on a CI runner ------------------------------------------------
if ($Live -and -not $DryRun -and -not $FirewallOnly) {
    $ciVars = @('GITHUB_ACTIONS', 'RUNNER_NAME', 'TF_BUILD', 'CI') | Where-Object {
        $v = [Environment]::GetEnvironmentVariable($_); $v -and $v -ne 'false'
    }
    if ($ciVars) {
        throw ("Refusing to apply the full Zero lockdown to this machine: it looks like a CI runner " +
               "($($ciVars -join ', ') set). Use -WhatIf, -FirewallOnly (blocks only the two inference programs), or -OfflineImage.")
    }
}
if (-not $DryRun) {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'lockdown.ps1 must run elevated.' }
}
if ($OfflineImage) {
    $OfflineImage = (Resolve-Path -LiteralPath $OfflineImage).Path.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $OfflineImage 'Windows\System32\config\SOFTWARE'))) {
        throw "$OfflineImage does not look like a mounted Windows image"
    }
    $StateDir = Join-Path $OfflineImage 'ProgramData\leCore+\lockdown'
} else {
    $StateDir = Join-Path $DataRoot 'lockdown'
}

$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$Area, [string]$Item, [string]$Status, [string]$Detail = '') {
    $script:Results.Add([pscustomobject]@{ Area = $Area; Item = $Item; Status = $Status; Detail = $Detail })
    if ($Status -eq 'FAILED') { Write-Warning "$Area | $Item | $Detail" }
}
function Say([string]$m) { Write-Host ("[lockdown] {0}" -f $m) }

# ---- registry plumbing (live keys, or offline hives loaded under HKLM\LCP_*) -----------------------
$script:Loaded = New-Object System.Collections.Generic.List[string]

function Mount-Hive([string]$Name, [string]$File) {
    if ($DryRun) { Say "would load $File as HKLM\$Name"; return }
    & reg.exe load "HKLM\$Name" $File | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load HKLM\$Name $File failed" }
    $script:Loaded.Add($Name)
}
function Dismount-Hives {
    foreach ($n in @($script:Loaded)) {
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $ok = $false
        for ($i = 0; $i -lt 10 -and -not $ok; $i++) {
            & reg.exe unload "HKLM\$n" 2>$null | Out-Null
            $ok = ($LASTEXITCODE -eq 0)
            if (-not $ok) { Start-Sleep -Seconds 1 }
        }
        if (-not $ok) { Write-Warning "could not unload HKLM\$n" } else { $script:Loaded.Remove($n) | Out-Null }
    }
}

# Logical keys: SOFTWARE\... = HKLM\SOFTWARE ; DEFAULTUSER\... = C:\Users\Default\NTUSER.DAT (every account created later)
function Resolve-Key([string]$Key) {
    $root = [Microsoft.Win32.Registry]::LocalMachine
    if ($Key -like 'DEFAULTUSER\*') {
        if (-not ($script:Loaded -contains 'LCP_DEFAULT')) { return $null }
        return @{ Root = $root; Sub = 'LCP_DEFAULT\' + $Key.Substring(12) }
    }
    if ($Key -notlike 'SOFTWARE\*') { throw "unsupported key $Key" }
    if ($Live) { return @{ Root = $root; Sub = $Key } }
    if (-not ($script:Loaded -contains 'LCP_SOFTWARE')) { return $null }
    return @{ Root = $root; Sub = 'LCP_SOFTWARE\' + $Key.Substring(9) }
}

function Set-Reg([string]$Key, [string]$Name, $Value, [string]$Why, [string]$Kind = 'DWord') {
    $item = "$Key\$Name = $Value"
    if (-not $script:Cmdlet.ShouldProcess($item, "Set registry value ($Why)")) { Add-Result 'registry' $item 'whatif' $Why; return }
    $r = Resolve-Key $Key
    if ($null -eq $r) { Add-Result 'registry' $item 'skipped' 'hive not loaded'; return }
    try {
        $k = $r.Root.CreateSubKey($r.Sub)
        try { $k.SetValue($Name, $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $k.Close() }
        Add-Result 'registry' $item 'ok' $Why
    } catch {
        Add-Result 'registry' $item 'FAILED' $_.Exception.Message
    }
}

# ---- 1. firewall, per program -----------------------------------------------------------------------
$NonLoopback = @('0.0.0.0-126.255.255.255', '128.0.0.0-255.255.255.255', '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
$Contained = [ordered]@{
    'llama-server' = (Join-Path $InstallRoot 'llama\llama-server.exe')
    'python'       = (Join-Path $InstallRoot 'python\python.exe')
    'pythonw'      = (Join-Path $InstallRoot 'python\pythonw.exe')
}

function Invoke-Firewall {
    if ($script:Cmdlet.ShouldProcess('Domain,Private,Public', 'Set-NetFirewallProfile -Enabled True -DefaultOutboundAction Allow')) {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultOutboundAction Allow
        Add-Result 'firewall' 'profiles: enabled, default outbound Allow (the OS networks normally)' 'ok'
    } else { Add-Result 'firewall' 'profiles: enabled, default outbound Allow' 'whatif' }

    # An earlier Zero build blocked all outbound traffic; undo that if it is present.
    if (Get-NetFirewallRule -Name 'LecorePlus-ZeroEgress-Block' -ErrorAction SilentlyContinue) {
        if ($script:Cmdlet.ShouldProcess('LecorePlus-ZeroEgress-Block', 'Remove the old machine-wide outbound block rule')) {
            Remove-NetFirewallRule -Name 'LecorePlus-ZeroEgress-Block'; Add-Result 'firewall' 'removed old machine-wide block rule' 'ok'
        }
    }
    foreach ($prof in 'DomainProfile', 'PrivateProfile', 'PublicProfile') {
        $k = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\$prof"
        if ((Test-Path $k) -and (Get-ItemProperty -Path $k -Name DefaultOutboundAction -ErrorAction SilentlyContinue)) {
            if ($script:Cmdlet.ShouldProcess("$k\DefaultOutboundAction", 'Remove the old outbound-block policy')) {
                Remove-ItemProperty -Path $k -Name DefaultOutboundAction; Add-Result 'firewall' "removed old policy $prof\DefaultOutboundAction" 'ok'
            }
        }
    }

    foreach ($name in $Contained.Keys) {
        $prog = $Contained[$name]
        foreach ($dir in 'Outbound', 'Inbound') {
            $id = "LecorePlus-Contain-$name-$($dir.Substring(0, $dir.Length - 5))"
            $what = "$dir Block for $prog to/from every non-loopback address"
            if (-not $script:Cmdlet.ShouldProcess($id, $what)) { Add-Result 'firewall' "$id ($what)" 'whatif'; continue }
            try {
                Remove-NetFirewallRule -Name $id -ErrorAction SilentlyContinue
                New-NetFirewallRule -Name $id -DisplayName "Zero: $name stays on this machine ($($dir.ToLower()))" -Group 'Zero (leCore+)' `
                    -Description 'Zero model containment: the model input/output never leaves the machine. See C:\Program Files\leCore+\setup\README.md.' `
                    -Direction $dir -Action Block -Profile Any -Program $prog -RemoteAddress $NonLoopback -Enabled True | Out-Null
                Add-Result 'firewall' $id 'ok' $what
            } catch { Add-Result 'firewall' $id 'FAILED' $_.Exception.Message }
        }
    }

    if (-not $DryRun) {
        $prof = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { -not $_.Enabled -or $_.DefaultOutboundAction -ne 'Allow' })
        if ($prof.Count) { Add-Result 'firewall' 'verify profiles' 'FAILED' ('not enabled+Allow: ' + (($prof | ForEach-Object { $_.Name }) -join ', ')) }
        foreach ($name in $Contained.Keys) {
            foreach ($d in 'Out', 'In') {
                $id = "LecorePlus-Contain-$name-$d"
                $r = Get-NetFirewallRule -Name $id -ErrorAction SilentlyContinue
                $app = if ($r) { ($r | Get-NetFirewallApplicationFilter).Program } else { $null }
                if (-not $r -or $r.Enabled -ne 'True' -or $r.Action -ne 'Block' -or $app -ne $Contained[$name]) {
                    Add-Result 'firewall' "verify $id" 'FAILED' "rule missing or wrong (program=$app)"
                }
            }
        }
        if (-not @($script:Results | Where-Object { $_.Area -eq 'firewall' -and $_.Status -eq 'FAILED' }).Count) {
            Add-Result 'firewall' 'verify active store: profiles Allow, 6 containment rules on the right programs' 'ok'
        }
    }
}

function Register-BootTask {
    $script = Join-Path $InstallRoot 'setup\lockdown.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not $script:Cmdlet.ShouldProcess('\Zero\Zero model containment check', 'Register boot-time firewall check (SYSTEM)')) {
        Add-Result 'task' 'boot-time model containment check' 'whatif'; return
    }
    Unregister-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero zero-egress check' -Confirm:$false -ErrorAction SilentlyContinue
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -FirewallOnly' -f $script)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero model containment check' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Add-Result 'task' 'boot-time model containment check (\Zero\)' 'ok'
}

# ---- 2-4. registry -----------------------------------------------------------------------------------
function Invoke-Registry {
    $P = 'SOFTWARE\Policies\Microsoft'
    # 2. crash dumps of the inference programs are never uploaded
    foreach ($exe in 'llama-server.exe', 'python.exe', 'pythonw.exe') {
        Set-Reg "$P\Windows\Windows Error Reporting\ExcludedApplications" $exe $exe 'crash reports (process memory) of the inference programs are not sent' 'String'
        Set-Reg 'SOFTWARE\Microsoft\Windows\Windows Error Reporting\ExcludedApplications' $exe 1 'crash reports of the inference programs are not sent'
    }
    # 3. Edge features that send typed text or page content to Microsoft (the Zero window is an Edge app window)
    Set-Reg "$P\Edge" 'MicrosoftEditorProofingEnabled' 0 'Edge: no cloud spell/grammar check of what you type (Windows local spell check stays)'
    Set-Reg "$P\Edge" 'MicrosoftEditorSynonymsEnabled' 0 'Edge: no cloud synonyms for what you type'
    Set-Reg "$P\Edge" 'TextPredictionEnabled' 0 'Edge: no cloud text prediction of what you type'
    Set-Reg "$P\Edge" 'CopilotPageContext' 0 'Edge: Copilot cannot read the page'
    Set-Reg "$P\Edge" 'CopilotCDPPageContext' 0 'Edge: Copilot cannot read the page'
    # 4. privacy toggles (the OOBE privacy page), all off
    Set-Reg "$P\Windows\OOBE" 'DisablePrivacyExperience' 1 'privacy page not shown; the toggles below are set off'
    Set-Reg "$P\Windows\LocationAndSensors" 'DisableLocation' 1 'privacy: location off'
    Set-Reg "$P\FindMyDevice" 'AllowFindMyDevice' 0 'privacy: Find my device off'
    Set-Reg "$P\Windows\DataCollection" 'AllowTelemetry' 0 'privacy: diagnostic data Required only (Pro floor)'
    Set-Reg "$P\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 1 'privacy: no feedback prompts'
    Set-Reg "$P\InputPersonalization" 'AllowInputPersonalization' 0 'privacy: inking & typing personalization and online speech recognition off'
    Set-Reg "$P\InputPersonalization" 'RestrictImplicitInkCollection' 1 'privacy: inking & typing off'
    Set-Reg "$P\InputPersonalization" 'RestrictImplicitTextCollection' 1 'privacy: inking & typing off'
    Set-Reg "$P\Windows\TextInput" 'AllowLinguisticDataCollection' 0 'privacy: improve inking & typing off'
    Set-Reg "$P\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 1 'privacy: advertising ID off'
    $U = 'DEFAULTUSER\Software'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 0 'privacy: advertising ID off'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 0 'privacy: tailored experiences off'
    Set-Reg "$U\Policies\Microsoft\Windows\CloudContent" 'DisableTailoredExperiencesWithDiagnosticData' 1 'privacy: tailored experiences off'
    Set-Reg "$U\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 1 'privacy: inking & typing off'
    Set-Reg "$U\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 1 'privacy: inking & typing off'
    Set-Reg "$U\Microsoft\Personalization\Settings" 'AcceptedPrivacyPolicy' 0 'privacy: inking & typing off'
    Set-Reg "$U\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" 'HasAccepted' 0 'privacy: online speech recognition off'
}

# ---- run --------------------------------------------------------------------------------------------
Say ("mode: {0}{1}{2}" -f ($(if ($Live) { 'live' } else { "offline image $OfflineImage" })), $(if ($FirewallOnly) { ', firewall only' } else { '' }), $(if ($DryRun) { ', WhatIf (no changes)' } else { '' }))
try {
    if (-not $FirewallOnly) {
        if ($OfflineImage) { Mount-Hive 'LCP_SOFTWARE' (Join-Path $OfflineImage 'Windows\System32\config\SOFTWARE') }
        $ntuser = if ($Live) { Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT' } else { Join-Path $OfflineImage 'Users\Default\NTUSER.DAT' }
        Mount-Hive 'LCP_DEFAULT' $ntuser
        Invoke-Registry
    }
    if ($Live) { Invoke-Firewall }
    if ($Live -and $InstallBootTask) { Register-BootTask }
} finally {
    Dismount-Hives
}

$failed = @($script:Results | Where-Object { $_.Status -eq 'FAILED' })
$counts = $script:Results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
if ($DryRun) {
    foreach ($r in $script:Results) { Say ("WHATIF {0} | {1} | {2}" -f $r.Area, $r.Item, $r.Detail) }
}
Say ("results: " + ($counts -join ', '))
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $stamp = '{0:yyyyMMdd-HHmmss}' -f (Get-Date)
    $script:Results | Export-Csv -NoTypeInformation -Encoding UTF8 -LiteralPath (Join-Path $StateDir ("lockdown-{0}-{1}.csv" -f $(if ($Live) { 'live' } else { 'offline' }), $stamp))
}
$fwFailed = @($failed | Where-Object { $_.Area -eq 'firewall' })
if ($fwFailed.Count) { throw "model containment firewall rules FAILED: $(($fwFailed | ForEach-Object { $_.Item }) -join '; ')" }
if ($failed.Count) { Write-Warning "$($failed.Count) lockdown item(s) failed (see above); the firewall part succeeded." }
