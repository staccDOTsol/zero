<#
.SYNOPSIS
  Gets the official Windows 11 x64 English (US) ISO from Microsoft. CI runner only.

  -Resolve   asks Microsoft's software-download service for the current ISO link with pbatard's Fido
             (pinned v1.71, sha256-checked), retrying; writes the link (valid ~24 h) to -UrlFile.
             If Microsoft refuses the runner (e.g. message code 715-123130), the exact message is
             printed, written to the job summary and to <UrlFile>.error, and the script exits 1.
  -Download  downloads the ISO (from -IsoUrl, the user's input, or the resolved link in -UrlFile),
             then checks it: sha256 against -IsoSha256 when given, otherwise against the hash Microsoft
             publishes for "English 64-bit" on microsoft.com/en-us/software-download/windows11, and the
             Microsoft Authenticode signature of setup.exe inside the ISO.
  A runner-local path (self-hosted runner) is accepted as -IsoUrl too.
#>
[CmdletBinding()]
param(
    [switch]$Resolve,
    [switch]$Download,
    [string]$UrlFile = (Join-Path (Get-Location) 'iso-url.txt'),
    [string]$IsoUrl,
    [string]$IsoSha256,
    [string]$OutIso = (Join-Path (Get-Location) 'win11.iso'),
    [int]$Attempts = 4
)
. (Join-Path $PSScriptRoot 'common.ps1')
$pins = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'stack.json') | ConvertFrom-Json

if ($Resolve) {
    Write-Step "Resolve the official ISO link with Fido $($pins.fido.version)"
    $fido = Join-Path ([IO.Path]::GetTempPath()) 'Fido.ps1'
    Invoke-PinnedDownload -Url $pins.fido.url -Dest $fido -Sha256 $pins.fido.sha256 | Out-Null
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $url = $null; $last = ''
    for ($i = 1; $i -le $Attempts -and -not $url; $i++) {
        Write-Host "  attempt $i/$Attempts"
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $out = & $ps -NoProfile -ExecutionPolicy Bypass -File $fido -Win 11 -Rel Latest -Ed Pro -Lang '^English$' -Arch x64 -GetUrl 2>&1 | ForEach-Object { "$_" } | Out-String
        $ErrorActionPreference = $old
        $m = [regex]::Match($out, 'https://\S+')
        if ($m.Success) { $url = $m.Value.Trim() } else {
            $last = $out.Trim()
            Write-Host "  Fido: $last"
            if ($i -lt $Attempts) { Start-Sleep -Seconds (60 * $i) }
        }
    }
    if (-not $url) {
        $msg = "Microsoft refused to hand this runner ($env:RUNNER_NAME, $env:ImageOS) a Windows 11 ISO link after $Attempts attempts. Fido said: $last"
        Set-Content -LiteralPath "$UrlFile.error" -Value $msg -Encoding utf8
        Write-Summary "### Windows ISO: BLOCKED`n`n$msg`n"
        Write-Host "::error::$msg"
        exit 1
    }
    $file = ([regex]::Match($url, '/([^/?]+\.iso)')).Groups[1].Value
    Write-Host "  OK: $file"
    Set-Content -LiteralPath $UrlFile -Value $url -Encoding ascii -NoNewline
    Write-Summary "### Windows ISO link resolved by Fido on $env:ImageOS`n`n``$file```n"
}

if ($Download) {
    if (-not $IsoUrl) { $IsoUrl = (Get-Content -Raw -LiteralPath $UrlFile).Trim() }
    Write-Step 'Download the ISO'
    if (Test-Path -LiteralPath $IsoUrl) {
        Copy-Item -LiteralPath $IsoUrl -Destination $OutIso -Force
        $hash = Get-Sha256 $OutIso
    } else {
        $hash = Invoke-PinnedDownload -Url $IsoUrl -Dest $OutIso -Sha256 $IsoSha256 -AllowUnpinned
    }
    $name = ([regex]::Match($IsoUrl, '([^/\\?]+\.iso)')).Groups[1].Value
    Write-Host ("  {0} {1:N2} GB sha256 {2}" -f $name, ((Get-Item $OutIso).Length / 1GB), $hash)

    if (-not $IsoSha256) {
        Write-Step 'Compare with the hash Microsoft publishes (English 64-bit)'
        $page = Invoke-WebRequest -UseBasicParsing -TimeoutSec 60 -UserAgent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' -Uri 'https://www.microsoft.com/en-us/software-download/windows11'
        $m = [regex]::Match($page.Content, 'English 64-bit\s*</td>\s*<td>\s*([A-Fa-f0-9]{64})')
        if (-not $m.Success) { throw 'could not find the published "English 64-bit" hash on microsoft.com' }
        $published = $m.Groups[1].Value.ToLowerInvariant()
        if ($published -ne $hash) { throw "ISO sha256 $hash does not match Microsoft's published English 64-bit hash $published" }
        Write-Host "  matches Microsoft's published hash $published"
    }

    Write-Step 'Check the Microsoft signature inside the ISO'
    $drive = (Mount-IsoRoot $OutIso).Substring(0, 1)
    try {
        $sig = Get-AuthenticodeSignature -FilePath "${drive}:\setup.exe"
        $subject = $sig.SignerCertificate.Subject
        Write-Host "  setup.exe: $($sig.Status) $subject"
        if ($sig.Status -ne 'Valid' -or $subject -notmatch 'O=Microsoft Corporation') { throw "setup.exe in the ISO is not validly signed by Microsoft ($($sig.Status), $subject)" }
        $wim = @(Get-ChildItem "${drive}:\sources" -Include install.wim, install.esd -File -Recurse | Select-Object -First 1)
        $idx = Get-WindowsImage -ImagePath $wim[0].FullName
        $idx | ForEach-Object { Write-Host ("  index {0}: {1}" -f $_.ImageIndex, $_.ImageName) }
        $pro = Get-WindowsImage -ImagePath $wim[0].FullName -Name 'Windows 11 Pro'
        Write-Host ("  Windows 11 Pro: version {0}  ({1})" -f $pro.Version, $wim[0].Name)
        @{ iso = $name; iso_sha256 = $hash; source = $(if (Test-Path -LiteralPath $IsoUrl) { 'local path' } else { ([uri]$IsoUrl).Host }); windows_version = "$($pro.Version)"; image = $wim[0].Name } |
            ConvertTo-Json | Set-Content -LiteralPath "$OutIso.json" -Encoding utf8
        Write-Summary "### Windows ISO`n`n``$name`` sha256 ``$hash``, Windows 11 Pro $($pro.Version)`n"
    } finally {
        Dismount-DiskImage -ImagePath $OutIso | Out-Null
    }
}
