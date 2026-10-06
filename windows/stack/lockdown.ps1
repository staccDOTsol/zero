<#
.SYNOPSIS
  Zero-egress lockdown for a Zero laptop (leCore+): the machine makes no outbound network connections.

.DESCRIPTION
  Applies, in order:
    1. Firewall: Windows Firewall on for Domain/Private/Public, DefaultOutboundAction = Block (local
       store and policy), every enabled outbound Allow rule disabled (names recorded so open-egress.ps1
       can restore them), and one explicit Block rule for every non-loopback address so an allow rule
       added later (an app, a new user's Store apps) still cannot reach out. Loopback (127.0.0.0/8,
       ::1) stays open: Edge -> 127.0.0.1:7860 -> 127.0.0.1:8080.
    2. Policies and services: Windows Update (wuauserv, UsoSvc, WaaSMedicSvc + policies), Delivery
       Optimization, telemetry (DiagTrack, dmwappushservice, AllowTelemetry=0, which Pro treats as 1
       "Required"), NCSI active probing, w32time + tzautoupdate, Store auto-update, Edge update
       services/tasks + Edge policies, Defender cloud protection (MAPS) + sample submission, Bing /
       web search in Start, OneDrive, Copilot + Recall, consumer features / suggested apps, error
       reporting, CEIP, activity history, location, advertising ID, inking/typing, settings sync,
       root-certificate auto-update, font providers, maps auto-update.
    3. Live only: scheduled tasks (Windows Update, Edge update, telemetry), Defender preferences.

  Modes:
    (default)            the running Windows (needs Administrator/SYSTEM).
    -OfflineImage <dir>  a mounted Windows image (DISM /Mount-Image): edits its SOFTWARE, SYSTEM and
                         default-user hives and removes Copilot / Recall / cloud-only apps with DISM.
                         This is how the CI build pre-locks the image so egress is blocked from the
                         very first boot.
    -FirewallOnly        re-assert just the firewall part (the boot-time "Zero zero-egress check" task).
    -WhatIf              print every action, change nothing (this is what CI runs on its runner).

  NEVER run this (without -WhatIf or -OfflineImage) on a CI runner: it would cut the runner off.
  It refuses to when GITHUB_ACTIONS / RUNNER_NAME / TF_BUILD / CI are set.

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

