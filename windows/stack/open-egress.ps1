<#
.SYNOPSIS
  Deliberately lets the Zero inference programs (llama-server.exe and leCore's embedded Python) reach
  the network. For the OWNER, on purpose: afterwards the model's input and output CAN leave the machine.

.DESCRIPTION
  Windows itself is never cut off by Zero (the firewall's default outbound action is Allow); only the two
  inference programs are contained. This script removes the six "Zero: ... stays on this machine" firewall
  rules and disables the boot-time "Zero model containment check" task so they are not re-added.
  Needed, for example, for leCore chat commands that call outside services ("learn api: <URL>",
  "use api: ...") or for attaching a remote model in the chat's Settings.

      & 'C:\Program Files\leCore+\setup\open-egress.ps1'

  To contain them again: & 'C:\Program Files\leCore+\setup\lockdown.ps1'   (re-enables the boot-time check)

  Windows PowerShell 5.1 compatible; run elevated.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

if (-not $PSCmdlet.ShouldProcess('llama-server.exe and leCore python.exe', 'Allow network access (model input/output may leave this machine)')) { return }

foreach ($n in 'Zero model containment check', 'Zero zero-egress check') {
    $task = Get-ScheduledTask -TaskPath '\Zero\' -TaskName $n -ErrorAction SilentlyContinue
    if ($task) { Disable-ScheduledTask -InputObject $task | Out-Null; Write-Host "disabled task \Zero\$n" }
}
$rules = @(@(Get-NetFirewallRule -Name 'LecorePlus-Contain-*' -ErrorAction SilentlyContinue) +
           @(Get-NetFirewallRule -DisplayName 'Zero: * stays on this machine (*)' -ErrorAction SilentlyContinue) | Sort-Object Name -Unique)
$rules | Remove-NetFirewallRule
Write-Host "removed $($rules.Count) containment rule(s). llama-server and leCore can now reach the network."
Write-Host 'Run lockdown.ps1 to contain them again.'
