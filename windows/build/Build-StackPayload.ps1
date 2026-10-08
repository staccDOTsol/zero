<#
.SYNOPSIS
  Builds lecore-plus-windows-stack.zip: the Zero (leCore+) stack installer, the model containment (lockdown.ps1),
  and an offline payload (llama.cpp Vulkan build, Python embeddable, a wheelhouse, leCore at the pinned
  commit, NLTK data, WinSW). Runs on the CI runner. Nothing in the zip downloads anything on the laptop.
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path (Get-Location) 'out'),
    [string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'lecore-stack')
)
. (Join-Path $PSScriptRoot 'common.ps1')

$winDir = Split-Path -Parent $PSScriptRoot
$pins = Get-Content -Raw -LiteralPath (Join-Path $winDir 'stack.json') | ConvertFrom-Json
$name = 'lecore-plus-windows-stack'
$stage = Join-Path $WorkDir $name
$payload = Join-Path $stage 'payload'
if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Force -Path $payload, $OutDir | Out-Null

Write-Step 'Scripts'
Copy-Item -Recurse -Force (Join-Path $winDir 'stack\*') $stage
Copy-Item -Force (Join-Path $winDir 'README.md') (Join-Path $stage 'README.md')

Write-Step "llama.cpp $($pins.llama_cpp.tag) Vulkan x64"
Invoke-PinnedDownload -Url $pins.llama_cpp.url -Dest (Join-Path $payload $pins.llama_cpp.asset) `
    -Sha256 $pins.llama_cpp.sha256 -Bytes $pins.llama_cpp.bytes | Out-Null

Write-Step 'MSVC runtime (app-local next to llama-server.exe)'
# The llama.cpp release zip does not carry vcruntime140.dll / vcruntime140_1.dll / msvcp140.dll (its binaries
# import them) and a clean Windows 11 install has none of them. Microsoft's redistributable link always
# serves the current version, so (like the ADK) it is checked by Microsoft's Authenticode signature instead
# of a pinned sha256; the version goes into manifest.json and every file's sha256 into its file list.
function Assert-MicrosoftSigned([string]$Path) {
    $s = Get-AuthenticodeSignature -FilePath $Path
    Write-Host "  $Path : $($s.Status) $($s.SignerCertificate.Subject)"
    if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "$Path is not validly signed by Microsoft" }
}
$vcDir = Join-Path $WorkDir 'vcredist'
New-Item -ItemType Directory -Force -Path $vcDir | Out-Null
$vcSetup = Join-Path $vcDir 'vc_redist.x64.exe'
Write-Host "  GET $($pins.msvc_runtime.url)"
& curl.exe --fail --location --silent --show-error --retry 5 --retry-delay 10 --output $vcSetup $pins.msvc_runtime.url
if ($LASTEXITCODE -ne 0) { throw "Visual C++ Redistributable download failed (curl exit $LASTEXITCODE)" }
Assert-MicrosoftSigned $vcSetup
$vcVersion = [version](Get-Item -LiteralPath $vcSetup).VersionInfo.ProductVersion
Write-Host "  Visual C++ Redistributable $vcVersion sha256 $(Get-Sha256 $vcSetup)"
# Installs (or upgrades) the runtime on the runner: 0 = done, 1638 = the same or a newer one is already
# there, 3010 = done, reboot wanted (not needed to read the files).
$p = Start-Process -FilePath $vcSetup -ArgumentList @('/install', '/quiet', '/norestart') -PassThru -Wait
Write-Host "  vc_redist.x64.exe /install exit $($p.ExitCode)"
if ($p.ExitCode -notin 0, 1638, 3010) { throw "vc_redist.x64.exe failed ($($p.ExitCode))" }
$vcPayload = Join-Path $payload 'msvc-runtime'
New-Item -ItemType Directory -Force -Path $vcPayload | Out-Null
$vcInstalled = [ordered]@{}
foreach ($f in $pins.msvc_runtime.files) {
    $src = Join-Path $env:SystemRoot "System32\$f"
    if (-not (Test-Path -LiteralPath $src)) { throw "$src missing after the redistributable install" }
    Assert-MicrosoftSigned $src
    $fv = [version](Get-Item -LiteralPath $src).VersionInfo.FileVersion.Split(' ')[0]
    if ($fv -lt $vcVersion) { throw "$src is $fv, older than the redistributable $vcVersion" }
    Copy-Item -Force $src (Join-Path $vcPayload $f)
    $vcInstalled[$f] = "$fv"
    Write-Host "  $f $fv"
}

Write-Step "Python $($pins.python.version) embeddable"
Invoke-PinnedDownload -Url $pins.python.url -Dest (Join-Path $payload $pins.python.asset) `
    -Sha256 $pins.python.sha256 -Bytes $pins.python.bytes | Out-Null

