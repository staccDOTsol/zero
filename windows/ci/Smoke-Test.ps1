<#
.SYNOPSIS
  CI smoke test of lecore-plus-windows-stack.zip on the GitHub Actions Windows runner itself.
  Runs in Windows PowerShell 5.1 (what the laptop uses during Windows Setup).

  Proves, in order (each step prints PASS/FAIL and the evidence):
    1. install.ps1 -SkipLockdown -TestMode installs from the offline payload and registers both services
    2. llama service with no model configured: stops cleanly (exit 0), logs why
    3. chat on 127.0.0.1:7860 answers memory-only (GET /, title "Zero", POST /api/chat)
    4. provision\windows-add-models.ps1 -All pro with a test catalog (tiny test GGUF, never shipped):
       download, sha256 check, copy, model.txt; plus -DryRun against the real models/catalog.json per tier
    5. llama service with the model: /v1/models lists it, /v1/chat/completions answers
    6. chat -> model rung: a question memory cannot answer comes back with provenance "model-cached"
       and llama-server's log shows the request
    7. the chat process attempted no non-loopback connection or DNS lookup (egress guard log empty)
    8. lockdown.ps1 -WhatIf: exits 0, lists its actions, and changes nothing on this runner
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
function Wait-Http([string]$Url, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri $Url; if ($r.StatusCode -eq 200) { return $r } } catch { }
        Start-Sleep -Seconds 2
    }
    return $null
}
function Post-Json([string]$Url, $Body, [int]$Timeout = 300) {
    $json = $Body | ConvertTo-Json -Depth 5 -Compress
    Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec $Timeout
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
        ((Get-CimInstance Win32_Service -Filter "Name='lecore-chat'").StartName))
$pyv = & (Join-Path $root 'python\python.exe') -X utf8 -c "import sys, numpy, flask, matplotlib, nltk; print(sys.version.split()[0], 'numpy', numpy.__version__, 'flask', flask.__version__, 'nltk', nltk.__version__)"
Check 'embedded Python + wheels importable' ($LASTEXITCODE -eq 0) "$pyv"
$nl = & (Join-Path $root 'python\python.exe') -X utf8 -c "import os; os.environ['NLTK_DATA']=r'$root\nltk_data'; import nltk; print(nltk.download('gutenberg'), nltk.download('not-a-real-package', quiet=True)); from nltk.corpus import gutenberg; print(len(gutenberg.fileids()))"
Check 'nltk.download is an offline no-op; corpora pre-staged' (($nl -join ' ') -match '^True False \d+') ($nl -join ' ')

# 2. llama with no model -------------------------------------------------------------------------
Start-Sleep -Seconds 5
$llamaSvc = Get-Service lecore-llama
$llamaOut = Tail (Join-Path $logs 'lecore-llama.out.log') 5
Check 'llama service, no model configured: clean no-op' ($llamaSvc.Status -eq 'Stopped' -and $llamaOut -match 'no model configured') "status=$($llamaSvc.Status); log: $llamaOut"

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

# 5. llama with the model -------------------------------------------------------------------------
Start-Service lecore-llama
$models = Wait-Http 'http://127.0.0.1:8080/v1/models' 300
Check 'llama-server /v1/models answers' ($models -and $models.Content -match [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($tm.path))) $(if ($models) { $models.Content.Substring(0, [Math]::Min(300, $models.Content.Length)) } else { Tail (Join-Path $logs 'lecore-llama.out.log') 30 })
$dev = & (Join-Path $root 'llama\llama-server.exe') --list-devices 2>&1 | Out-String
Check 'llama.cpp devices on this runner (informational)' $true (($dev -split "`n" | Where-Object { $_ -match 'Vulkan|device|CPU|load_backend' }) -join ' / ')
try {
    $cc = Post-Json 'http://127.0.0.1:8080/v1/chat/completions' @{ model = 'x'; max_tokens = 24; messages = @(@{ role = 'user'; content = 'Say hello.' }) } 120
    Check 'llama-server /v1/chat/completions answers' ([bool]$cc.choices[0].message.content) ("{0}" -f $cc.choices[0].message.content)
} catch { Check 'llama-server /v1/chat/completions answers' $false $_.Exception.Message }

