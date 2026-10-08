<#
.SYNOPSIS
  CI smoke test of lecore-plus-windows-stack.zip on the GitHub Actions Windows runner itself.
  Runs in Windows PowerShell 5.1 (what the laptop uses during Windows Setup).

  Proves, in order (each step prints PASS/FAIL and the evidence):
    1. install.ps1 -SkipLockdown -TestMode installs from the offline payload and registers both services
    2. llama service with no model configured: a clean no-op (nothing listens on :8080), logs why
    3. chat on 127.0.0.1:7860 answers memory-only (GET /, title "Zero", POST /api/chat)
    4. provision\windows-add-models.ps1 -All pro with a test catalog (tiny test GGUF, never shipped):
       download, sha256 check, copy, model.txt; plus -DryRun against the real models/catalog.json per tier
    5. llama service with the model: /v1/models lists it, /v1/chat/completions answers
    5b. the per-machine API key: no key / wrong key -> 401, key -> 200; key file ACL; key not on the command line
    6. chat -> model rung: a question memory cannot answer is answered by llama-server
    7. the chat process attempted no non-loopback connection or DNS lookup (in-process egress guard)
    8. lockdown.ps1 -WhatIf lists its actions and changes nothing; the full lockdown refuses on CI
    8b. lockdown.ps1 -FirewallOnly applied for real: general outbound and other Pythons still work,
        leCore's python.exe and the llama-server.exe path cannot reach a non-loopback address, both
        listen on 127.0.0.1 only, chat -> model still works, chat refuses rebinding/cross-site requests
    8c. llama.cpp's Vulkan backend runs the model on a software Vulkan device (Mesa lavapipe, CI only)
    9. PSScriptAnalyzer: no errors in windows\ and provision\windows-*.ps1
#>
param(
    [Parameter(Mandatory = $true)][string]$StackZip,
    [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$Report = (Join-Path (Get-Location) 'smoke-report.md')
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Rows = New-Object System.Collections.Generic.List[string]
$script:Failed = 0
function Check([string]$Name, [bool]$Ok, [string]$Evidence) {
    $tag = if ($Ok) { 'PASS' } else { 'FAIL'; $script:Failed++ }
    Write-Host ("[{0}] {1} -- {2}" -f $tag, $Name, $Evidence)
    $script:Rows.Add(("| {0} | {1} | {2} |" -f $tag, $Name, ($Evidence -replace '\|', '/' -replace "`r?`n", ' ')))
}
function Wait-Http([string]$Url, [int]$Seconds, [hashtable]$Headers = @{}) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri $Url -Headers $Headers; if ($r.StatusCode -eq 200) { return $r } } catch { }
        Start-Sleep -Seconds 2
    }
    return $null
}
function Post-Json([string]$Url, $Body, [int]$Timeout = 300, [hashtable]$Headers = @{}) {
    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $Timeout -Headers $Headers
}
function Get-KeyHeader {
    # the per-machine llama-server API key (Administrators may read it; the runner user is one)
    @{ Authorization = 'Bearer ' + (Get-Content -Raw -LiteralPath (Join-Path $env:ProgramData 'leCore+\secret\llama-api-key')).Trim() }
}
function Get-Code([string]$Url, [string[]]$More = @()) {
    $o = (& (Join-Path $env:SystemRoot 'System32\curl.exe') -s -o NUL -w '%{http_code}' --max-time 30 @More $Url) | Out-String
    return $o.Trim()
}
function Invoke-Quiet([scriptblock]$Block) {
    # Windows PowerShell 5.1 turns a native command's stderr into terminating errors under 'Stop' when redirected.
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $Block 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $old }
}
function Tail([string]$Path, [int]$N = 40) { if (Test-Path -LiteralPath $Path) { (Get-Content -LiteralPath $Path -Tail $N) -join "`n" } else { "(no $Path)" } }

$data = Join-Path $env:ProgramData 'leCore+'
$root = Join-Path $env:ProgramFiles 'leCore+'
$logs = Join-Path $data 'logs'
$stackJson = Get-Content -Raw (Join-Path $RepoRoot 'windows\stack.json') | ConvertFrom-Json

# Firewall state before (to prove -WhatIf changed nothing)
$fwBefore = (Get-NetFirewallProfile | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Enabled):$($_.DefaultOutboundAction)" }) -join ' '
$rulesBefore = @(Get-NetFirewallRule -Direction Outbound -Enabled True -ErrorAction SilentlyContinue).Count

