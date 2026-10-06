<#
  Opens Zero when a user signs in (All Users Startup shortcut). Waits for the leCore chat service on
  127.0.0.1:7860 to answer (the service may still be booting right after sign-in), then runs exactly:
      msedge --app=http://127.0.0.1:7860
#>
$url = 'http://127.0.0.1:7860'
$edge = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path -LiteralPath $edge)) { $edge = Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }
$deadline = (Get-Date).AddMinutes(3)
while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Uri "$url/zero/status"
        if ($r.StatusCode -eq 200) { break }
    } catch { }
    Start-Sleep -Seconds 2
}
Start-Process -FilePath $edge -ArgumentList "--app=$url"