Write-Step "WinSW $($pins.winsw.version)"
Invoke-PinnedDownload -Url $pins.winsw.url -Dest (Join-Path $payload $pins.winsw.asset) -Sha256 $pins.winsw.sha256 | Out-Null

Write-Step 'Wheelhouse (win_amd64, hashes required)'
$wheelhouse = Join-Path $payload 'wheelhouse'
$lock = Join-Path $stage 'requirements.lock.txt'
$pyVer = ($pins.python.version -split '\.')[0..1] -join '.'
$py = (Get-Command python.exe).Source
Invoke-Native $py @('-m', 'pip', 'download', '--disable-pip-version-check', '--no-cache-dir', '--require-hashes', '--no-deps',
    '--only-binary=:all:', '--platform', 'win_amd64', '--python-version', $pyVer, '--implementation', 'cp',
    '--abi', $pins.python.abi, '-r', $lock, '-d', $wheelhouse) | Out-Null
Copy-Item -Force $lock (Join-Path $wheelhouse 'requirements.lock.txt')
Write-Host ("  {0} wheels" -f (Get-ChildItem $wheelhouse -Filter *.whl).Count)

Write-Step "leCore $($pins.lecore.commit)"
$git = Join-Path $WorkDir 'lecore.git'
Invoke-Native git.exe @('init', '--quiet', '--bare', $git) | Out-Null
Invoke-Native git.exe @('-C', $git, 'fetch', '--quiet', '--depth', '1', $pins.lecore.repo, $pins.lecore.commit) | Out-Null
$got = (& git.exe -C $git rev-parse FETCH_HEAD).Trim()
if ($got -ne $pins.lecore.commit) { throw "leCore fetch returned $got, expected $($pins.lecore.commit)" }
$short = $pins.lecore.commit.Substring(0, 12)
$lecoreZip = Join-Path $payload "lecore-$short.zip"
# Byte-exact tree (no CRLF conversion): core.autocrlf=false.
Invoke-Native git.exe @('-c', 'core.autocrlf=false', '-c', 'core.eol=lf', '-C', $git, 'archive', '--format=zip',
    '-o', $lecoreZip, $pins.lecore.commit) | Out-Null
$tree = (& git.exe -C $git rev-parse "$($pins.lecore.commit)^{tree}").Trim()
Write-Host "  tree $tree -> $lecoreZip"

Write-Step 'NLTK data (pre-staged; the laptop never calls nltk.download)'
foreach ($p in $pins.nltk_data.packages) {
    $url = "https://raw.githubusercontent.com/nltk/nltk_data/$($pins.nltk_data.commit)/packages/$($p.path)"
    $dest = Join-Path (Join-Path $payload 'nltk_data') ($p.path -replace '/', '\')
    Invoke-PinnedDownload -Url $url -Dest $dest -Sha256 $p.sha256 | Out-Null
}

Write-Step 'Manifest'
$files = Get-ChildItem -Recurse -File $payload | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path = $_.FullName.Substring($stage.Length + 1).Replace('\', '/'); bytes = $_.Length; sha256 = (Get-Sha256 $_.FullName) }
}
$manifest = [ordered]@{
    product       = 'Zero (leCore+) Windows stack'
    built_utc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    source_commit = $env:GITHUB_SHA
    llama_cpp     = [ordered]@{ tag = $pins.llama_cpp.tag; asset = $pins.llama_cpp.asset }
    msvc_runtime  = [ordered]@{ redistributable = "$vcVersion"; dir = 'msvc-runtime'; files = $vcInstalled }
    python        = [ordered]@{ version = $pins.python.version; asset = $pins.python.asset; pth = $pins.python.pth }
    winsw         = [ordered]@{ version = $pins.winsw.version; asset = $pins.winsw.asset }
    lecore        = [ordered]@{ commit = $pins.lecore.commit; tree = $tree; version = $pins.lecore.version; asset = "lecore-$short.zip" }
    nltk_data     = [ordered]@{ commit = $pins.nltk_data.commit }
    files         = @($files)
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding utf8

Write-Step 'Zip'
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
$7z = Get-SevenZip
Invoke-Native $7z @('a', '-tzip', '-mx=7', '-bso0', '-bsp0', $zip, $stage) | Out-Null
$hash = Get-Sha256 $zip
"$hash  $name.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
Write-Host ("  {0} ({1:N1} MB) sha256 {2}" -f $zip, ((Get-Item $zip).Length / 1MB), $hash)
Write-Summary "### Stack zip`n`n``$name.zip`` $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB, sha256 ``$hash```n"