# ---- hard guard: never cut off a CI runner ---------------------------------------------------------
if ($Live -and -not $DryRun) {
    $ciVars = @('GITHUB_ACTIONS', 'RUNNER_NAME', 'TF_BUILD', 'CI') | Where-Object {
        $v = [Environment]::GetEnvironmentVariable($_); $v -and $v -ne 'false'
    }
    if ($ciVars) {
        throw ("Refusing to apply the zero-egress lockdown to this machine: it looks like a CI runner " +
               "($($ciVars -join ', ') set) and the lockdown would cut it off. Use -WhatIf, or -OfflineImage <mounted image>.")
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
$script:ControlSet = 'CurrentControlSet'

function Mount-Hive([string]$Name, [string]$File) {
    if ($DryRun) { Say "would load $File as HKLM\$Name"; return $false }
    & reg.exe load "HKLM\$Name" $File | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg load HKLM\$Name $File failed" }
    $script:Loaded.Add($Name)
    return $true
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

# Logical key prefixes used below:
#   SOFTWARE\...                       HKLM\SOFTWARE
#   SYSTEM\CurrentControlSet\...       HKLM\SYSTEM\CurrentControlSet (offline: the image's current control set)
#   DEFAULTUSER\...                    C:\Users\Default\NTUSER.DAT (applies to every account created later)
function Resolve-Key([string]$Key) {
    $root = [Microsoft.Win32.Registry]::LocalMachine
    if ($Key -like 'DEFAULTUSER\*') {
        if (-not ($script:Loaded -contains 'LCP_DEFAULT')) { return $null }
        return @{ Root = $root; Sub = 'LCP_DEFAULT\' + $Key.Substring(12) }
    }
    if ($Live) {
        return @{ Root = $root; Sub = $Key }
    }
    if ($Key -like 'SOFTWARE\*') {
        if (-not ($script:Loaded -contains 'LCP_SOFTWARE')) { return $null }
        return @{ Root = $root; Sub = 'LCP_SOFTWARE\' + $Key.Substring(9) }
    }
    if ($Key -like 'SYSTEM\CurrentControlSet\*') {
        if (-not ($script:Loaded -contains 'LCP_SYSTEM')) { return $null }
        return @{ Root = $root; Sub = 'LCP_SYSTEM\' + $script:ControlSet + '\' + $Key.Substring(25) }
    }
    throw "unsupported key $Key"
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

function Remove-RegValue([string]$Key, [string]$Name, [string]$Why) {
    $item = "$Key\$Name"
    if (-not $script:Cmdlet.ShouldProcess($item, "Remove registry value ($Why)")) { Add-Result 'registry' "remove $item" 'whatif' $Why; return }
    $r = Resolve-Key $Key
    if ($null -eq $r) { Add-Result 'registry' "remove $item" 'skipped' 'hive not loaded'; return }
    $k = $r.Root.OpenSubKey($r.Sub, $true)
    if ($null -eq $k) { Add-Result 'registry' "remove $item" 'absent'; return }
    try {
        if ($k.GetValueNames() -contains $Name) { $k.DeleteValue($Name); Add-Result 'registry' "remove $item" 'ok' $Why }
        else { Add-Result 'registry' "remove $item" 'absent' }
    } finally { $k.Close() }
}

function Disable-Svc([string]$Name, [string]$Why) {
    $key = "SYSTEM\CurrentControlSet\Services\$Name"
    if (-not $DryRun) {
        $r = Resolve-Key $key
        if ($null -eq $r) { Add-Result 'service' $Name 'skipped' 'hive not loaded'; return }
        $k = $r.Root.OpenSubKey($r.Sub)
        if ($null -eq $k) { Add-Result 'service' $Name 'absent'; return }
        $k.Close()
    }
    if (-not $script:Cmdlet.ShouldProcess($Name, "Disable service ($Why)")) { Add-Result 'service' $Name 'whatif' $Why; return }
    $done = $false
    if ($Live) {
        try { Set-Service -Name $Name -StartupType Disabled -ErrorAction Stop; $done = $true } catch { }
    }
    if (-not $done) {
        # Protected services (WaaSMedicSvc, UsoSvc) refuse Set-Service; the registry value still takes effect at boot.
        $r = Resolve-Key $key
        try {
            $k = $r.Root.OpenSubKey($r.Sub, $true)
            try { $k.SetValue('Start', 4, [Microsoft.Win32.RegistryValueKind]::DWord) } finally { $k.Close() }
            $done = $true
        } catch {
            Add-Result 'service' $Name 'FAILED' $_.Exception.Message
            return
        }
    }
    if ($Live) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    Add-Result 'service' $Name 'ok' $Why
}

# ---- firewall ----------------------------------------------------------------------------------------
$BlockRuleName = 'LecorePlus-ZeroEgress-Block'
$NonLoopback = @('0.0.0.0-126.255.255.255', '128.0.0.0-255.255.255.255',
                 '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')

function Set-FirewallPolicyKeys {
    foreach ($prof in 'DomainProfile', 'PrivateProfile', 'PublicProfile') {
        $k = "SOFTWARE\Policies\Microsoft\WindowsFirewall\$prof"
        Set-Reg $k 'EnableFirewall' 1 'firewall on (policy)'
        Set-Reg $k 'DefaultOutboundAction' 1 'block outbound by default (policy)'
        Set-Reg $k 'DefaultInboundAction' 1 'block unsolicited inbound (policy)'
    }
}

function Invoke-FirewallOffline {
    Set-FirewallPolicyKeys
    $fp = 'SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
    foreach ($prof in 'DomainProfile', 'StandardProfile', 'PublicProfile') {
        Set-Reg "$fp\$prof" 'EnableFirewall' 1 'firewall on'
        Set-Reg "$fp\$prof" 'DefaultOutboundAction' 1 'block outbound by default'
        Set-Reg "$fp\$prof" 'DefaultInboundAction' 1 'block unsolicited inbound'
    }
    if ($DryRun) { Add-Result 'firewall' 'disable every enabled outbound Allow rule in the image' 'whatif'; return }
    $r = Resolve-Key "$fp\FirewallRules"
    $k = $r.Root.OpenSubKey($r.Sub, $true)
    if ($null -eq $k) { Add-Result 'firewall' 'FirewallRules key' 'FAILED' 'not found in image'; return }
    $disabled = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($n in $k.GetValueNames()) {
            $v = [string]$k.GetValue($n)
            if ($v -match '\|Dir=Out\|' -and $v -match '\|Action=Allow\|' -and $v -match '\|Active=TRUE\|') {
                $k.SetValue($n, ($v -replace '\|Active=TRUE\|', '|Active=FALSE|'), [Microsoft.Win32.RegistryValueKind]::String)
                $disabled.Add($n)
            }
        }
    } finally { $k.Close() }
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    [IO.File]::WriteAllLines((Join-Path $StateDir 'outbound-rules-disabled-offline.txt'), [string[]]$disabled)
    Add-Result 'firewall' "disabled $($disabled.Count) outbound Allow rules in the image" 'ok' 'recorded in ProgramData\leCore+\lockdown'
}

function Invoke-FirewallLive {
    Set-FirewallPolicyKeys
    if ($script:Cmdlet.ShouldProcess('Domain,Private,Public', 'Set-NetFirewallProfile -Enabled True -DefaultOutboundAction Block -DefaultInboundAction Block')) {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True -DefaultOutboundAction Block -DefaultInboundAction Block
        Add-Result 'firewall' 'profiles: enabled, outbound Block' 'ok'
    } else { Add-Result 'firewall' 'profiles: enabled, outbound Block' 'whatif' }

    $allow = @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Outbound -Action Allow -Enabled True -ErrorAction SilentlyContinue)
    if ($script:Cmdlet.ShouldProcess("$($allow.Count) enabled outbound Allow rules", 'Disable-NetFirewallRule (names recorded for open-egress.ps1)')) {
        if ($allow.Count -gt 0) {
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
            $log = Join-Path $StateDir 'outbound-rules-disabled.txt'
            $prev = @(); if (Test-Path -LiteralPath $log) { $prev = @(Get-Content -LiteralPath $log) }
            [IO.File]::WriteAllLines($log, [string[]](@($prev) + @($allow | ForEach-Object { $_.Name }) | Sort-Object -Unique))
            $allow | Disable-NetFirewallRule
        }
        Add-Result 'firewall' "disabled $($allow.Count) outbound Allow rules" 'ok'
    } else { Add-Result 'firewall' "disable $($allow.Count) outbound Allow rules" 'whatif' }

    $existing = Get-NetFirewallRule -Name $BlockRuleName -ErrorAction SilentlyContinue
    if ($script:Cmdlet.ShouldProcess($BlockRuleName, "Block outbound to $($NonLoopback -join ', ')")) {
        if ($existing) { Remove-NetFirewallRule -Name $BlockRuleName }
        New-NetFirewallRule -Name $BlockRuleName -DisplayName 'Zero: block all non-loopback outbound traffic (zero egress)' `
            -Group 'Zero (leCore+)' -Description 'Zero-egress lockdown. Remove with C:\Program Files\leCore+\setup\open-egress.ps1.' `
            -Direction Outbound -Action Block -Profile Any -RemoteAddress $NonLoopback -Enabled True | Out-Null
        Add-Result 'firewall' "block rule $BlockRuleName" 'ok'
    } else { Add-Result 'firewall' "block rule $BlockRuleName" 'whatif' }

    if (-not $DryRun) {
        $bad = @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { -not $_.Enabled -or $_.DefaultOutboundAction -ne 'Block' })
        if ($bad.Count) { Add-Result 'firewall' 'verify active store' 'FAILED' ("not blocking: " + (($bad | ForEach-Object { $_.Name }) -join ', ')) }
        else { Add-Result 'firewall' 'verify active store: all profiles enabled + outbound Block' 'ok' }
    }
}

function Register-BootTask {
    $script = Join-Path $InstallRoot 'setup\lockdown.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not $script:Cmdlet.ShouldProcess('\Zero\Zero zero-egress check', 'Register boot-time firewall check (SYSTEM)')) {
        Add-Result 'task' 'boot-time zero-egress check' 'whatif'; return
    }
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -FirewallOnly' -f $script)
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero zero-egress check' -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Add-Result 'task' 'boot-time zero-egress check (\Zero\)' 'ok'
}

# ---- what gets switched off ---------------------------------------------------------------------------
function Invoke-Policies {
    $P = 'SOFTWARE\Policies\Microsoft'
    # Windows Update (Windows Update never runs; drivers are in the image)
    Set-Reg "$P\Windows\WindowsUpdate\AU" 'NoAutoUpdate' 1 'Windows Update: no automatic updates'
    Set-Reg "$P\Windows\WindowsUpdate\AU" 'AUOptions' 1 'Windows Update: never check'
    Set-Reg "$P\Windows\WindowsUpdate" 'DoNotConnectToWindowsUpdateInternetLocations' 1 'Windows Update: no internet locations'
    Set-Reg "$P\Windows\WindowsUpdate" 'DisableWindowsUpdateAccess' 1 'Windows Update: hide access'
    Set-Reg "$P\Windows\WindowsUpdate" 'SetDisableUXWUAccess' 1 'Windows Update: no scan UI'
    Set-Reg "$P\Windows\WindowsUpdate" 'ExcludeWUDriversInQualityUpdate' 1 'Windows Update: no driver updates'
    Set-Reg "$P\Windows\WindowsUpdate" 'DisableOSUpgrade' 1 'Windows Update: no feature upgrades'
    Set-Reg "$P\Windows\DriverSearching" 'DontSearchWindowsUpdate' 1 'no driver search on Windows Update'
    Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 0 'no driver search on Windows Update'
    Set-Reg "$P\Windows\Device Metadata" 'PreventDeviceMetadataFromNetwork' 1 'no device metadata downloads'
    # Delivery Optimization
    Set-Reg "$P\Windows\DeliveryOptimization" 'DODownloadMode' 99 'Delivery Optimization: simple mode, no peers, no DO cloud'
    # Telemetry (Windows Pro honours 0 as 1 = "Required" diagnostic data; DiagTrack is disabled below so nothing is sent)
    Set-Reg "$P\Windows\DataCollection" 'AllowTelemetry' 0 'telemetry: lowest level (Pro floor is Required)'
    Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0 'telemetry: lowest level'
    Set-Reg "$P\Windows\DataCollection" 'DoNotShowFeedbackNotifications' 1 'no feedback prompts'
    Set-Reg "$P\Windows\DataCollection" 'DisableOneSettingsDownloads' 1 'no OneSettings downloads'
    Set-Reg "$P\Windows\DataCollection" 'AllowDeviceNameInTelemetry' 0 'no device name in diagnostics'
    Set-Reg "$P\Windows\DataCollection" 'LimitDiagnosticLogCollection' 1 'no diagnostic log collection'
    Set-Reg "$P\Windows\DataCollection" 'LimitDumpCollection' 1 'no dump collection'
    Set-Reg "$P\SQMClient\Windows" 'CEIPEnable' 0 'no Customer Experience Improvement Program'
    Set-Reg "$P\Windows\AppCompat" 'AITEnable' 0 'no application telemetry'
    Set-Reg "$P\Windows\AppCompat" 'DisableInventory' 1 'no inventory collector'
    Set-Reg "$P\Windows\Windows Error Reporting" 'Disabled' 1 'no error reporting'
    Set-Reg 'SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1 'no error reporting'
    # OOBE / privacy settings (all off)
    Set-Reg "$P\Windows\OOBE" 'DisablePrivacyExperience' 1 'privacy settings page not shown; policies below set them off'
    Set-Reg "$P\Windows\AdvertisingInfo" 'DisabledByGroupPolicy' 1 'advertising ID off'
    Set-Reg "$P\Windows\LocationAndSensors" 'DisableLocation' 1 'location off'
    Set-Reg "$P\Windows\LocationAndSensors" 'DisableWindowsLocationProvider' 1 'location provider off'
    Set-Reg "$P\FindMyDevice" 'AllowFindMyDevice' 0 'Find my device off'
    Set-Reg "$P\InputPersonalization" 'AllowInputPersonalization' 0 'inking & typing / online speech off'
    Set-Reg "$P\InputPersonalization" 'RestrictImplicitInkCollection' 1 'inking & typing off'
    Set-Reg "$P\InputPersonalization" 'RestrictImplicitTextCollection' 1 'inking & typing off'
    Set-Reg "$P\Windows\TextInput" 'AllowLinguisticDataCollection' 0 'no typing data upload'
    Set-Reg "$P\Speech" 'AllowSpeechModelUpdate' 0 'no speech model downloads'
    Set-Reg "$P\Windows\System" 'EnableActivityFeed' 0 'activity history off'
    Set-Reg "$P\Windows\System" 'PublishUserActivities' 0 'activity history off'
    Set-Reg "$P\Windows\System" 'UploadUserActivities' 0 'activity history off'
    Set-Reg "$P\Windows\System" 'EnableSmartScreen' 0 'SmartScreen (cloud lookups) off'
    Set-Reg "$P\Windows\System" 'EnableFontProviders' 0 'no online font providers'
    Set-Reg 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'SmartScreenEnabled' 'Off' 'SmartScreen for apps/files off' 'String'
    Set-Reg "$P\Windows\SettingSync" 'DisableSettingSync' 2 'settings sync off'
    Set-Reg "$P\Windows\SettingSync" 'DisableSettingSyncUserOverride' 1 'settings sync off'
    Set-Reg "$P\Windows\CloudContent" 'DisableWindowsConsumerFeatures' 1 'consumer features off (Enterprise/Education honour this; Pro also gets the per-user settings below)'
    Set-Reg "$P\Windows\CloudContent" 'DisableCloudOptimizedContent' 1 'no cloud-optimized content'
    Set-Reg "$P\Windows\CloudContent" 'DisableConsumerAccountStateContent' 1 'no account-state content'
    Set-Reg "$P\Windows\CloudContent" 'DisableSoftLanding' 1 'no tips'
    Set-Reg "$P\Dsh" 'AllowNewsAndInterests' 0 'Widgets (news feed) off'
    Set-Reg "$P\Windows\Maps" 'AutoDownloadAndUpdateMapData' 0 'no map downloads'
    Set-Reg "$P\Windows\Maps" 'AllowUntriggeredNetworkTrafficOnSettingsPage' 0 'no map traffic'
    Set-Reg "$P\SystemCertificates\AuthRoot" 'DisableRootAutoUpdate' 1 'no root certificate auto-update downloads'
    Set-Reg "$P\Windows\PreviewBuilds" 'AllowBuildPreview' 0 'no Insider builds'
    Set-Reg 'SOFTWARE\Policies\Microsoft\Windows NT\CurrentVersion\Software Protection Platform' 'NoGenTicket' 1 'no online license validation ticket'
    Set-Reg "$P\Windows\CurrentVersion\PushNotifications" 'NoCloudApplicationNotification' 1 'no cloud push notifications'
    # NCSI active probing (msftconnecttest.com)
    Set-Reg "$P\Windows\NetworkConnectivityStatusIndicator" 'NoActiveProbe' 1 'NCSI: no active probing'
    Set-Reg 'SYSTEM\CurrentControlSet\Services\NlaSvc\Parameters\Internet' 'EnableActiveProbing' 0 'NCSI: no active probing'
    # Time sync
    Set-Reg "$P\W32Time\TimeProviders\NtpClient" 'Enabled' 0 'no NTP'
    # Store
    Set-Reg "$P\WindowsStore" 'AutoDownload' 2 'Store: no automatic app updates'
    Set-Reg "$P\WindowsStore" 'DisableOSUpgrade' 1 'Store: no OS upgrade offers'
    # Search in Start: local only
    Set-Reg "$P\Windows\Windows Search" 'AllowCortana' 0 'no Cortana'
    Set-Reg "$P\Windows\Windows Search" 'AllowCloudSearch' 0 'no cloud search'
    Set-Reg "$P\Windows\Windows Search" 'ConnectedSearchUseWeb' 0 'no web results in Start'
    Set-Reg "$P\Windows\Windows Search" 'DisableWebSearch' 1 'no Bing/web search in Start'
    Set-Reg "$P\Windows\Windows Search" 'EnableDynamicContentInWSB' 0 'no search highlights'
    Set-Reg "$P\Windows\Explorer" 'DisableSearchBoxSuggestions' 1 'no web suggestions in Start'
    # OneDrive
    Set-Reg "$P\Windows\OneDrive" 'DisableFileSyncNGSC' 1 'OneDrive off'
    Set-Reg "$P\Windows\OneDrive" 'KFMBlockOptIn' 1 'no OneDrive folder backup'
    # Copilot / Recall / Click to Do
    Set-Reg "$P\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1 'Copilot off'
    Set-Reg "$P\Windows\WindowsAI" 'DisableAIDataAnalysis' 1 'Recall snapshots off'
    Set-Reg "$P\Windows\WindowsAI" 'AllowRecallEnablement' 0 'Recall cannot be enabled'
    Set-Reg "$P\Windows\WindowsAI" 'DisableClickToDo' 1 'Click to Do off'
    # Defender: keep the local engine, stop cloud protection and sample upload. Signature updates then
    # need manual offline packages (see windows/README.md). With Tamper Protection on, Windows ignores
    # these two policies; the firewall still blocks the traffic.
    Set-Reg "$P\Windows Defender\Spynet" 'SpynetReporting' 0 'Defender cloud protection (MAPS) off'
    Set-Reg "$P\Windows Defender\Spynet" 'SubmitSamplesConsent' 2 'Defender sample submission: never'
    Set-Reg "$P\Windows Defender\Spynet" 'DisableBlockAtFirstSeen' 1 'Defender block-at-first-sight (cloud) off'
    Set-Reg "$P\MRT" 'DontReportInfectionInformation' 1 'MSRT: no reporting'
    # Edge updates + Edge policies
    Set-Reg "$P\EdgeUpdate" 'UpdateDefault' 0 'Edge/WebView2: no updates'
    Set-Reg "$P\EdgeUpdate" 'AutoUpdateCheckPeriodMinutes' 0 'Edge: no update checks'
    Set-Reg "$P\EdgeUpdate" 'Update{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}' 0 'Edge Stable: no updates'
    Set-Reg "$P\EdgeUpdate" 'Update{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' 0 'WebView2: no updates'
    $edge = [ordered]@{
        BrowserSignin = 0; SyncDisabled = 1; ImplicitSignInEnabled = 0; LinkedAccountEnabled = 0
        SmartScreenEnabled = 0; SmartScreenPuaEnabled = 0; TyposquattingCheckerEnabled = 0
        DiagnosticData = 0; PersonalizationReportingEnabled = 0; UserFeedbackAllowed = 0
        ExperimentationAndConfigurationServiceControl = 0; ComponentUpdatesEnabled = 0
        ResolveNavigationErrorsUseWebService = 0; AlternateErrorPagesEnabled = 0; NetworkPredictionOptions = 2
        SearchSuggestEnabled = 0; AddressBarMicrosoftSearchInBingProviderEnabled = 0; LocalProvidersEnabled = 0
        HubsSidebarEnabled = 0; Microsoft365CopilotChatIconEnabled = 0; CopilotPageContext = 0; CopilotCDPPageContext = 0
        EdgeShoppingAssistantEnabled = 0; ShowRecommendationsEnabled = 0; SpotlightExperiencesAndRecommendationsEnabled = 0
        ShowMicrosoftRewards = 0; PromotionalTabsEnabled = 0; EdgeCollectionsEnabled = 0; EdgeFollowEnabled = 0
        NewTabPageContentEnabled = 0; NewTabPageQuickLinksEnabled = 0; NewTabPageHideDefaultTopSites = 1
        HideFirstRunExperience = 1; AutoImportAtFirstRun = 4; BackgroundModeEnabled = 0; StartupBoostEnabled = 0
        TranslateEnabled = 0; PaymentMethodQueryEnabled = 0; ConfigureDoNotTrack = 1; WebWidgetAllowed = 0
        ConfigureOnlineTextToSpeech = 0; EdgeEnhanceImagesEnabled = 0; FamilySafetySettingsEnabled = 0
    }
    foreach ($n in $edge.Keys) { Set-Reg "$P\Edge" $n $edge[$n] 'Edge: no sign-in/sync/SmartScreen/telemetry/online features' }
}

function Invoke-DefaultUser {
    $U = 'DEFAULTUSER\Software'
    $cdm = "$U\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
    foreach ($n in 'ContentDeliveryAllowed', 'FeatureManagementEnabled', 'OemPreInstalledAppsEnabled', 'PreInstalledAppsEnabled',
                   'PreInstalledAppsEverEnabled', 'SilentInstalledAppsEnabled', 'SoftLandingEnabled', 'SubscribedContentEnabled',
                   'SystemPaneSuggestionsEnabled', 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled',
                   'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled', 'SubscribedContent-338389Enabled',
                   'SubscribedContent-338393Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled') {
        Set-Reg $cdm $n 0 'no suggested apps / consumer content'
    }
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\AdvertisingInfo" 'Enabled' 0 'advertising ID off'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\Privacy" 'TailoredExperiencesWithDiagnosticDataEnabled' 0 'tailored experiences off'
    Set-Reg "$U\Microsoft\InputPersonalization" 'RestrictImplicitInkCollection' 1 'inking & typing off'
    Set-Reg "$U\Microsoft\InputPersonalization" 'RestrictImplicitTextCollection' 1 'inking & typing off'
    Set-Reg "$U\Microsoft\InputPersonalization\TrainedDataStore" 'HarvestContacts' 0 'inking & typing off'
    Set-Reg "$U\Microsoft\Personalization\Settings" 'AcceptedPrivacyPolicy' 0 'inking & typing off'
    Set-Reg "$U\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy" 'HasAccepted' 0 'online speech recognition off'
    Set-Reg "$U\Microsoft\Siuf\Rules" 'NumberOfSIUFInPeriod' 0 'no feedback requests'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\Search" 'BingSearchEnabled' 0 'no Bing in Start'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\Search" 'CortanaConsent' 0 'no Cortana'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\AppHost" 'EnableWebContentEvaluation' 0 'no SmartScreen lookups for apps'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'Start_IrisRecommendations' 0 'no Start recommendations'
    Set-Reg "$U\Microsoft\Windows\CurrentVersion\Explorer\Advanced" 'ShowCopilotButton' 0 'no Copilot button'
    Set-Reg "$U\Policies\Microsoft\Windows\Explorer" 'DisableSearchBoxSuggestions' 1 'no web suggestions in Start'
    Set-Reg "$U\Policies\Microsoft\Windows\CloudContent" 'DisableTailoredExperiencesWithDiagnosticData' 1 'tailored experiences off'
    Set-Reg "$U\Policies\Microsoft\Windows\CloudContent" 'DisableWindowsSpotlightFeatures' 1 'Spotlight off'
    Set-Reg "$U\Policies\Microsoft\Windows\CloudContent" 'DisableThirdPartySuggestions' 1 'no third-party suggestions'
    Set-Reg "$U\Policies\Microsoft\Windows\WindowsCopilot" 'TurnOffWindowsCopilot' 1 'Copilot off'
    Set-Reg "$U\Policies\Microsoft\Windows\WindowsAI" 'DisableAIDataAnalysis' 1 'Recall snapshots off'
    Set-Reg "$U\Policies\Microsoft\Windows\CurrentVersion\PushNotifications" 'NoCloudApplicationNotification' 1 'no cloud push notifications'
    Remove-RegValue "$U\Microsoft\Windows\CurrentVersion\Run" 'OneDriveSetup' 'OneDrive setup does not run for new users'
}

function Invoke-Services {
    $svc = [ordered]@{
        wuauserv = 'Windows Update'; UsoSvc = 'Update Orchestrator'; WaaSMedicSvc = 'Windows Update Medic'
        DoSvc = 'Delivery Optimization'; DiagTrack = 'Connected User Experiences and Telemetry'
        dmwappushservice = 'WAP push message routing (telemetry)'; W32Time = 'Windows Time (NTP)'
        tzautoupdate = 'automatic time zone (location lookup)'; edgeupdate = 'Edge update'; edgeupdatem = 'Edge update'
        InstallService = 'Microsoft Store install service (auto-updates)'; WerSvc = 'Windows Error Reporting'
        MapsBroker = 'downloaded maps manager'; wisvc = 'Windows Insider service'; RetailDemo = 'retail demo'
        lfsvc = 'geolocation'; OneSyncSvc = 'sync host'
    }
    foreach ($n in $svc.Keys) { Disable-Svc $n $svc[$n] }
}

function Invoke-ScheduledTasks {
    $patterns = @(
        @('\Microsoft\Windows\WindowsUpdate\', '*'), @('\Microsoft\Windows\UpdateOrchestrator\', '*'),
        @('\Microsoft\Windows\WaaSMedic\', '*'), @('\', 'MicrosoftEdgeUpdate*'),
        @('\Microsoft\Windows\Application Experience\', '*'), @('\Microsoft\Windows\Customer Experience Improvement Program\', '*'),
        @('\Microsoft\Windows\Feedback\Siuf\', '*'), @('\Microsoft\Windows\Windows Error Reporting\', '*'),
        @('\Microsoft\Windows\Time Synchronization\', '*'), @('\Microsoft\Windows\Maps\', '*'),
        @('\Microsoft\Windows\InstallService\', '*'), @('\Microsoft\Windows\Flighting\FeatureConfig\', '*'),
        @('\Microsoft\Windows\Flighting\OneSettings\', '*'), @('\Microsoft\Windows\Autochk\', 'Proxy'),
        @('\Microsoft\Windows\DiskDiagnostic\', 'Microsoft-Windows-DiskDiagnosticDataCollector'),
        @('\Microsoft\Windows\Device Information\', '*'), @('\Microsoft\Windows\CloudExperienceHost\', '*')
    )
    foreach ($pt in $patterns) {
        $tasks = @(Get-ScheduledTask -TaskPath $pt[0] -TaskName $pt[1] -ErrorAction SilentlyContinue | Where-Object { $_.State -ne 'Disabled' })
        foreach ($t in $tasks) {
            $item = "$($t.TaskPath)$($t.TaskName)"
            if (-not $script:Cmdlet.ShouldProcess($item, 'Disable scheduled task')) { Add-Result 'task' $item 'whatif'; continue }
            try { Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null; Add-Result 'task' $item 'ok' }
            catch { Add-Result 'task' $item 'warn' ("protected: " + $_.Exception.Message) }
        }
    }
}

function Invoke-Defender {
    $mp = Get-Command Set-MpPreference -ErrorAction SilentlyContinue
    $svc = Get-Service -Name WinDefend -ErrorAction SilentlyContinue
    if (-not $mp -or -not $svc -or $svc.Status -ne 'Running') { Add-Result 'defender' 'MAPS / sample submission preferences' 'skipped' 'Defender not running'; return }
    if (-not $script:Cmdlet.ShouldProcess('Microsoft Defender', 'Set-MpPreference -MAPSReporting 0 -SubmitSamplesConsent 2')) {
        Add-Result 'defender' 'MAPS off, sample submission never' 'whatif'; return
    }
    try {
        Set-MpPreference -MAPSReporting 0 -SubmitSamplesConsent 2 -ErrorAction Stop
        $now = Get-MpPreference
        if ($now.MAPSReporting -eq 0 -and $now.SubmitSamplesConsent -eq 2) { Add-Result 'defender' 'MAPS off, sample submission never' 'ok' }
        else { Add-Result 'defender' 'MAPS off, sample submission never' 'warn' "not applied (Tamper Protection?): MAPSReporting=$($now.MAPSReporting) SubmitSamplesConsent=$($now.SubmitSamplesConsent); firewall still blocks it" }
    } catch { Add-Result 'defender' 'MAPS off, sample submission never' 'warn' $_.Exception.Message }
}

$CloudApps = @('Microsoft.Copilot', 'Microsoft.Windows.Ai.Copilot.Provider', 'Microsoft.BingNews', 'Microsoft.BingWeather',
               'Microsoft.BingSearch', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.OutlookForWindows', 'MSTeams',
               'Clipchamp.Clipchamp', 'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.GetHelp',
               'MicrosoftCorporationII.QuickAssist', 'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.YourPhone',
               'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.Windows.DevHome', 'Microsoft.StartExperiencesApp')

function Invoke-AppsAndFeatures {
    # DISM operations run before any hive is loaded (DISM needs the image's hives itself).
    $scope = if ($Live) { @{ Online = $true } } else { @{ Path = $OfflineImage } }
    $prov = @()
    try { $prov = @(Get-AppxProvisionedPackage @scope -ErrorAction Stop) } catch { Add-Result 'apps' 'list provisioned apps' 'warn' $_.Exception.Message }
    foreach ($a in $prov) {
        if ($CloudApps -notcontains $a.DisplayName) { continue }
        if (-not $script:Cmdlet.ShouldProcess($a.PackageName, 'Remove provisioned app (cloud-only consumer app)')) { Add-Result 'apps' $a.DisplayName 'whatif'; continue }
        try { Remove-AppxProvisionedPackage @scope -PackageName $a.PackageName -ErrorAction Stop | Out-Null; Add-Result 'apps' "removed $($a.DisplayName)" 'ok' }
        catch { Add-Result 'apps' $a.DisplayName 'warn' $_.Exception.Message }
    }
    try { $f = Get-WindowsOptionalFeature @scope -FeatureName 'Recall' -ErrorAction Stop } catch { $f = $null }
    if ($null -eq $f) { Add-Result 'feature' 'Recall' 'absent' }
    elseif ($f.State -like 'Disabled*') { Add-Result 'feature' 'Recall' 'ok' "already $($f.State)" }
    elseif ($script:Cmdlet.ShouldProcess('Recall', 'Disable-WindowsOptionalFeature -Remove')) {
        try { Disable-WindowsOptionalFeature @scope -FeatureName 'Recall' -Remove -NoRestart -ErrorAction Stop | Out-Null; Add-Result 'feature' 'Recall removed' 'ok' }
        catch { Add-Result 'feature' 'Recall' 'warn' $_.Exception.Message }
    } else { Add-Result 'feature' 'Recall' 'whatif' }
}

# ---- run --------------------------------------------------------------------------------------------
Say ("mode: {0}{1}{2}" -f ($(if ($Live) { 'live' } else { "offline image $OfflineImage" })), $(if ($FirewallOnly) { ', firewall only' } else { '' }), $(if ($DryRun) { ', WhatIf (no changes)' } else { '' }))
try {
    if (-not $FirewallOnly) { Invoke-AppsAndFeatures }

    if ($OfflineImage) {
        if (Mount-Hive 'LCP_SOFTWARE' (Join-Path $OfflineImage 'Windows\System32\config\SOFTWARE')) { }
        if (Mount-Hive 'LCP_SYSTEM' (Join-Path $OfflineImage 'Windows\System32\config\SYSTEM')) {
            $sel = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('LCP_SYSTEM\Select')
            $script:ControlSet = 'ControlSet{0:D3}' -f [int]$sel.GetValue('Current'); $sel.Close()
            Say "offline control set: $script:ControlSet"
        }
    }
    if (-not $FirewallOnly) {
        $ntuser = if ($Live) { Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT' } else { Join-Path $OfflineImage 'Users\Default\NTUSER.DAT' }
        Mount-Hive 'LCP_DEFAULT' $ntuser | Out-Null
    }

    if ($Live) { Invoke-FirewallLive } else { Invoke-FirewallOffline }
    if (-not $FirewallOnly) {
        Invoke-Policies
        Invoke-DefaultUser
        Invoke-Services
        if ($Live) { Invoke-ScheduledTasks; Invoke-Defender }
    }
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
if ($fwFailed.Count) { throw "zero-egress firewall lockdown FAILED: $(($fwFailed | ForEach-Object { $_.Item }) -join '; ')" }
if ($failed.Count) { Write-Warning "$($failed.Count) lockdown item(s) failed (see above); the firewall part succeeded." }
