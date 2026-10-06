<#
.SYNOPSIS
  Installs the Zero stack (leCore+): llama.cpp's llama-server (Vulkan) on 127.0.0.1:8080 and the
  leCore chat on 127.0.0.1:7860, as two Windows services, plus the "Zero" Start-menu and sign-in
  app window. Then applies the Zero model containment (lockdown.ps1: llama-server and leCore's
  Python can reach only 127.0.0.1; Windows itself networks normally) unless -SkipLockdown.

.DESCRIPTION
  Everything comes from .\payload next to this script; nothing is downloaded. Safe to run again:
  an identical install is detected and only the lockdown is re-applied.

  Layout (see the repo README):
    C:\Program Files\leCore+\        llama\  python\  lecore\  nltk_data\  bin\  services\  setup\
    C:\ProgramData\leCore+\          models\  model.txt  memory\  logs\  work\  cache\  lockdown\

  Windows PowerShell 5.1 compatible (runs during Windows Setup).

.PARAMETER SkipLockdown
  Test mode: install and start everything but do not run lockdown.ps1.
.PARAMETER TestMode
  CI: additionally run the chat service with the in-process egress guard
  (LECORE_PLUS_EGRESS_GUARD=1), which logs and refuses any non-loopback connection.
.PARAMETER NoStart
  Register the services but do not start them (used in the specialize pass of Windows Setup;
  they start on the next boot).
