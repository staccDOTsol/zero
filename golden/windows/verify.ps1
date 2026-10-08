<#
  Zero golden image, TEST ONLY: runs inside a throwaway copy-on-write overlay of the finished image
  booted in QEMU (golden/windows/build.sh, step "verify"). The build host adds one line at the hook
  point of the overlay's copy of golden/windows/firstboot.ps1, which the image's own startup task
  (\Zero\Zero golden first boot) runs, and that line starts this file from C:\zero-verify\ as its own
  process; nothing of it is in the image.

  The overlay disk is the size of the laptop's NVMe (1 TB Pro, 2 TB Max/Ultra), larger than the image,
  exactly as when an imaging team writes the image onto the drive. This is the image's FIRST boot:
  the specialize pass (reboot), then the oobeSystem pass, SetupComplete.cmd and the startup task, while
  Windows Welcome (OOBE) waits for the owner on the screen. The VM has no GPU and no Vulkan loader
  (vulkan-1.dll comes from the laptop's GPU driver), so llama.cpp's Vulkan backend (loaded at run time,
  GGML_BACKEND_DL) is skipped and the model runs on the CPU backend; the laptop's GPU path is not covered.

  Results go to COM1 (read by the build host) and C:\zero-verify\report.txt:
    VERIFY PASS|FAIL|INFO: <check> -- <evidence>
    ZERO_VERIFY_RESULT: PASS|FAIL pass=N fail=N
    ZERO_VERIFY_DONE
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$data = Join-Path $env:ProgramData 'leCore+'
$root = Join-Path $env:ProgramFiles 'leCore+'
$logs = Join-Path $data 'logs'
$report = Join-Path $here 'report.txt'
$expect = Get-Content -Raw -LiteralPath (Join-Path $here 'expect.json') | ConvertFrom-Json

$script:port = $null
try { $script:port = New-Object System.IO.Ports.SerialPort 'COM1', 115200; $script:port.Open() } catch { $script:port = $null }
function Out-Line([string]$l) {
    Add-Content -LiteralPath $report -Value $l -Encoding utf8
    if ($script:port) { try { $script:port.WriteLine($l) } catch { } }
}
$script:Pass = 0; $script:Fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Evidence) {
    if ($Ok) { $script:Pass++; $t = 'PASS' } else { $script:Fail++; $t = 'FAIL' }
    Out-Line ("VERIFY {0}: {1} -- {2}" -f $t, $Name, ($Evidence -replace "`r?`n", ' / '))
}
function Info([string]$Name, [string]$Evidence) { Out-Line ("VERIFY INFO: {0} -- {1}" -f $Name, ($Evidence -replace "`r?`n", ' / ')) }
function Invoke-Quiet([scriptblock]$Block) {
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Block 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
}
function Wait-Http([string]$Url, [int]$Seconds, [hashtable]$Headers = @{}) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Uri $Url -Headers $Headers; if ($r.StatusCode -eq 200) { return $r } } catch { }
        Start-Sleep -Seconds 5
    }
    return $null
}
function Post-Json([string]$Url, $Body, [int]$Timeout = 900, [hashtable]$Headers = @{}) {
    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $Timeout -Headers $Headers
}
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
function Get-Code([string]$Exe, [string[]]$More) {
    $o = Invoke-Quiet { & $Exe -sS -o NUL -w '%{http_code}' --max-time 30 @More } | Out-String
    return ($o -replace "`r?`n", ' ').Trim()
}
function Tail([string]$Path, [int]$N = 40) { if (Test-Path -LiteralPath $Path) { (Get-Content -LiteralPath $Path -Tail $N) -join "`n" } else { "(no $Path)" } }
function Get-LlamaTasks { ([regex]::Matches((Tail (Join-Path $logs 'lecore-llama.out.log') 20000), 'launch_slot_')).Count }

