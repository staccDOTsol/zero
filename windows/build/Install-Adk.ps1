<#
.SYNOPSIS
  Installs the Windows ADK "Deployment Tools" feature (oscdimg) on the CI runner from Microsoft's
  official ADK bootstrapper, checks Microsoft's Authenticode signatures, and exports OSCDIMG=<path>.
#>
[CmdletBinding()]
param([string]$WorkDir = (Join-Path ([IO.Path]::GetTempPath()) 'adk'))
. (Join-Path $PSScriptRoot 'common.ps1')
$pins = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'stack.json') | ConvertFrom-Json

function Find-Oscdimg {
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        $p = Join-Path $base 'Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}
function Assert-MicrosoftSigned([string]$Path) {
    $s = Get-AuthenticodeSignature -FilePath $Path
    Write-Host "  $Path : $($s.Status) $($s.SignerCertificate.Subject)"
    if ($s.Status -ne 'Valid' -or $s.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "$Path is not validly signed by Microsoft" }
}

$osc = Find-Oscdimg
if (-not $osc) {
    Write-Step 'Install Windows ADK Deployment Tools'
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    $setup = Join-Path $WorkDir 'adksetup.exe'
    & curl.exe --fail --location --silent --show-error --retry 5 --output $setup $pins.adk.url
    if ($LASTEXITCODE -ne 0) { throw "ADK bootstrapper download failed ($LASTEXITCODE)" }
    Assert-MicrosoftSigned $setup
    Write-Host "  adksetup.exe $((Get-Item $setup).VersionInfo.ProductVersion) sha256 $(Get-Sha256 $setup)"
    $log = Join-Path $WorkDir 'adk.log'
    $p = Start-Process -FilePath $setup -ArgumentList @('/quiet', '/norestart', '/ceip', 'off', '/features', 'OptionId.DeploymentTools', '/log', $log) -PassThru -Wait
    Write-Host "  adksetup exit $($p.ExitCode)"
    $osc = Find-Oscdimg
    if (-not $osc) { Get-Content $log -Tail 40 -ErrorAction SilentlyContinue; throw 'oscdimg.exe not found after the ADK install' }
}
Assert-MicrosoftSigned $osc
Write-Host "  oscdimg $((Get-Item $osc).VersionInfo.FileVersion)"
if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value "OSCDIMG=$osc" }
