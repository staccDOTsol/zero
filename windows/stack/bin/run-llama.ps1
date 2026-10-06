<#
  Zero model server supervisor (service "lecore-llama", run by WinSW as LOCAL SERVICE).

  Reads C:\ProgramData\leCore+\model.txt (one line: a file name in C:\ProgramData\leCore+\models\,
  or an absolute path) and runs:
      llama-server.exe --host 127.0.0.1 --port 8080 -ngl 999 -m <model>
                       --alias <name> --offline --no-webui --cors-origins localhost
                       --api-key-file C:\ProgramData\leCore+\secret\llama-api-key
  plus any extra arguments listed one per line in C:\ProgramData\leCore+\llama-args.txt.

  No model configured -> a clean no-op: nothing listens on 127.0.0.1:8080, the chat runs memory-only,
  and this script waits (checking every 15 s), so a model added at imaging time starts by itself.
  It never exits 0 on its own: WinSW running as LOCAL SERVICE cannot report a clean stop to the
  service manager, so a non-zero exit (llama-server crashed) is what triggers the service's restart.
  After changing model.txt:  Restart-Service lecore-llama
#>
$ErrorActionPreference = 'Stop'
$data = $env:LECORE_PLUS_DATA
if (-not $data) { $data = Join-Path $env:ProgramData 'leCore+' }
$root = $env:LECORE_PLUS_ROOT
if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
$server = Join-Path $root 'llama\llama-server.exe'
$modelTxt = Join-Path $data 'model.txt'

function Say([string]$m) { Write-Output ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

function Get-ConfiguredModel {
    if (-not (Test-Path -LiteralPath $modelTxt)) { return @{ Path = $null; Why = "no model configured ($modelTxt does not exist)" } }
    $name = Get-Content -LiteralPath $modelTxt -TotalCount 1
    if ($null -eq $name) { $name = '' }
    $name = $name.Trim().Trim([char]0xFEFF)
    if (-not $name) { return @{ Path = $null; Why = "no model configured ($modelTxt is empty)" } }
    if ([IO.Path]::IsPathRooted($name)) { $p = $name } else { $p = Join-Path (Join-Path $data 'models') $name }
    if (-not (Test-Path -LiteralPath $p)) { return @{ Path = $null; Why = "model.txt names '$name' but $p does not exist" } }
    return @{ Path = $p; Why = '' }
}

$said = ''
while ($true) {
    $m = Get-ConfiguredModel
    if (-not $m.Path) {
        if ($m.Why -ne $said) { Say "$($m.Why); llama-server not started, nothing listens on 127.0.0.1:8080, the chat runs memory-only. Waiting for a model."; $said = $m.Why }
        Start-Sleep -Seconds 15
        continue
    }
    $said = ''
    $extra = @()
    $argsFile = Join-Path $data 'llama-args.txt'
    if (Test-Path -LiteralPath $argsFile) {
        $extra = @(Get-Content -LiteralPath $argsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
    }
    $keyFile = $env:LECORE_PLUS_LLM_KEY_FILE
    if (-not $keyFile) { $keyFile = Join-Path $data 'secret\llama-api-key' }
    if (-not (Test-Path -LiteralPath $keyFile)) {
        # fail closed: never serve the model without the per-machine API key
        if ($said -ne 'nokey') { Say "API key $keyFile missing; llama-server not started (re-run C:\Program Files\leCore+\setup\install.ps1)."; $said = 'nokey' }
        Start-Sleep -Seconds 15
        continue
    }
    $alias = [IO.Path]::GetFileNameWithoutExtension($m.Path)
    # --offline: llama.cpp never downloads anything; --no-webui: no built-in web UI (Zero's UI is the chat on
    # :7860); --cors-origins localhost: a web page from anywhere else cannot read the model's answers;
    # --api-key-file: every request except /health needs the per-machine key (DNS-rebinding pages can't
    # use the model); read from a file so the key is not on the command line.
    # The firewall blocks llama-server.exe from every non-loopback address on top of this.
    $cmd = @('--host', '127.0.0.1', '--port', '8080', '-ngl', '999', '-m', $m.Path, '--alias', $alias,
             '--offline', '--no-webui', '--cors-origins', 'localhost', '--api-key-file', $keyFile) + $extra
    Say ("starting: `"$server`" " + ($cmd -join ' '))
    # llama-server logs to stderr; fold it into stdout as plain text so Windows PowerShell never turns a log
    # line into a terminating NativeCommandError (WinSW writes the output to C:\ProgramData\leCore+\logs).
    $ErrorActionPreference = 'Continue'
    & $server @cmd 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    Say "llama-server exited with $code"
    if ($code -ne 0) { exit $code }
    Start-Sleep -Seconds 5
}
