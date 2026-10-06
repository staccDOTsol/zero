<#
  PowerShell twin of `unattend.py offline` (for the Windows build host, which has no Python):
  the ISO's own autounattend.xml without its windowsPE pass, plus one specialize command after the
  Zero stack install that runs zero-golden\firstboot.ps1 -InSpecialize. Text surgery on purpose: the
  ISO's specialize and oobeSystem XML stays as shipped.
#>
param(
    [Parameter(Mandatory = $true)][string]$IsoAnswerFile,
    [Parameter(Mandatory = $true)][string]$Out
)
$ErrorActionPreference = 'Stop'
$t = [IO.File]::ReadAllText($IsoAnswerFile)
if ($t -match '@OEM_MODEL@') { throw "$IsoAnswerFile still has the @OEM_MODEL@ placeholder" }
$t = [regex]::Replace($t, '(?s)[ \t]*<settings pass="windowsPE">.*?</settings>[ \t]*\r?\n', '', 1)
$spec = [regex]::Match($t, '(?s)[ \t]*<settings pass="specialize">.*?</settings>[ \t]*\r?\n')
if (-not $spec.Success) { throw 'answer file has no specialize pass' }
$orders = [regex]::Matches($spec.Value, '<Order>(\d+)</Order>') | ForEach-Object { [int]$_.Groups[1].Value }
$next = ([int]($orders | Measure-Object -Maximum).Maximum) + 1
$cmd = @"
        <RunSynchronousCommand wcm:action="add">
          <Order>$next</Order>
          <Description>Zero golden image: C: to the end of the disk, model file ACLs, firmware product key</Description>
          <Path>cmd.exe /c "%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File %WINDIR%\Setup\Scripts\zero-golden\firstboot.ps1 -InSpecialize &gt; %WINDIR%\Setup\Scripts\zero-golden-specialize.log 2&gt;&amp;1"</Path>
        </RunSynchronousCommand>

"@
$i = $spec.Value.IndexOf('      </RunSynchronous>')
if ($i -lt 0) { throw 'specialize pass has no RunSynchronous block' }
$newSpec = $spec.Value.Substring(0, $i) + $cmd + $spec.Value.Substring($i)
$t = $t.Substring(0, $spec.Index) + $newSpec + $t.Substring($spec.Index + $spec.Length)
$note = "<!--`r`n  Zero golden image (golden/windows/offline-unattend.ps1): the ISO's autounattend.xml without its windowsPE`r`n  pass, plus the golden first-boot step in specialize. Applied with DISM + bcdboot; first boot = specialize + OOBE.`r`n-->`r`n"
$t = ([regex]'<unattend ').Replace($t, $note + '<unattend ', 1)
$t = $t -replace "(?<!\r)\n", "`r`n"
[void][xml]$t
[IO.File]::WriteAllText($Out, $t, (New-Object Text.UTF8Encoding($false)))
Write-Host "offline answer file -> $Out"