#>
[CmdletBinding()]
param(
    [switch]$SkipLockdown,
    [switch]$TestMode,
    [switch]$NoStart,
    [string]$Phase = 'manual',
    [string]$InstallRoot = (Join-Path $env:ProgramFiles 'leCore+'),
    [string]$DataRoot = (Join-Path $env:ProgramData 'leCore+')
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Src = $PSScriptRoot
$LocalServiceSid = 'S-1-5-19'      # NT AUTHORITY\LOCAL SERVICE (language independent)
$ProductName = 'Zero'
$ChatUrl = 'http://127.0.0.1:7860'

function Say([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'install.ps1 must run elevated (Administrator or SYSTEM).'
    }
}

function Get-Sha256([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Expand-Zip([string]$Zip, [string]$Dest) {
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path -LiteralPath $tar) {
        & $tar -xf $Zip -C $Dest
        if ($LASTEXITCODE -ne 0) { throw "tar.exe failed ($LASTEXITCODE) on $Zip" }
    } else {
        Expand-Archive -LiteralPath $Zip -DestinationPath $Dest -Force
    }
}

function Reset-Dir([string]$Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Grant-LocalService([string]$Path, [string]$Rights) {
    # (OI)(CI) inherit to files and subfolders. M = modify, RX = read & execute.
    & icacls.exe $Path /grant "*${LocalServiceSid}:(OI)(CI)$Rights" /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Path" }
}

function Set-LlamaApiKey([string]$KeyFile) {
    # Per-machine API key for llama-server on 127.0.0.1:8080. A web page that DNS-rebinds its own name
    # to 127.0.0.1 could otherwise use the model. 256 random bits from the OS CSPRNG; created once per
    # install (Windows Setup's specialize pass on each laptop), kept on re-runs. Readable only by the
    # two Zero services (their service SIDs NT SERVICE\lecore-llama / NT SERVICE\lecore-chat), SYSTEM
    # and Administrators; not by other LOCAL SERVICE services and not by users.
    $dir = Split-Path -Parent $KeyFile
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' `
        'NT SERVICE\lecore-llama:(OI)(CI)RX' 'NT SERVICE\lecore-chat:(OI)(CI)RX' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $dir" }
    $fresh = $false
    if (-not (Test-Path -LiteralPath $KeyFile) -or (Get-Item -LiteralPath $KeyFile).Length -lt 64) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
        [IO.File]::WriteAllText($KeyFile, $hex, (New-Object Text.ASCIIEncoding))
        $fresh = $true
    }
    & icacls.exe $KeyFile /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' 'NT SERVICE\lecore-llama:R' 'NT SERVICE\lecore-chat:R' /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $KeyFile" }
    Say ("llama-server API key: {0} ({1})" -f $KeyFile, $(if ($fresh) { 'generated for this machine' } else { 'kept' }))
}

function ConvertTo-XmlText([string]$s) { [Security.SecurityElement]::Escape($s) }

function Write-WinSWConfig {
    param([string]$Path, [string]$Id, [string]$Name, [string]$Description, [string]$Executable,
          [string]$Arguments, [string]$WorkDir, [hashtable]$Env)
    $envXml = ($Env.Keys | Sort-Object | ForEach-Object {
        '  <env name="{0}" value="{1}"/>' -f (ConvertTo-XmlText $_), (ConvertTo-XmlText $Env[$_])
    }) -join "`r`n"
    $xml = @"
<service>
  <id>$(ConvertTo-XmlText $Id)</id>
  <name>$(ConvertTo-XmlText $Name)</name>
  <description>$(ConvertTo-XmlText $Description)</description>
  <executable>$(ConvertTo-XmlText $Executable)</executable>
  <arguments>$(ConvertTo-XmlText $Arguments)</arguments>
  <workingdirectory>$(ConvertTo-XmlText $WorkDir)</workingdirectory>
  <startmode>Automatic</startmode>
  <stoptimeout>20 sec</stoptimeout>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <resetfailure>1 hour</resetfailure>
  <logpath>$(ConvertTo-XmlText (Join-Path $DataRoot 'logs'))</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
$envXml
</service>
"@
    [IO.File]::WriteAllText($Path, $xml, (New-Object Text.UTF8Encoding($false)))
}

function Install-WinSWService {
    param([string]$Id, [string]$ServicesDir, [string]$WinSW)
    $exe = Join-Path $ServicesDir "$Id.exe"
    Copy-Item -Force $WinSW $exe
    & $exe install
    if ($LASTEXITCODE -ne 0) { throw "WinSW install of $Id failed ($LASTEXITCODE)" }
    # Least privilege: run as LOCAL SERVICE, not LocalSystem. sc.exe, not WMI: in Windows Setup's
    # specialize pass Win32_Service.Change fails with "Provider failure" (0x80041004). Start-Process with
    # one argument string, because Windows PowerShell drops an empty "" argument (password= "").
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\sc.exe') -Wait -PassThru -NoNewWindow `
        -ArgumentList ('config "{0}" obj= "NT AUTHORITY\LocalService" password= ""' -f $Id)
    if ($p.ExitCode -ne 0) { throw "sc config $Id obj= LocalService failed ($($p.ExitCode))" }
    $qc = (& sc.exe qc $Id) -join ' '
    if ($qc -notmatch 'SERVICE_START_NAME\s*:\s*NT AUTHORITY\\LocalService') { throw "service $Id does not run as LOCAL SERVICE: $qc" }
    & sc.exe failureflag $Id 1 | Out-Null
    # Give the service its own SID (NT SERVICE\<id>) in its token, so files can be shared with just it.
    & sc.exe sidtype $Id unrestricted | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc sidtype $Id unrestricted failed ($LASTEXITCODE)" }
}

function Remove-ServiceIfPresent([string]$Id, [string]$ServicesDir) {
    $svc = Get-Service -Name $Id -ErrorAction SilentlyContinue
    if (-not $svc) { return }
    Say "removing existing service $Id"
    if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Id -Force -ErrorAction SilentlyContinue }
    $exe = Join-Path $ServicesDir "$Id.exe"
    if (Test-Path -LiteralPath $exe) { & $exe uninstall | Out-Null } else { & sc.exe delete $Id | Out-Null }
    for ($i = 0; $i -lt 30 -and (Get-Service -Name $Id -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
}

function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$Icon, [int]$WindowStyle = 1, [string]$Description = '') {
    $dir = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($Path)
    $lnk.TargetPath = $Target
    $lnk.Arguments = $Arguments
    if ($Icon) { $lnk.IconLocation = $Icon }
    $lnk.WindowStyle = $WindowStyle
    $lnk.Description = $Description
    $lnk.Save()
}

# --------------------------------------------------------------------------------------------------
Assert-Admin
New-Item -ItemType Directory -Force -Path (Join-Path $DataRoot 'logs') | Out-Null
$transcript = Join-Path $DataRoot ("logs\install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -LiteralPath $transcript -Force | Out-Null
try {
    Say "Zero / leCore+ install (phase=$Phase, skipLockdown=$SkipLockdown, testMode=$TestMode)"
    Say "source $Src"
    $manifestPath = Join-Path $Src 'manifest.json'
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $manifestHash = Get-Sha256 $manifestPath

    $marker = Join-Path $InstallRoot 'installed.json'
    $already = $false
    if (Test-Path -LiteralPath $marker) {
        try { $already = ((Get-Content -Raw $marker | ConvertFrom-Json).manifest_sha256 -eq $manifestHash) } catch { $already = $false }
    }

    $llamaDir = Join-Path $InstallRoot 'llama'
    $pyDir = Join-Path $InstallRoot 'python'
    $lecoreDir = Join-Path $InstallRoot 'lecore'
    $nltkDir = Join-Path $InstallRoot 'nltk_data'
    $binDir = Join-Path $InstallRoot 'bin'
    $svcDir = Join-Path $InstallRoot 'services'
    $setupDir = Join-Path $InstallRoot 'setup'
    $python = Join-Path $pyDir 'python.exe'

    if ($already -and (Test-Path -LiteralPath $python)) {
        Say 'identical install already present; skipping the stack install'
    } else {
        Say 'verifying payload against manifest.json'
        foreach ($f in $manifest.files) {
            $p = Join-Path $Src ($f.path -replace '/', '\')
            if (-not (Test-Path -LiteralPath $p)) { throw "payload file missing: $($f.path)" }
            if ((Get-Sha256 $p) -ne $f.sha256) { throw "payload file corrupt (sha256): $($f.path)" }
        }
        $payload = Join-Path $Src 'payload'

        foreach ($id in 'lecore-chat', 'lecore-llama') { Remove-ServiceIfPresent $id $svcDir }

        Say "llama.cpp $($manifest.llama_cpp.tag) -> $llamaDir"
        Reset-Dir $llamaDir
        Expand-Zip (Join-Path $payload $manifest.llama_cpp.asset) $llamaDir
        if (-not (Test-Path (Join-Path $llamaDir 'llama-server.exe'))) { throw 'llama-server.exe missing after extract' }

        Say "Python $($manifest.python.version) embeddable -> $pyDir"
        Reset-Dir $pyDir
        Expand-Zip (Join-Path $payload $manifest.python.asset) $pyDir
        $zipName = (Get-ChildItem $pyDir -Filter 'python3*.zip' | Select-Object -First 1).Name
        $pth = "$zipName`r`n.`r`nLib\site-packages`r`nimport site`r`n"
        [IO.File]::WriteAllText((Join-Path $pyDir $manifest.python.pth), $pth, (New-Object Text.ASCIIEncoding))
        New-Item -ItemType Directory -Force -Path (Join-Path $pyDir 'Lib\site-packages') | Out-Null
        Copy-Item -Force (Join-Path $Src 'bin\sitecustomize.py') (Join-Path $pyDir 'sitecustomize.py')

        Say 'wheels from the local wheelhouse (pip --no-index; no network)'
        $wheelhouse = Join-Path $payload 'wheelhouse'
        $pipWheel = (Get-ChildItem $wheelhouse -Filter 'pip-*.whl' | Select-Object -First 1).FullName
        # pip itself runs from its wheel and is not installed into the target (pip refuses to "modify pip").
        $req = Join-Path $env:TEMP 'lecore-plus-requirements.txt'
        Get-Content -LiteralPath (Join-Path $wheelhouse 'requirements.lock.txt') | Where-Object { $_ -notmatch '^pip==' } |
            Set-Content -LiteralPath $req -Encoding ascii
        $pipArgs = @('-X', 'utf8', (Join-Path $pipWheel 'pip'), 'install', '--no-index', '--find-links', $wheelhouse,
                     '--require-hashes', '--only-binary=:all:', '--disable-pip-version-check', '--no-cache-dir',
                     '--no-warn-script-location', '--target', (Join-Path $pyDir 'Lib\site-packages'), '-r', $req)
        & $python @pipArgs
        if ($LASTEXITCODE -ne 0) { throw "offline pip install failed ($LASTEXITCODE)" }

        Say "leCore $($manifest.lecore.commit) -> $lecoreDir"
        Reset-Dir $lecoreDir
        Expand-Zip (Join-Path $payload $manifest.lecore.asset) $lecoreDir
        if (-not (Test-Path (Join-Path $lecoreDir 'chat_server.py'))) { throw 'chat_server.py missing after extract' }
        New-Item -ItemType Directory -Force -Path (Join-Path $lecoreDir 'memories') | Out-Null

        Say "NLTK data -> $nltkDir"
        Reset-Dir $nltkDir
        Get-ChildItem -Recurse -File (Join-Path $payload 'nltk_data') -Filter *.zip | ForEach-Object {
            $rel = $_.Directory.FullName.Substring((Join-Path $payload 'nltk_data').Length).TrimStart('\')
            $destDir = Join-Path $nltkDir $rel
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            Copy-Item -Force $_.FullName $destDir
            Expand-Zip $_.FullName $destDir
        }

        Say "launchers -> $binDir"
        Reset-Dir $binDir
        Copy-Item -Force (Join-Path $Src 'bin\*') $binDir

        Say 'precompiling Python (the services run as LOCAL SERVICE and cannot write __pycache__ here)'
        & $python -X utf8 -m compileall -q -j 0 $lecoreDir $binDir | Out-Null
        Say "compileall exit $LASTEXITCODE (non-zero only means some research scripts in the leCore tree do not compile; they are never imported by the chat)"

        Say 'copying setup scripts for later re-application'
        Reset-Dir $setupDir
        foreach ($f in 'install.ps1', 'lockdown.ps1', 'open-egress.ps1', 'manifest.json', 'README.md') {
            if (Test-Path (Join-Path $Src $f)) { Copy-Item -Force (Join-Path $Src $f) $setupDir }
        }
    }

    Say "data -> $DataRoot"
    foreach ($d in 'models', 'memory', 'logs', 'work', 'cache', 'cache\matplotlib', 'lockdown') {
        New-Item -ItemType Directory -Force -Path (Join-Path $DataRoot $d) | Out-Null
    }
    $memory = Join-Path $DataRoot 'memory'
    if (-not (Get-ChildItem -LiteralPath $memory -Force | Select-Object -First 1)) {
        Say 'seeding the leCore memory partition from the shipped release_bundle'
        Copy-Item -Recurse -Force (Join-Path $lecoreDir 'release_bundle\*') $memory
    }
    foreach ($d in 'memory', 'logs', 'work', 'cache') { Grant-LocalService (Join-Path $DataRoot $d) 'M' }
    Grant-LocalService (Join-Path $DataRoot 'models') 'RX'
    Grant-LocalService (Join-Path $lecoreDir 'memories') 'M'
    Grant-LocalService $InstallRoot 'RX'

    Say 'services (WinSW wrapper, LOCAL SERVICE account)'
    New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
    foreach ($id in 'lecore-chat', 'lecore-llama') { Remove-ServiceIfPresent $id $svcDir }
    $winsw = Join-Path (Join-Path $Src 'payload') $manifest.winsw.asset
    if (-not (Test-Path -LiteralPath $winsw)) { $winsw = Join-Path $svcDir 'WinSW.exe' }   # re-run from setup\
    else { Copy-Item -Force $winsw (Join-Path $svcDir 'WinSW.exe') }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $keyFile = Join-Path $DataRoot 'secret\llama-api-key'

    Write-WinSWConfig -Path (Join-Path $svcDir 'lecore-llama.xml') -Id 'lecore-llama' `
        -Name "$ProductName model server (llama.cpp)" `
        -Description 'llama.cpp llama-server (Vulkan) on 127.0.0.1:8080 for the model named in C:\ProgramData\leCore+\model.txt. With no model configured it only waits (nothing listens).' `
        -Executable $ps -Arguments ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $binDir 'run-llama.ps1')) `
        -WorkDir (Join-Path $DataRoot 'work') -Env @{ LECORE_PLUS_DATA = $DataRoot; LECORE_PLUS_ROOT = $InstallRoot; LECORE_PLUS_LLM_KEY_FILE = $keyFile }

    $chatEnv = @{
        LECORE_LLM_URL     = 'http://127.0.0.1:8080/v1'
        LECORE_PLUS_LLM_KEY_FILE = $keyFile
        LECORE_PARTITION   = $memory
        LECORE_PLUS_DATA   = $DataRoot
        LECORE_PLUS_ROOT   = $InstallRoot
        LECORE_PLUS_TITLE  = $ProductName
        LECORE_HOME        = (Join-Path $DataRoot 'work')
        NLTK_DATA          = $nltkDir
        MPLCONFIGDIR       = (Join-Path $DataRoot 'cache\matplotlib')
        HF_HUB_OFFLINE     = '1'
        TRANSFORMERS_OFFLINE = '1'
    }
    if ($TestMode) { $chatEnv['LECORE_PLUS_EGRESS_GUARD'] = '1' }
    Write-WinSWConfig -Path (Join-Path $svcDir 'lecore-chat.xml') -Id 'lecore-chat' `
        -Name "$ProductName chat (leCore)" `
        -Description 'leCore chat (chat_server.py) on 127.0.0.1:7860. Memory-only when no model runs; uses llama-server on 127.0.0.1:8080 when one does.' `
        -Executable $python -Arguments ('-X utf8 -u "{0}"' -f (Join-Path $binDir 'lecore_plus_chat.py')) `
        -WorkDir (Join-Path $DataRoot 'work') -Env $chatEnv

    Install-WinSWService -Id 'lecore-llama' -ServicesDir $svcDir -WinSW $winsw
    Install-WinSWService -Id 'lecore-chat' -ServicesDir $svcDir -WinSW $winsw
    Set-LlamaApiKey $keyFile

    Say "Start menu + sign-in app window ($ProductName)"
    $edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (-not (Test-Path -LiteralPath $edge)) { $edge = Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    New-Shortcut -Path (Join-Path $programs "$ProductName.lnk") -Target $edge -Arguments "--app=$ChatUrl" `
        -Icon "$edge,0" -Description "$ProductName (leCore chat, local only)"
    New-Shortcut -Path (Join-Path $programs "StartUp\$ProductName.lnk") -Target $ps `
        -Arguments ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $binDir 'open-zero.ps1')) `
        -Icon "$edge,0" -WindowStyle 7 -Description "Opens $ProductName when you sign in"
    if (-not (Test-Path -LiteralPath $edge)) { Write-Warning "Microsoft Edge not found at $edge; shortcuts point at the standard path." }

    $info = [ordered]@{
        product          = $ProductName
        manifest_sha256  = $manifestHash
        installed_utc    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        phase            = $Phase
        llama_cpp        = $manifest.llama_cpp.tag
        python           = $manifest.python.version
        lecore_commit    = $manifest.lecore.commit
        winsw            = $manifest.winsw.version
    }
    [IO.File]::WriteAllText($marker, ($info | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))

    if (-not $NoStart) {
        Say 'starting services'
        Start-Service -Name 'lecore-chat'
        # With no model configured run-llama.ps1 only waits for one; nothing listens on :8080.
        try { Start-Service -Name 'lecore-llama' } catch { Say "lecore-llama: $($_.Exception.Message)" }
    }

    if ($SkipLockdown) {
        Say 'lockdown SKIPPED (-SkipLockdown)'
    } else {
        Say 'applying the Zero model containment (lockdown.ps1)'
        & (Join-Path $Src 'lockdown.ps1') -InstallBootTask
    }
    Say 'done'
} finally {
    Stop-Transcript | Out-Null
}
