# Shared helpers for the Windows image build (CI runner only). Dot-source this file.
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message"
}

function Get-Sha256([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-PinnedDownload {
    <#
      Downloads $Url to $Dest with curl.exe and checks it against $Sha256 (and $Bytes when given).
      An empty $Sha256 is only accepted with -AllowUnpinned: the hash is printed so it can be pinned,
      and the caller decides what to do. Returns the sha256 of the file.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Dest,
        [string]$Sha256,
        [long]$Bytes = 0,
        [hashtable]$Headers = @{},
        [switch]$AllowUnpinned
    )
    $dir = Split-Path -Parent $Dest
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if ((Test-Path -LiteralPath $Dest) -and $Sha256 -and ((Get-Sha256 $Dest) -eq $Sha256.ToLowerInvariant())) {
        Write-Host "  cached: $Dest"
        return $Sha256.ToLowerInvariant()
    }
    $curlArgs = @('--fail', '--location', '--silent', '--show-error', '--retry', '5', '--retry-delay', '10',
                  '--retry-all-errors', '--connect-timeout', '30', '--user-agent', 'leCore-plus-image-build/1.0',
                  '--output', $Dest)
    foreach ($k in $Headers.Keys) { $curlArgs += @('--header', "${k}: $($Headers[$k])") }
    $curlArgs += $Url
    Write-Host "  GET $Url"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & curl.exe @curlArgs
    if ($LASTEXITCODE -ne 0) { throw "download failed (curl exit $LASTEXITCODE): $Url" }
    $len = (Get-Item -LiteralPath $Dest).Length
    $hash = Get-Sha256 $Dest
    Write-Host ("  {0:N0} bytes in {1:N0}s  sha256={2}" -f $len, $sw.Elapsed.TotalSeconds, $hash)
    if ($Bytes -gt 0 -and $len -ne $Bytes) {
        throw "size mismatch for ${Url}: expected $Bytes bytes, got $len"
    }
    if ($Sha256) {
        if ($hash -ne $Sha256.ToLowerInvariant()) {
            throw "sha256 mismatch for ${Url}: expected $Sha256, got $hash"
        }
    } elseif ($AllowUnpinned) {
        Write-Warning "UNPINNED download $Url -> sha256 $hash (pin this value)"
    } else {
        throw "no sha256 pinned for $Url (downloaded file hashes to $hash)"
    }
    return $hash
}

function Invoke-Native {
    # Runs a native command, echoes it, throws on a non-zero exit code (unless listed in -OkCodes).
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [int[]]$OkCodes = @(0))
    Write-Host "  > $FilePath $($ArgumentList -join ' ')"
    & $FilePath @ArgumentList
    $code = $LASTEXITCODE
    if ($OkCodes -notcontains $code) { throw "$FilePath exited with $code" }
    return $code
}

function Get-SevenZip {
    foreach ($c in @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe")) {
        if (Test-Path -LiteralPath $c) { return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw '7-Zip (7z.exe) not found'
}

function Write-Summary([string]$Markdown) {
    # Appends to the GitHub Actions job summary when running in Actions.
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $Markdown -Encoding utf8 }
}

function Show-Disk([string]$Label = 'disk') {
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -ne $null } | ForEach-Object {
        Write-Host ("  [{0}] {1}: used {2:N1} GB, free {3:N1} GB" -f $Label, $_.Name, ($_.Used / 1GB), ($_.Free / 1GB))
    }
}