# 6. chat -> model rung ---------------------------------------------------------------------------
$viaModel = $null
foreach ($q in 'Write one short sentence about a lighthouse keeper named Brindle.', 'Invent a name for a purple teapot dragon.', 'Describe the taste of a zorbleberry in five words.') {
    try { $r = Post-Json 'http://127.0.0.1:7860/api/chat' @{ message = $q; workspace = 'default' } 300 } catch { $r = $null }
    if ($r -and $r.provenance -eq 'model-cached') { $viaModel = $r; break }
    Write-Host ("  not via model: provenance={0} text={1}" -f $(if ($r) { $r.provenance } else { 'error' }), $(if ($r) { $r.text } else { '' }))
}
$llamaLog = Tail (Join-Path $logs 'lecore-llama.out.log') 400
$served = ([regex]::Matches($llamaLog, 'POST /v1/chat/completions')).Count
Check 'chat on :7860 escalates to the model on :8080 (provenance model-cached)' ($null -ne $viaModel) $(if ($viaModel) { "text=$($viaModel.text)" } else { 'no model-cached answer' })
Check 'llama-server log shows chat completions served' ($served -ge 1) "$served POST /v1/chat/completions lines"

# 7. egress guard --------------------------------------------------------------------------------
$guard = Join-Path $logs 'egress-guard.log'
$chatLog = Tail (Join-Path $logs 'lecore-chat.out.log') 400
Check 'chat process made no non-loopback connection or DNS lookup' ((-not (Test-Path $guard) -or -not (Get-Content $guard)) -and $chatLog -match 'egress guard ON') $(if (Test-Path $guard) { Tail $guard 10 } else { 'egress-guard.log empty; guard was ON' })

# 8. lockdown -WhatIf -----------------------------------------------------------------------------
$lk = & (Join-Path $root 'setup\lockdown.ps1') -WhatIf -InstallBootTask 6>&1 4>&1 3>&1 2>&1 | Out-String
$lkOk = $?
$whatIfs = ([regex]::Matches($lk, 'What if:')).Count
$fwAfter = (Get-NetFirewallProfile | Sort-Object Name | ForEach-Object { "$($_.Name):$($_.Enabled):$($_.DefaultOutboundAction)" }) -join ' '
$rulesAfter = @(Get-NetFirewallRule -Direction Outbound -Enabled True -ErrorAction SilentlyContinue).Count
Check 'lockdown.ps1 -WhatIf runs clean' ($lkOk -and $whatIfs -gt 100) "$whatIfs 'What if' actions"
Check 'lockdown -WhatIf changed nothing on the runner' ($fwBefore -eq $fwAfter -and $rulesBefore -eq $rulesAfter -and -not (Get-NetFirewallRule -Name 'LecorePlus-ZeroEgress-Block' -ErrorAction SilentlyContinue)) "firewall before=[$fwBefore] after=[$fwAfter]; enabled outbound rules $rulesBefore -> $rulesAfter"
$guardMsg = try { & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$root\setup\lockdown.ps1' -FirewallOnly -WhatIf:`$false" 2>&1 | Out-String } catch { $_.Exception.Message }
Check 'lockdown refuses to run for real on a CI runner' ($guardMsg -match 'Refusing to apply the zero-egress lockdown') (($guardMsg -split "`n" | Select-Object -First 2) -join ' ')
$lk | Set-Content -LiteralPath (Join-Path (Split-Path $Report) 'lockdown-whatif.txt') -Encoding utf8

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
if ($script:Failed) { throw "$script:Failed smoke check(s) failed" }