# 1. install ------------------------------------------------------------------------------------
$x = Join-Path $env:RUNNER_TEMP 'stack'
if (Test-Path $x) { Remove-Item -Recurse -Force $x }
Expand-Archive -LiteralPath $StackZip -DestinationPath $x
$src = Join-Path $x 'lecore-plus-windows-stack'
$sw = [Diagnostics.Stopwatch]::StartNew()
$installOk = $true
try { & (Join-Path $src 'install.ps1') -SkipLockdown -TestMode -Phase ci }
catch { $installOk = $false; Write-Host "install.ps1 threw: $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
$chatSvc = Get-Service lecore-chat -ErrorAction SilentlyContinue
$llamaSvc = Get-Service lecore-llama -ErrorAction SilentlyContinue
Check 'install.ps1 -SkipLockdown -TestMode (offline payload, no pip downloads)' ($installOk -and $chatSvc -and $llamaSvc) `
    ("{0:N0}s; services: lecore-chat={1}, lecore-llama={2}; account={3}" -f $sw.Elapsed.TotalSeconds,
        $(if ($chatSvc) { $chatSvc.Status } else { 'missing' }), $(if ($llamaSvc) { $llamaSvc.Status } else { 'missing' }),
        $(if ($chatSvc) { (Get-CimInstance Win32_Service -Filter "Name='lecore-chat'").StartName } else { '-' }))
$rtFiles = @($stackJson.msvc_runtime.files)
$rtMissing = @($rtFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root "llama\$_")) })
$rtVer = ($rtFiles | ForEach-Object { $p = Join-Path $root "llama\$_"; if (Test-Path -LiteralPath $p) { "$_ $((Get-Item -LiteralPath $p).VersionInfo.FileVersion)" } }) -join ', '
Check 'MSVC runtime shipped app-local next to llama-server.exe (a clean Windows 11 has none)' ($rtMissing.Count -eq 0) $(if ($rtMissing) { 'missing: ' + ($rtMissing -join ', ') } else { $rtVer })
$pyv = & (Join-Path $root 'python\python.exe') -X utf8 -c "import sys, numpy, flask, matplotlib, nltk; print(sys.version.split()[0], 'numpy', numpy.__version__, 'flask', flask.__version__, 'nltk', nltk.__version__)"
Check 'embedded Python + wheels importable' ($LASTEXITCODE -eq 0) "$pyv"
$nl = & (Join-Path $root 'python\python.exe') -X utf8 -c "import os; os.environ['NLTK_DATA']=r'$root\nltk_data'; import nltk; print(nltk.download('gutenberg'), nltk.download('not-a-real-package', quiet=True)); from nltk.corpus import gutenberg; print(len(gutenberg.fileids()))"
Check 'nltk.download is an offline no-op; corpora pre-staged' (($nl -join ' ') -match '^True False \d+') ($nl -join ' ')

# 2. llama with no model -------------------------------------------------------------------------
function Test-Port([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect('127.0.0.1', $Port); return $true } catch { return $false } finally { $c.Close() }
}
Start-Sleep -Seconds 5
$llamaSvc = Get-Service lecore-llama
$llamaOut = Tail (Join-Path $logs 'lecore-llama.out.log') 3
Check 'llama service, no model configured: clean no-op (waits, nothing on :8080)' ($llamaSvc.Status -eq 'Running' -and $llamaOut -match 'no model configured' -and -not (Test-Port 8080)) "status=$($llamaSvc.Status); port 8080 open=$(Test-Port 8080); log: $llamaOut"

# 3. chat memory-only ----------------------------------------------------------------------------
$status = Wait-Http 'http://127.0.0.1:7860/zero/status' 240
if (-not $status) { Write-Host (Tail (Join-Path $logs 'lecore-chat.out.log') 80); Write-Host (Tail (Join-Path $logs 'lecore-chat.err.log') 80) }
Check 'chat service up on 127.0.0.1:7860' ($null -ne $status) $(if ($status) { $status.Content } else { 'no answer in 240 s' })
$page = try { Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:7860/' -TimeoutSec 30 } catch { $null }
Check 'chat UI page (title Zero)' ($page -and $page.Content -match '<title>Zero</title>') $(if ($page) { "HTTP $($page.StatusCode), $($page.Content.Length) bytes" } else { 'no page' })
try {
    $a1 = Post-Json 'http://127.0.0.1:7860/api/chat' @{ message = 'what is lecore'; workspace = 'default' }
    Check 'chat answers memory-only (no model)' ([bool]$a1.text) ("provenance={0}; text={1}" -f $a1.provenance, ($a1.text.Substring(0, [Math]::Min(160, $a1.text.Length))))
    $a2 = Post-Json 'http://127.0.0.1:7860/api/chat' @{ message = 'Name a colour that rhymes with mellow, in one word.'; workspace = 'default' }
    Check 'unknown question escalates honestly without a model' ([bool]$a2.text) ("provenance={0}; text={1}" -f $a2.provenance, ($a2.text.Substring(0, [Math]::Min(160, $a2.text.Length))))
} catch { Check 'chat answers memory-only (no model)' $false $_.Exception.Message }

# 4. provisioning ----------------------------------------------------------------------------------
$tm = $stackJson.test_model
$cat = Join-Path $env:RUNNER_TEMP 'test-catalog.json'
@{ updated = 'ci'; models = @(@{ id = $tm.id; name = 'CI smoke test model (never shipped)'; default_for = @('pro')
    builds = @{ pro = @{ repo = $tm.repo; files = @(@{ path = $tm.path; bytes = $tm.bytes; sha256 = $tm.sha256 }) }; max = $null; ultra = $null } }) } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cat -Encoding utf8
$prov = Join-Path $RepoRoot 'provision\windows-add-models.ps1'
& $prov -All pro -Catalog $cat -Target $env:SystemDrive
$mt = (Get-Content (Join-Path $data 'model.txt') -TotalCount 1).Trim()
$mf = Join-Path $data "models\$mt"
Check 'provision -All pro: download, sha256, copy, model.txt' ($mt -eq $tm.path -and (Test-Path $mf) -and ((Get-FileHash $mf -Algorithm SHA256).Hash.ToLower() -eq $tm.sha256)) "model.txt=$mt"
$realCat = Join-Path $RepoRoot 'models\catalog.json'
if (Test-Path $realCat) {
    foreach ($t in 'pro', 'max', 'ultra') {
        $out = & $prov -All $t -Catalog $realCat -Target 'Z:' -DryRun 6>&1 | Out-String
        Check "provision -All $t -DryRun against models/catalog.json" ($out -match 'model\.txt would be') (($out -split "`n" | Where-Object { $_ -match 'tier |model\.txt' }) -join ' / ')
    }
}

