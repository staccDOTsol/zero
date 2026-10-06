<#
  Zero model server launcher (service "lecore-llama", run by WinSW as LOCAL SERVICE).

  Reads C:\ProgramData\leCore+\model.txt (one line: a file name in C:\ProgramData\leCore+\models\,
  or an absolute path) and runs:
      llama-server.exe --host 127.0.0.1 --port 8080 -ngl 999 -m <model>
  plus any extra arguments listed one per line in C:\ProgramData\leCore+\llama-args.txt.

  No model configured -> logs why and exits 0, so the service stops cleanly (no restart loop).
  After adding a model:  Start-Service lecore-llama   (or reboot).
#>
$ErrorActionPreference = 'Stop'
$data = $env:LECORE_PLUS_DATA
if (-not $data) { $data = Join-Path $env:ProgramData 'leCore+' }
$root = $env:LECORE_PLUS_ROOT
if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
$server = Join-Path $root 'llama\llama-server.exe'
$modelTxt = Join-Path $data 'model.txt'

function Say([string]$m) { Write-Output ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) }

if (-not (Test-Path -LiteralPath $modelTxt)) {
    Say "no model configured ($modelTxt does not exist); llama-server not started. The chat runs memory-only."
    exit 0
}
$name = (Get-Content -LiteralPath $modelTxt -TotalCount 1)
if ($null -eq $name) { $name = '' }
$name = $name.Trim().Trim([char]0xFEFF)
if (-not $name) {
    Say "no model configured ($modelTxt is empty); llama-server not started. The chat runs memory-only."
    exit 0
}
if ([IO.Path]::IsPathRooted($name)) { $model = $name } else { $model = Join-Path (Join-Path $data 'models') $name }
if (-not (Test-Path -LiteralPath $model)) {
    Say "model.txt names '$name' but $model does not exist; llama-server not started."
    exit 0
}
$extra = @()
$argsFile = Join-Path $data 'llama-args.txt'
if (Test-Path -LiteralPath $argsFile) {
    $extra = @(Get-Content -LiteralPath $argsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
$alias = [IO.Path]::GetFileNameWithoutExtension($model)
$cmd = @('--host', '127.0.0.1', '--port', '8080', '-ngl', '999', '-m', $model, '--alias', $alias) + $extra
Say ("starting: `"$server`" " + ($cmd -join ' '))
# llama-server logs to stderr; fold it into stdout as plain text so Windows PowerShell never turns a log
# line into a terminating NativeCommandError (WinSW writes both streams to C:\ProgramData\leCore+\logs).
$ErrorActionPreference = 'Continue'
& $server @cmd 2>&1 | ForEach-Object { "$_" }
$code = $LASTEXITCODE
Say "llama-server exited with $code"
exit $code
