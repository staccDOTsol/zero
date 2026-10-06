<#
.SYNOPSIS
  Deliberately opens network egress on a Zero laptop (undoes the firewall part of lockdown.ps1).

.DESCRIPTION
  For the OWNER, on purpose. Run from an elevated PowerShell:

      & 'C:\Program Files\leCore+\setup\open-egress.ps1'                 # firewall only
      & 'C:\Program Files\leCore+\setup\open-egress.ps1' -WindowsUpdate  # ...and turn Windows Update back on
      & 'C:\Program Files\leCore+\setup\open-egress.ps1' -TimeSync       # ...and NTP time sync

  What it does:
    * removes the "Zero: block all non-loopback outbound traffic" rule,
    * sets DefaultOutboundAction back to Allow (local store) and removes the firewall policy values,
    * re-enables the outbound Allow rules lockdown.ps1 disabled (it recorded their names),
    * disables the boot-time "Zero zero-egress check" task, so the next boot does not close egress again.
  Everything else (telemetry, Edge, Copilot, consumer features) stays off. To close egress again,
  run C:\Program Files\leCore+\setup\lockdown.ps1 (it re-enables the boot-time check).

  Windows PowerShell 5.1 compatible.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$WindowsUpdate,
    [switch]$TimeSync,
    [string]$DataRoot = (Join-Path $env:ProgramData 'leCore+')
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$state = Join-Path $DataRoot 'lockdown'

if (-not $PSCmdlet.ShouldProcess('this computer', 'Open outbound network access (undo the Zero zero-egress firewall lockdown)')) { return }

$task = Get-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero zero-egress check' -ErrorAction SilentlyContinue
if ($task) { Disable-ScheduledTask -InputObject $task | Out-Null; Write-Host 'boot-time zero-egress check disabled' }

Remove-NetFirewallRule -Name 'LecorePlus-ZeroEgress-Block' -ErrorAction SilentlyContinue
foreach ($prof in 'DomainProfile', 'PrivateProfile', 'PublicProfile') {
    $k = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\$prof"
    if (Test-Path $k) { Remove-ItemProperty -Path $k -Name 'DefaultOutboundAction' -ErrorAction SilentlyContinue }
}
Set-NetFirewallProfile -Profile Domain, Private, Public -DefaultOutboundAction Allow

$names = @()
foreach ($f in 'outbound-rules-disabled.txt', 'outbound-rules-disabled-offline.txt') {
    $p = Join-Path $state $f
    if (Test-Path -LiteralPath $p) { $names += @(Get-Content -LiteralPath $p | Where-Object { $_ }) }
}
$names = @($names | Sort-Object -Unique)
$n = 0
foreach ($name in $names) {
    try { Enable-NetFirewallRule -Name $name -ErrorAction Stop; $n++ } catch { }
}
Write-Host "re-enabled $n outbound allow rule(s); default outbound action is Allow"

if ($WindowsUpdate) {
    Remove-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching' -Name 'DontSearchWindowsUpdate' -ErrorAction SilentlyContinue
    foreach ($s in @{ wuauserv = 3; UsoSvc = 2; WaaSMedicSvc = 3; DoSvc = 2 }.GetEnumerator()) {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$($s.Key)" -Name 'Start' -Value $s.Value -ErrorAction SilentlyContinue
    }
    Get-ScheduledTask -TaskPath '\Microsoft\Windows\WindowsUpdate\' -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    Get-ScheduledTask -TaskPath '\Microsoft\Windows\UpdateOrchestrator\' -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
    Write-Host 'Windows Update re-enabled (takes effect after a restart)'
}
if ($TimeSync) {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\TimeProviders\NtpClient' -Name 'Enabled' -ErrorAction SilentlyContinue
    Set-Service -Name W32Time -StartupType Manual
    Start-Service -Name W32Time
    & w32tm.exe /resync /force | Out-Null
    Write-Host 'time sync re-enabled'
}
Write-Host 'Egress is OPEN. Run lockdown.ps1 to close it again.'