# 5. llama with the model (the service picks the new model.txt up by itself) ----------------------
$null = Wait-Http 'http://127.0.0.1:8080/health' 300
$models = Wait-Http 'http://127.0.0.1:8080/v1/models' 30 (Get-KeyHeader)
Check 'llama service started the provisioned model by itself; /v1/models answers' ($models -and $models.Content -match [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($tm.path))) $(if ($models) { $models.Content.Substring(0, [Math]::Min(300, $models.Content.Length)) } else { Tail (Join-Path $logs 'lecore-llama.out.log') 30 })
$dev = Invoke-Quiet { & (Join-Path $root 'llama\llama-server.exe') --list-devices } | Out-String
Check 'llama.cpp devices on this runner (informational)' $true (($dev -split "`n" | Where-Object { $_ -match 'Vulkan|device|CPU|load_backend' }) -join ' / ')
try {
    $cc = Post-Json 'http://127.0.0.1:8080/v1/chat/completions' @{ model = 'x'; max_tokens = 24; messages = @(@{ role = 'user'; content = 'Say hello.' }) } 120 (Get-KeyHeader)
    Check 'llama-server /v1/chat/completions answers' ([bool]$cc.choices[0].message.content) ("{0}" -f $cc.choices[0].message.content)
} catch { Check 'llama-server /v1/chat/completions answers' $false $_.Exception.Message }