Out-Line 'ZERO_VERIFY_STARTED'
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Info 'Windows' ("{0} {1} build {2}.{3}, EditionID {4}" -f $os.Caption, $os.Version, $cv.CurrentBuild, $cv.UBR, $cv.EditionID)
    Check 'Windows 11 Pro' ($cv.EditionID -eq 'Professional') "EditionID $($cv.EditionID)"
    $sb = try { [string](Confirm-SecureBootUEFI) } catch { "n/a ($($_.Exception.Message))" }
    Info 'Secure Boot' $sb

    # --- generalized image, first boot ----------------------------------------------------------------
    $golden = Get-Content -Raw -LiteralPath (Join-Path $data 'golden.json') | ConvertFrom-Json
    $sid = (Get-LocalUser | Select-Object -First 1).SID.AccountDomainSid.Value
    Check 'new machine SID (sysprep /generalize)' ($sid -and $sid -ne $golden.build_machine_sid) "this boot $sid, build VM $($golden.build_machine_sid)"
    # defaultuser0 is Windows' own temporary OOBE account (removed when OOBE finishes)
    $users = @(Get-LocalUser | Where-Object { $_.Enabled -and $_.Name -notmatch '^defaultuser\d+$' } | ForEach-Object { $_.Name })
    Check 'no enabled user account baked in (the owner creates one at OOBE)' ($users.Count -eq 0) ("enabled: " + ($users -join ', ') + "; all: " + ((Get-LocalUser | ForEach-Object { "$($_.Name)$(if ($_.Enabled) { '*' })" }) -join ', '))
    $unattend = Join-Path $env:WINDIR 'Panther\unattend.xml'
    Check 'OOBE answer file in place (local account, no Microsoft-account screens)' ((Test-Path $unattend) -and ((Get-Content -Raw $unattend) -match 'HideOnlineAccountScreens>true')) $unattend
    Info 'stack installed in' ([string]$golden.stack_installed_in)

    # --- golden first boot task ---------------------------------------------------------------------------
    # this script was started by the task itself (test hook), so wait for that task run to finish
    $done = Join-Path $data 'golden-firstboot.done'
    $deadline = (Get-Date).AddMinutes(20)
    while (((-not (Test-Path $done)) -or (Get-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero golden first boot' -ErrorAction SilentlyContinue)) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    Check 'golden first-boot task ran and removed itself' ((Test-Path $done) -and -not (Get-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero golden first boot' -ErrorAction SilentlyContinue)) (Tail (Join-Path $logs 'golden-firstboot.log') 12)
    # Windows Setup is done with its passes (ImageState: the specialize pass ran on this boot's predecessor,
    # the oobeSystem pass on this one) and OOBE (Windows Welcome) has not been completed: what Windows itself
    # answers through kernel32 OOBEComplete (0 until the owner finishes OOBE), or HKLM\SYSTEM\Setup
    # OOBEInProgress = 1, or Windows Welcome (msoobe.exe) on the screen. ImageState alone cannot tell: it is
    # IMAGE_STATE_COMPLETE as soon as the oobeSystem pass ends, while OOBE is still waiting for the owner.
    # Polled briefly: this runs from the startup task, seconds into the boot, before Welcome may be up.
    $state = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State').ImageState
    try { Add-Type -Namespace ZeroVerify -Name Oobe -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool OOBEComplete(out int isComplete);' } catch { }
    $oobeDeadline = (Get-Date).AddMinutes(3)
    do {
        $oobeDone = 'n/a'
        try { $c = 0; if ([ZeroVerify.Oobe]::OOBEComplete([ref]$c)) { $oobeDone = [int]$c } } catch { }
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue
        $oobe = [int]$(if ($setup -and $setup.PSObject.Properties['OOBEInProgress']) { $setup.OOBEInProgress } else { 0 })
        $welcome = @(Get-Process -Name 'msoobe' -ErrorAction SilentlyContinue).Count
        $oobePending = ($oobeDone -eq 0) -or ($oobe -eq 1) -or ($welcome -ge 1)
        if ($oobePending) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $oobeDeadline)
    $du0 = [bool](Get-LocalUser -Name 'defaultuser0' -ErrorAction SilentlyContinue)
    Check 'generalized image on its first boot: Setup passes done, OOBE waiting for the owner' (($state -eq 'IMAGE_STATE_COMPLETE' -or $state -eq 'IMAGE_STATE_SPECIALIZE_RESEAL_TO_OOBE') -and $oobePending) "ImageState $state; OOBEComplete() $oobeDone; OOBEInProgress $oobe; msoobe.exe running $welcome; OOBE account defaultuser0 present $du0"
    $c = Get-Partition -DriveLetter C
    $disk = Get-Disk -Number $c.DiskNumber
    $max = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
    Check ("disk is the laptop-sized test drive ({0:N0} bytes)" -f [double]$expect.disk_bytes) ([double]$disk.Size -eq [double]$expect.disk_bytes) ("disk {0} bytes; image {1} bytes" -f $disk.Size, $expect.image_bytes)
    Check 'C: grew to the end of the disk' (($max - $c.Size) -lt 1GB -and $c.Size -gt [double]$expect.image_bytes) ("C: {0:N1} GB of a {1:N1} GB disk (max {2:N1} GB)" -f ($c.Size / 1e9), ($disk.Size / 1e9), ($max / 1e9))
    $parts = (Get-Partition -DiskNumber $c.DiskNumber | ForEach-Object { "{0}:{1}:{2:N2}GB" -f $_.PartitionNumber, $_.Type, ($_.Size / 1e9) }) -join ' '
    Info 'partitions' $parts
    $re = (& reagentc.exe /info 2>&1 | Where-Object { $_ -match 'status|location' }) -join ' ' -replace '\s+', ' '
    Check 'Windows Recovery Environment enabled (moved onto C:)' ($re -match 'status:\s*Enabled') $re

    # --- per-machine API key ------------------------------------------------------------------------------
    $keyFile = Join-Path $data 'secret\llama-api-key'
    $key = if (Test-Path $keyFile) { (Get-Content -Raw -LiteralPath $keyFile).Trim() } else { '' }
    $keySha = if ($key) { (Get-FileHash -LiteralPath $keyFile -Algorithm SHA256).Hash.ToLowerInvariant() } else { '' }
    Check 'per-machine llama-server API key generated on this machine at first boot (not the build VM''s)' ($key -match '^[0-9a-f]{64}$' -and $keySha -ne $golden.build_api_key_sha256) "sha256 $keySha vs build $($golden.build_api_key_sha256)"
    $auth = @{ Authorization = "Bearer $key" }

    # --- models -------------------------------------------------------------------------------------------
    $mt = (Get-Content -LiteralPath (Join-Path $data 'model.txt') -TotalCount 1).Trim()
    Check "model.txt names the tier default ($($expect.default))" ($mt -eq $expect.default_file) "model.txt = $mt"
    $inv = Get-Content -Raw -LiteralPath (Join-Path $data 'models.json') | ConvertFrom-Json
    Check "models.json: tier $($expect.tier), $(@($expect.models).Count) models" ($inv.tier -eq $expect.tier -and @($inv.models).Count -eq @($expect.models).Count) ("{0} / {1}" -f $inv.tier, (@($inv.models) -join ', '))
    $missing = @(); $total = 0
    foreach ($f in $expect.files) {
        $p = Join-Path $data "models\$($f.file)"
        if (-not (Test-Path -LiteralPath $p) -or (Get-Item -LiteralPath $p).Length -ne [long]$f.bytes) { $missing += $f.file } else { $total += [long]$f.bytes }
    }
    Check ("every model file of the tier on disk with its catalog size ({0} files, {1} models)" -f @($expect.files).Count, @($expect.models).Count) ($missing.Count -eq 0) $(if ($missing) { 'missing/wrong size: ' + ($missing -join ', ') } else { "{0:N1} GB" -f ($total / 1e9) })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $badHash = @()
    foreach ($f in @($expect.files | Where-Object { $_.id -eq $expect.default })) {
        $h = (Get-FileHash -LiteralPath (Join-Path $data "models\$($f.file)") -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($h -ne $f.sha256) { $badHash += "$($f.file) $h" }
    }
    Check 'default model sha256 (read by Windows) matches the catalog' ($badHash.Count -eq 0) ("{0} file(s) hashed in {1:N0}s {2}" -f @($expect.files | Where-Object { $_.id -eq $expect.default }).Count, $sw.Elapsed.TotalSeconds, ($badHash -join ' '))
    $acl = (Get-Acl -LiteralPath (Join-Path $data "models\$mt")).Access
    $ls = @($acl | Where-Object { $_.IdentityReference -match 'LOCAL SERVICE' -and $_.FileSystemRights -match 'Read' })
    $everyoneFull = @($acl | Where-Object { $_.IdentityReference -match '^Everyone$' -and $_.FileSystemRights -match 'FullControl' })
    Check 'model files: inherited ACL (LOCAL SERVICE read, no Everyone full control)' ($ls.Count -ge 1 -and $everyoneFull.Count -eq 0) (($acl | ForEach-Object { "$($_.IdentityReference):$($_.FileSystemRights)$(if ($_.IsInherited) { '(inh)' })" }) -join ', ')

    # --- services + the default model ------------------------------------------------------------------------
    # what the service manager saw this boot (a service that failed or timed out at boot shows here)
    $scm = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Service Control Manager' } -MaxEvents 400 -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'lecore|Zero model server|Zero chat' } | Sort-Object TimeCreated |
        ForEach-Object { "{0:HH:mm:ss} {1} {2}" -f $_.TimeCreated, $_.Id, ($_.Message -replace "`r?`n", ' ') })
    Info 'service manager events for the Zero services' ($scm -join ' || ')
    foreach ($l in 'lecore-llama.wrapper.log', 'lecore-llama.err.log', 'lecore-llama.out.log') { Info "log $l" (Tail (Join-Path $logs $l) 15) }
    Info 'golden first-boot log' (Tail (Join-Path $logs 'golden-firstboot.log') 30)
    foreach ($id in 'lecore-llama', 'lecore-chat') {
        $s = Get-CimInstance Win32_Service -Filter "Name='$id'"
        Check "service $id running as LOCAL SERVICE, automatic" ($s -and $s.State -eq 'Running' -and $s.StartName -match 'LocalService' -and $s.StartMode -eq 'Auto') $(if ($s) { "$($s.State) $($s.StartName) $($s.StartMode)" } else { 'missing' })
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $health = Wait-Http 'http://127.0.0.1:8080/health' 1500
    Check 'default model loaded by itself at boot (llama-server /health)' ($null -ne $health) ("{0:N0}s after the check started; {1}" -f $sw.Elapsed.TotalSeconds, $(if ($health) { $health.Content } else { Tail (Join-Path $logs 'lecore-llama.out.log') 20 }))
    # which ggml backends llama-server loaded (no GPU and no Vulkan loader in this VM: the CPU backend; a laptop logs Vulkan0)
    $backends = @([regex]::Matches((Tail (Join-Path $logs 'lecore-llama.out.log') 20000), '(?m)^.*(load_backend|Vulkan0|ggml_vulkan).*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -Unique -Last 8)
    Info 'ggml backends loaded by llama-server (CPU expected in this VM)' ($backends -join ' / ')
    $cmd = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" | ForEach-Object { $_.CommandLine })
    Check 'llama-server serves the default model file' (@($cmd | Where-Object { $_ -match [regex]::Escape("models\$($expect.default_file)") }).Count -ge 1) (($cmd | Select-Object -First 1) -replace '[0-9a-f]{64}', '<KEY>')
    $k1 = Get-Code $curl @('http://127.0.0.1:8080/v1/models')
    $k2 = Get-Code $curl @('-H', 'Authorization: Bearer wrong-key', 'http://127.0.0.1:8080/v1/models')
    $k3 = Get-Code $curl @('-H', "Authorization: Bearer $key", 'http://127.0.0.1:8080/v1/models')
    Check 'llama-server needs the per-machine key: none/wrong -> 401, key -> 200' ($k1 -eq '401' -and $k2 -eq '401' -and $k3 -eq '200') "no key $k1, wrong key $k2, key $k3"
    $alias = [IO.Path]::GetFileNameWithoutExtension($expect.default_file)
    $models = Wait-Http 'http://127.0.0.1:8080/v1/models' 60 $auth
    Check '/v1/models lists the default model' ($models -and $models.Content -match [regex]::Escape($alias)) $(if ($models) { $models.Content.Substring(0, [Math]::Min(300, $models.Content.Length)) } else { 'no answer' })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $cc = Post-Json 'http://127.0.0.1:8080/v1/chat/completions' @{ model = $alias; max_tokens = 48; temperature = 0; messages = @(@{ role = 'user'; content = 'Reply with one short sentence: what is the capital of France?' }) } 1800 $auth
        $msg = [string]$cc.choices[0].message.content
        $rc = [string]$cc.choices[0].message.reasoning_content
        Check 'the default model answers on 127.0.0.1:8080 (/v1/chat/completions, CPU only in this VM)' ([bool]($msg + $rc)) ("{0:N0}s; content='{1}' reasoning='{2}'" -f $sw.Elapsed.TotalSeconds, $msg, ($rc.Substring(0, [Math]::Min(160, $rc.Length))))
    } catch { Check 'the default model answers on 127.0.0.1:8080' $false $_.Exception.Message }

    # --- the chat on 127.0.0.1:7860, through the model -------------------------------------------------------
    $st = Wait-Http 'http://127.0.0.1:7860/zero/status' 600
    Check 'chat (leCore) up on 127.0.0.1:7860' ($null -ne $st) $(if ($st) { $st.Content } else { Tail (Join-Path $logs 'lecore-chat.out.log') 20 })
    $page = try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:7860/' -TimeoutSec 60 } catch { $null }
    Check 'chat page (title Zero)' ($page -and $page.Content -match '<title>Zero</title>') $(if ($page) { "HTTP $($page.StatusCode)" } else { 'no page' })
    $memoryProv = @('engine', 'taught', 'validated', 'evidenced', 'semantic-recall', 'docs', 'workspace', 'escalated')
    $viaModel = $null; $used = 0
    foreach ($q in 'Write one short sentence about a lighthouse keeper named Brindle.', 'Invent a name for a purple teapot dragon.') {
        $before = Get-LlamaTasks
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { $r = Post-Json 'http://127.0.0.1:7860/api/chat' @{ message = $q; workspace = 'default' } 1800 } catch { $r = $null; Info 'chat error' $_.Exception.Message }
        $used = (Get-LlamaTasks) - $before
        $prov = if ($r) { [string]$r.provenance } else { 'error' }
        Info 'chat question' ("{0:N0}s q='{1}' llama tasks +{2} provenance='{3}' text={4}" -f $sw.Elapsed.TotalSeconds, $q, $used, $prov, $(if ($r) { $r.text } else { '' }))
        if ($r -and $r.text -and $used -ge 1 -and $memoryProv -notcontains $prov) { $viaModel = $r; break }
    }
    Check 'the chat answers on 127.0.0.1:7860 through the default model' ($null -ne $viaModel) $(if ($viaModel) { "llama tasks +$used; text=$($viaModel.text)" } else { 'no model-backed answer (see chat question lines)' })

    # --- zero egress: the containment as shipped ------------------------------------------------------------
    $rules = @(Get-NetFirewallRule -Name 'LecorePlus-Contain-*' -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Block' })
    Check 'containment: 6 per-program Block rules (llama-server.exe, leCore python.exe/pythonw.exe; in + out)' ($rules.Count -eq 6) (($rules | ForEach-Object { "{0} {1} {2}" -f $_.Direction, (($_ | Get-NetFirewallApplicationFilter).Program), (($_ | Get-NetFirewallAddressFilter).RemoteAddress -join ',') }) -join ' / ')
    $listen = @(Get-NetTCPConnection -State Listen -LocalPort 7860, 8080 -ErrorAction SilentlyContinue)
    Check 'llama-server and the chat listen on 127.0.0.1 only' ($listen.Count -ge 2 -and -not @($listen | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count) (($listen | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" } | Sort-Object -Unique) -join ', ')
    $testUrl = 'https://pypi.org/simple/'
    $c0 = Get-Code $curl @($testUrl)
    Check "the OS networks normally (curl.exe -> $testUrl)" ($c0 -match '^[23]\d\d$') "HTTP $c0"
    $probe = "import socket,urllib.request`ntry:`n  s=socket.create_connection(('1.1.1.1',443),10); s.close(); print('TCP-OK')`nexcept Exception as e: print('TCP-FAIL', type(e).__name__, e)`ntry:`n  print('HTTP-OK', urllib.request.urlopen('$testUrl', timeout=15).status)`nexcept Exception as e: print('HTTP-FAIL', type(e).__name__, e)"
    $probeFile = Join-Path $here 'egress_probe.py'
    [IO.File]::WriteAllText($probeFile, $probe)
    $o2 = (Invoke-Quiet { & (Join-Path $root 'python\python.exe') -X utf8 $probeFile } | Out-String).Trim()
    Check "leCore's python.exe cannot reach a non-loopback address" ($o2 -match 'TCP-FAIL' -and $o2 -match 'HTTP-FAIL' -and $o2 -notmatch '-OK') ($o2 -replace "`r?`n", ' | ')
    $llamaExe = Join-Path $root 'llama\llama-server.exe'
    Stop-Service lecore-llama
    Start-Sleep -Seconds 3
    Get-Process -Name llama-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Rename-Item -LiteralPath $llamaExe -NewName 'llama-server.exe.real'
    try {
        Copy-Item -LiteralPath $curl -Destination $llamaExe
        $c3 = Get-Code $llamaExe @($testUrl)
        $c4 = Get-Code $llamaExe @('http://127.0.0.1:7860/zero/status')
    } finally {
        Remove-Item -Force -LiteralPath $llamaExe
        Rename-Item -LiteralPath "$llamaExe.real" -NewName 'llama-server.exe'
    }
    Check 'the llama-server.exe program path cannot reach a non-loopback address (loopback works)' ($c3 -match '000' -and $c4 -eq '200') "curl.exe placed at that path: $testUrl -> $c3; 127.0.0.1:7860 -> $c4"
    Start-Service lecore-llama
    $h1 = Get-Code $curl @('-H', 'Host: zero.attacker.example:7860', 'http://127.0.0.1:7860/zero/status')
    Check 'chat refuses a DNS-rebinding Host' ($h1 -eq '403') "foreign Host -> $h1"
    $wer = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\ExcludedApplications' -ErrorAction SilentlyContinue
    Info 'crash dumps excluded' $(if ($wer) { (($wer.PSObject.Properties | Where-Object { $_.Name -match '\.exe$' }).Name -join ', ') } else { '(no key)' })

    # --- drivers for the laptop -------------------------------------------------------------------------------
    $drv = @(Get-WindowsDriver -Online -ErrorAction SilentlyContinue)
    $disp = @($drv | Where-Object { $_.ClassName -eq 'Display' } | ForEach-Object { "$($_.ProviderName) $($_.Version) $(Split-Path -Leaf $_.OriginalFileName)" })
    Check ("laptop drivers in the driver store ({0})" -f $expect.target) ($drv.Count -ge 20 -and @($disp | Where-Object { $_ -match $expect.display_vendor }).Count -ge 1) ("{0} third-party driver packages; Display: {1}" -f $drv.Count, ($disp -join '; '))
    $fwKey = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey
    Info 'activation' $(if ($fwKey) { 'firmware OA3 key present' } else { 'no firmware OA3 key in this VM (laptops have one; firstboot.ps1 installs it)' })
    $bl = Invoke-Quiet { & manage-bde.exe -status C: } | Out-String
    Info 'BitLocker C:' (($bl -split "`n" | Where-Object { $_ -match 'Conversion Status|Protection Status' }) -join ' ')
} catch {
    Check 'verify script ran to the end' $false ("{0} at {1}" -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)
}
$res = if ($script:Fail -eq 0 -and $script:Pass -gt 0) { 'PASS' } else { 'FAIL' }
Out-Line ("ZERO_VERIFY_RESULT: {0} pass={1} fail={2}" -f $res, $script:Pass, $script:Fail)
foreach ($l in 'lecore-llama.out.log', 'lecore-chat.out.log', 'golden-firstboot.log') { Out-Line "---- $l"; Out-Line (Tail (Join-Path $logs $l) 25) }
Out-Line 'ZERO_VERIFY_DONE'
Start-Sleep -Seconds 5
& shutdown.exe /s /t 5 /f /c 'zero golden verify done'