# 5b. the per-machine API key on :8080 ------------------------------------------------------------------
$keyFile = Join-Path $data 'secret\llama-api-key'
$key = (Get-Content -Raw -LiteralPath $keyFile).Trim()
$acl = (Get-Acl -LiteralPath $keyFile).Access | ForEach-Object { "$($_.IdentityReference):$($_.FileSystemRights)" }
$aclOk = -not @((Get-Acl -LiteralPath $keyFile).Access | Where-Object { $_.IdentityReference -notin @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', 'NT SERVICE\lecore-llama', 'NT SERVICE\lecore-chat') }).Count
Check 'API key: 256 random bits, readable only by the two Zero services (service SIDs), SYSTEM, Administrators' ($key -match '^[0-9a-f]{64}$' -and $aclOk) ($acl -join ', ')
$k1 = Get-Code 'http://127.0.0.1:8080/v1/models'
$k2 = Get-Code 'http://127.0.0.1:8080/v1/chat/completions' @('-H', 'Content-Type: application/json', '--data', '{"messages":[{"role":"user","content":"hi"}],"max_tokens":4}')
$k3 = Get-Code 'http://127.0.0.1:8080/v1/models' @('-H', 'Authorization: Bearer wrong-key')
$k4 = Get-Code 'http://127.0.0.1:8080/v1/models' @('-H', "Authorization: Bearer $key")
$k5 = Get-Code 'http://127.0.0.1:8080/health'
Check 'llama-server requires the key: no key / wrong key -> 401, key -> 200 (/health stays public)' ($k1 -eq '401' -and $k2 -eq '401' -and $k3 -eq '401' -and $k4 -eq '200' -and $k5 -eq '200') "no key /v1/models $k1, no key /v1/chat/completions $k2, wrong key $k3, key $k4, /health $k5"
$cmdLines = @(Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" | ForEach-Object { $_.CommandLine })
Check 'the key is not on llama-server''s command line (--api-key-file)' ($cmdLines.Count -ge 1 -and -not @($cmdLines | Where-Object { $_ -match $key }).Count -and @($cmdLines | Where-Object { $_ -match '--api-key-file' }).Count) (($cmdLines | Select-Object -First 1) -replace [regex]::Escape($key), '<KEY>')
# The runner has the redistributable in System32 too; the loader searches the program's folder first, so the
# modules of the running llama-server must be the shipped app-local copies (and so new enough for this build).
$rtLoaded = @(Get-Process -Name llama-server -ErrorAction SilentlyContinue | ForEach-Object { $_.Modules } |
    Where-Object { $rtFiles -contains $_.ModuleName.ToLowerInvariant() } | ForEach-Object { "$($_.ModuleName)=$($_.FileName)" } | Sort-Object -Unique)
Check 'llama-server runs on the shipped app-local MSVC runtime (not the runner''s System32 copies)' ($rtLoaded.Count -eq $rtFiles.Count -and -not @($rtLoaded | Where-Object { $_ -notlike "*=$root\llama\*" }).Count) ($rtLoaded -join '; ')

# 6. chat -> model rung ---------------------------------------------------------------------------
# Evidence that the chat on :7860 reached the model on :8080: llama-server processes new tasks while the
# chat answers a question its memory cannot, and the answer is not a memory/engine answer. (At the pinned
# leCore commit an answer from the model rung via the ladder comes back with provenance null or
# "model-cached".)
function Get-LlamaTasks { ([regex]::Matches((Tail (Join-Path $logs 'lecore-llama.out.log') 5000), 'launch_slot_')).Count }
$memoryProv = @('engine', 'taught', 'validated', 'evidenced', 'semantic-recall', 'docs', 'workspace', 'escalated')
$viaModel = $null; $tasksUsed = 0
foreach ($q in 'Write one short sentence about a lighthouse keeper named Brindle.', 'Invent a name for a purple teapot dragon.', 'Describe the taste of a zorbleberry in five words.') {
    $before = Get-LlamaTasks
    try { $r = Post-Json 'http://127.0.0.1:7860/api/chat' @{ message = $q; workspace = 'default' } 300 } catch { $r = $null }
    $used = (Get-LlamaTasks) - $before
    $prov = if ($r) { [string]$r.provenance } else { 'error' }
    Write-Host ("  q='{0}' -> llama tasks +{1}, provenance='{2}', text={3}" -f $q, $used, $prov, $(if ($r) { $r.text } else { '' }))
    if ($r -and $r.text -and $used -ge 1 -and $memoryProv -notcontains $prov) { $viaModel = $r; $tasksUsed = $used; break }
}
Check 'chat on :7860 answers through the model on :8080' ($null -ne $viaModel) $(if ($viaModel) { "llama-server ran $tasksUsed task(s) for the chat; provenance='$($viaModel.provenance)'; text=$($viaModel.text)" } else { 'no model-backed answer' })

# 7. egress guard --------------------------------------------------------------------------------
$guard = Join-Path $logs 'egress-guard.log'
$chatLog = Tail (Join-Path $logs 'lecore-chat.out.log') 400
Check 'chat process made no non-loopback connection or DNS lookup' ((-not (Test-Path $guard) -or -not (Get-Content $guard)) -and $chatLog -match 'egress guard ON') $(if (Test-Path $guard) { Tail $guard 10 } else { 'egress-guard.log empty; guard was ON' })

# 8. lockdown -WhatIf -----------------------------------------------------------------------------
$lkOk = $true
try { $lk = & (Join-Path $root 'setup\lockdown.ps1') -WhatIf -InstallBootTask 6>&1 3>&1 | Out-String }
catch { $lkOk = $false; $lk = "lockdown -WhatIf threw: $($_.Exception.Message)" }
$whatIfs = ([regex]::Matches($lk, '\[lockdown\] WHATIF ')).Count
$fwAfter = (Get-NetFirewallProfile | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Enabled):$($_.DefaultOutboundAction)" }) -join ' '
$rulesAfter = @(Get-NetFirewallRule -Direction Outbound -Enabled True -ErrorAction SilentlyContinue).Count
Check 'lockdown.ps1 -WhatIf runs clean' ($lkOk -and $whatIfs -ge 25) ("$whatIfs planned actions; " + (($lk -split "`n" | Where-Object { $_ -match 'results:' }) -join ' '))
Check 'lockdown -WhatIf changed nothing on the runner' ($fwBefore -eq $fwAfter -and $rulesBefore -eq $rulesAfter -and -not (Get-NetFirewallRule -DisplayName 'Zero: * stays on this machine (*)' -ErrorAction SilentlyContinue)) "firewall before=[$fwBefore] after=[$fwAfter]; enabled outbound rules $rulesBefore -> $rulesAfter"
$guardMsg = Invoke-Quiet { & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$root\setup\lockdown.ps1' -WhatIf:`$false" } | Out-String
Check 'full lockdown (machine policy) refuses to run on a CI runner' ($guardMsg -match 'Refusing to apply the full Zero lockdown') (($guardMsg -split "`n" | Select-Object -First 2) -join ' ')
$lk | Set-Content -LiteralPath (Join-Path (Split-Path $Report) 'lockdown-whatif.txt') -Encoding utf8

# 8b. model containment, for real, on this runner ------------------------------------------------------
# lockdown.ps1 -FirewallOnly adds only the per-program rules (llama-server.exe, leCore's python.exe /
# pythonw.exe -> no non-loopback address) and keeps DefaultOutboundAction Allow, so it is safe on the runner.
function Get-HttpCode([string]$Exe, [string[]]$More) {
    # prints "<http code>" plus curl's error text when it fails (000 = no HTTP response at all)
    $o = Invoke-Quiet { & $Exe -sS -o NUL -w '%{http_code}' --max-time 20 @More } | Out-String
    return ($o -replace "`r?`n", ' ').Trim()
}
$testUrl = 'https://pypi.org/simple/'
$fo = Invoke-Quiet { & (Join-Path $root 'setup\lockdown.ps1') -FirewallOnly } | Out-String
Write-Host $fo
$rules = @(Get-NetFirewallRule -DisplayName 'Zero: * stays on this machine (*)' -ErrorAction SilentlyContinue)
$ruleInfo = ($rules | ForEach-Object { "{0} {1} {2} {3}" -f $_.Name, $_.Direction, $_.Action, (($_ | Get-NetFirewallApplicationFilter).Program) }) -join ' / '
$profAllow = @(Get-NetFirewallProfile | Where-Object { $_.Enabled -and $_.DefaultOutboundAction -eq 'Allow' }).Count -eq 3
Check 'containment applied: 6 per-program Block rules, every profile default outbound Allow' ($rules.Count -eq 6 -and $profAllow) "$ruleInfo"

$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$code = Get-HttpCode $curl @($testUrl)
Check "general outbound works (curl.exe -> $testUrl)" ($code -match '^[23]\d\d$') "HTTP $code"
$probe = "import socket,urllib.request`ntry:`n  s=socket.create_connection(('1.1.1.1',443),10); s.close(); print('TCP-OK')`nexcept Exception as e: print('TCP-FAIL', type(e).__name__, e)`ntry:`n  print('HTTP-OK', urllib.request.urlopen('https://pypi.org/simple/', timeout=15).status)`nexcept Exception as e: print('HTTP-FAIL', type(e).__name__, e)"
$probeFile = Join-Path $env:RUNNER_TEMP 'egress_probe.py'
[IO.File]::WriteAllText($probeFile, $probe)
$otherPy = (Get-Command python.exe -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike "$root*" } | Select-Object -First 1).Source
$o1 = (Invoke-Quiet { & $otherPy $probeFile } | Out-String).Trim()
Check "another Python is not affected ($otherPy)" ($o1 -match 'TCP-OK' -and $o1 -match 'HTTP-OK') ($o1 -replace "`r?`n", ' | ')
$o2 = (Invoke-Quiet { & (Join-Path $root 'python\python.exe') -X utf8 $probeFile } | Out-String).Trim()
Check "leCore's python.exe cannot reach a non-loopback address" ($o2 -match 'TCP-FAIL' -and $o2 -match 'HTTP-FAIL' -and $o2 -notmatch '-OK') ($o2 -replace "`r?`n", ' | ')

# llama-server.exe path: swap a copy of curl.exe in at exactly that path (the rule matches the program
# path), try to reach the internet, put llama-server.exe back.
$llamaExe = Join-Path $root 'llama\llama-server.exe'
Stop-Service lecore-llama
Start-Sleep -Seconds 2
Rename-Item -LiteralPath $llamaExe -NewName 'llama-server.exe.real'
try {
    Copy-Item -LiteralPath $curl -Destination $llamaExe
    $c3 = Get-HttpCode $llamaExe @($testUrl)
    $c4 = Get-HttpCode $llamaExe @('http://127.0.0.1:7860/zero/status')
} finally {
    Remove-Item -Force -LiteralPath $llamaExe
    Rename-Item -LiteralPath "$llamaExe.real" -NewName 'llama-server.exe'
}
Check 'the llama-server.exe program path cannot reach a non-loopback address (loopback still works)' ($c3 -match '000' -and $c3 -match 'Failed to connect|Could not connect|10013|Permission|forbidden' -and $c4 -eq '200') "same curl.exe placed at that path: $testUrl -> $c3; 127.0.0.1:7860 -> $c4"
Start-Service lecore-llama
$null = Wait-Http 'http://127.0.0.1:8080/health' 300
$listen = @(Get-NetTCPConnection -State Listen -LocalPort 7860, 8080 -ErrorAction SilentlyContinue)
Check 'llama-server and the chat listen on 127.0.0.1 only' ($listen.Count -ge 2 -and -not @($listen | Where-Object { $_.LocalAddress -ne '127.0.0.1' }).Count) (($listen | ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" } | Sort-Object -Unique) -join ', ')
$before = Get-LlamaTasks
try { $r = Post-Json 'http://127.0.0.1:7860/api/chat' @{ message = 'Write one short sentence about a lantern named Quill.'; workspace = 'default' } 300 } catch { $r = $null }
$used = (Get-LlamaTasks) - $before
Check 'with containment on, the chat still reaches the model over loopback' ($r -and $r.text -and $used -ge 1) ("llama tasks +{0}; text={1}" -f $used, $(if ($r) { $r.text } else { '' }))

$h1 = Get-HttpCode $curl @('-H', 'Host: zero.attacker.example:7860', 'http://127.0.0.1:7860/zero/status')
$h2 = Get-HttpCode $curl @('-X', 'POST', '-H', 'Origin: https://attacker.example', '-H', 'Content-Type: text/plain', '--data', '{"message":"hi"}', 'http://127.0.0.1:7860/api/chat')
$hdr = (Invoke-Quiet { & $curl -s -D - -o NUL --max-time 20 'http://127.0.0.1:7860/' } | Out-String)
$csp = ($hdr -split "`n" | Where-Object { $_ -match '^Content-Security-Policy:' }) -join ''
Check 'chat refuses DNS-rebinding hosts and cross-site posts; CSP keeps the page on 127.0.0.1' ($h1 -eq '403' -and $h2 -eq '403' -and $csp -match "default-src 'self'") "foreign Host -> $h1, foreign Origin POST -> $h2; $($csp.Trim())"
$cors = (Invoke-Quiet { & $curl -s -D - -o NUL --max-time 20 -H 'Origin: https://attacker.example' 'http://127.0.0.1:8080/v1/models' } | Out-String)
Check 'llama-server does not grant CORS to other sites' ($cors -notmatch 'Access-Control-Allow-Origin:\s*(\*|https://attacker)') (($cors -split "`n" | Where-Object { $_ -match '^HTTP/|Access-Control' }) -join ' / ')

# 8d. the same containment through netsh.exe + schtasks.exe (the no-WMI path Windows Setup's specialize
#     pass takes, where CIM fails with "Provider failure") -----------------------------------------------
Get-NetFirewallRule -DisplayName 'Zero: * stays on this machine (*)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$env:LECORE_PLUS_NO_CIM = '1'
$nsLog = Invoke-Quiet { & (Join-Path $root 'setup\lockdown.ps1') -FirewallOnly -InstallBootTask 6>&1 } | Out-String
Remove-Item Env:\LECORE_PLUS_NO_CIM
Write-Host $nsLog
$csv = Get-ChildItem (Join-Path $data 'lockdown') -Filter 'lockdown-live-*.csv' | Sort-Object LastWriteTime | Select-Object -Last 1
$nsOut = if ($csv) { Get-Content -Raw -LiteralPath $csv.FullName } else { '' }
Write-Host $nsOut
$rules2 = @(Get-NetFirewallRule -DisplayName 'Zero: * stays on this machine (*)' -ErrorAction SilentlyContinue)
$progs2 = ($rules2 | ForEach-Object { ($_ | Get-NetFirewallApplicationFilter).Program } | Sort-Object -Unique) -join ', '
$addr2 = (($rules2 | Select-Object -First 1 | Get-NetFirewallAddressFilter).RemoteAddress) -join ' '
$task2 = Get-ScheduledTask -TaskPath '\Zero\' -TaskName 'Zero model containment check' -ErrorAction SilentlyContinue
Check 'netsh/schtasks path (no WMI): 6 rules on the 3 programs, boot task registered' ($nsOut -match '\[netsh\]' -and $rules2.Count -eq 6 -and $progs2 -match 'llama-server' -and $task2 -and $task2.Principal.UserId -match 'SYSTEM|S-1-5-18') ("rules=$($rules2.Count) programs=[$progs2] remote=[$addr2] task=$(if ($task2) { "$($task2.TaskPath)$($task2.TaskName) as $($task2.Principal.UserId)" } else { 'missing' })")
$o3 = (Invoke-Quiet { & (Join-Path $root 'python\python.exe') -X utf8 $probeFile } | Out-String).Trim()
$o4 = (Invoke-Quiet { & $otherPy $probeFile } | Out-String).Trim()
Check 'netsh-made rules: leCore python.exe blocked, another Python not' ($o3 -match 'TCP-FAIL' -and $o3 -notmatch '-OK' -and $o4 -match 'TCP-OK') ("leCore: $($o3 -replace "`r?`n", ' | ') // other: $($o4 -replace "`r?`n", ' | ')")
$null = Invoke-Quiet { & schtasks.exe /Delete /TN '\Zero\Zero model containment check' /F }

# 8c. the Vulkan backend on a software Vulkan device (CI only; never shipped) ----------------------
# The runner has no GPU. Install the Khronos loader + Mesa lavapipe, restart the model service (it runs as
# LOCAL SERVICE in session 0, like on the laptop) and check llama.cpp's Vulkan backend loads the device
# and runs the model on it.
try {
    $vk = $stackJson.ci_vulkan
    $vkDir = Join-Path $env:ProgramData 'lecore-ci-vulkan'
    New-Item -ItemType Directory -Force -Path $vkDir | Out-Null
    $lz = Join-Path $vkDir 'loader.zip'; $mz = Join-Path $vkDir 'mesa.7z'
    & curl.exe --fail --location --silent --show-error --retry 3 --output $lz $vk.loader.url
    & curl.exe --fail --location --silent --show-error --retry 3 --output $mz $vk.icd.url
    if ((Get-FileHash $lz -Algorithm SHA256).Hash.ToLower() -ne $vk.loader.sha256) { throw 'Vulkan loader sha256 mismatch' }
    if ((Get-FileHash $mz -Algorithm SHA256).Hash.ToLower() -ne $vk.icd.sha256) { throw 'Mesa sha256 mismatch' }
    Expand-Archive -LiteralPath $lz -DestinationPath (Join-Path $vkDir 'loader') -Force
    Copy-Item -Force (Join-Path (Join-Path $vkDir 'loader') ($vk.loader.dll -replace '/', '\')) (Join-Path $env:SystemRoot 'System32\vulkan-1.dll')
    $7z = (Get-Command 7z.exe -ErrorAction SilentlyContinue).Source; if (-not $7z) { $7z = "$env:ProgramFiles\7-Zip\7z.exe" }
    $null = Invoke-Quiet { & $7z x -y "-o$vkDir\mesa" $mz 'x64\vulkan_lvp.dll' 'x64\lvp_icd.x86_64.json' }
    $icd = Join-Path $vkDir 'mesa\x64\lvp_icd.x86_64.json'
    & icacls.exe $vkDir /grant '*S-1-5-19:(OI)(CI)RX' /T /C /Q | Out-Null
    $null = Invoke-Quiet { & reg.exe add 'HKLM\SOFTWARE\Khronos\Vulkan\Drivers' /v $icd /t REG_DWORD /d 0 /f }
    Write-Host ("  mesa files: " + ((Get-ChildItem -Recurse -File (Join-Path $vkDir 'mesa') | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', '))
    Write-Host ("  icd json: " + (Get-Content -Raw $icd))
    $vkinfo = Join-Path (Join-Path $vkDir 'loader') (($vk.loader.dll -replace '/', '\') -replace 'vulkan-1\.dll$', 'vulkaninfo.exe')
    $env:VK_LOADER_DEBUG = 'error,warn,driver'
    Write-Host (Invoke-Quiet { & $vkinfo --summary } | Select-Object -First 60 | Out-String)
    Remove-Item Env:\VK_LOADER_DEBUG
    # ggml-vulkan skips CPU-type Vulkan devices (lavapipe) unless they are selected explicitly. CI only:
    # the laptops have a real GPU (Radeon 8060S iGPU is picked as the first non-CPU device; on the P16
    # the dedicated RTX PRO 5000 is preferred).
    $env:GGML_VK_VISIBLE_DEVICES = '0'
    $devs = Invoke-Quiet { & (Join-Path $root 'llama\llama-server.exe') --list-devices } | Out-String
    Write-Host $devs
    $xmlPath = Join-Path $root 'services\lecore-llama.xml'
    $x = Get-Content -Raw $xmlPath
    if ($x -notmatch 'GGML_VK_VISIBLE_DEVICES') {
        [IO.File]::WriteAllText($xmlPath, ($x -replace '</service>', "  <env name=`"GGML_VK_VISIBLE_DEVICES`" value=`"0`"/>`r`n</service>"), (New-Object Text.UTF8Encoding($false)))
    }
    Check 'llama.cpp Vulkan backend sees a Vulkan device (Mesa lavapipe, CI only)' ($devs -match 'Vulkan\d') (($devs -split "`n" | Where-Object { $_ -match 'Vulkan|llvmpipe' }) -join ' / ')
    # CI only: debug log level (one argument per line in llama-args.txt) so the log names the device.
    [IO.File]::WriteAllLines((Join-Path $data 'llama-args.txt'), [string[]]@('-lv', '4'))
    $mark = (Get-Content (Join-Path $logs 'lecore-llama.out.log')).Count
    Restart-Service lecore-llama
    $null = Wait-Http 'http://127.0.0.1:8080/health' 300
    $cc2 = Post-Json 'http://127.0.0.1:8080/v1/chat/completions' @{ model = 'x'; max_tokens = 8; messages = @(@{ role = 'user'; content = 'Say hi.' }) } 600 (Get-KeyHeader)
    $since = (Get-Content (Join-Path $logs 'lecore-llama.out.log') | Select-Object -Skip $mark) -join "`n"
    $vkLines = ($since -split "`n" | Where-Object { $_ -match 'Vulkan0|llvmpipe|offload' } | Select-Object -First 8) -join ' / '
    Remove-Item -Force (Join-Path $data 'llama-args.txt')
    Check 'model service runs the model on the Vulkan device (as LOCAL SERVICE)' ([bool]$cc2.choices[0].message.content -and $since -match 'Vulkan0') ("answer: {0} | log: {1}" -f $cc2.choices[0].message.content, $vkLines)
} catch { Check 'llama.cpp Vulkan backend on a software Vulkan device (CI only)' $false $_.Exception.Message }

# 9. PSScriptAnalyzer -----------------------------------------------------------------------------
$files = @(Get-ChildItem -Recurse -Path (Join-Path $RepoRoot 'windows') -Include *.ps1) + @(Get-ChildItem (Join-Path $RepoRoot 'provision') -Filter 'windows-*.ps1')
$issues = @($files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Error, ParseError })
foreach ($i in $issues) { Write-Host ("  {0}:{1} {2} {3}" -f $i.ScriptName, $i.Line, $i.RuleName, $i.Message) }
$warn = @($files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Severity Warning })
Check 'PSScriptAnalyzer: no errors' ($issues.Count -eq 0) ("{0} files, {1} errors, {2} warnings" -f $files.Count, $issues.Count, $warn.Count)

# report --------------------------------------------------------------------------------------------
$md = @('### Smoke test (GitHub Actions Windows runner, lockdown skipped)', '', '| | Check | Evidence |', '|---|---|---|') + $script:Rows
$md -join "`n" | Set-Content -LiteralPath $Report -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) { $md -join "`n" | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
foreach ($l in 'lecore-chat.out.log', 'lecore-chat.err.log', 'lecore-llama.out.log', 'lecore-llama.err.log') { Write-Host "---- $l"; Write-Host (Tail (Join-Path $logs $l) 60) }
if ($script:Failed) { Write-Host "::error::$script:Failed smoke check(s) failed"; exit 1 }
exit 0   # (the lockdown guard check leaves $LASTEXITCODE = 1 on purpose)
