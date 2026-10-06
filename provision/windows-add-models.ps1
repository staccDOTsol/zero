<#
.SYNOPSIS
  Adds models to a Zero (leCore+) Windows laptop or disk image AT IMAGING TIME. Runs on the imaging
  station, never on the laptop (the laptop has zero egress).

.DESCRIPTION
  Reads models/catalog.json (schema: models[].id, models[].builds.<tier> = null | { repo, files[] },
  files[].path / .bytes / .sha256, models[].default_for[]), downloads each file from
      https://huggingface.co/<repo>/resolve/main/<path>
  into a cache on the imaging station, checks bytes + sha256, copies it into
      <Target>\ProgramData\leCore+\models\<file name>
  checks the copy's sha256 again, and writes <Target>\ProgramData\leCore+\model.txt (one line: the
  default model's first file name). llama-server loads the other parts of a split GGUF from the same
  folder.

  Two ways to choose models:
    -All <tier>                every model whose builds.<tier> is not null (the golden-image flow:
                               run once per tier, then capture/clone the image).
    -Models <id>,<id> -Tier t  just these models (the order page's checkboxes).
  model.txt names -Default <id> if given; otherwise the model whose default_for includes the tier;
  otherwise (with -Models) the first id.

.PARAMETER Target
  Root of the target Windows volume: a drive letter of the laptop's Windows partition attached to the
  imaging station or of an applied/mounted image (e.g. W:), or C: when running on the laptop itself
  during imaging. Default C:.
.PARAMETER Cache
  Download cache on the imaging station (reused across laptops). Default <Target>\ProgramData\leCore+\models\.download
  (no second copy needed when imaging a single machine).
.PARAMETER HfToken
  Optional Hugging Face token for gated repos (or set HF_TOKEN).

.EXAMPLE
  .\provision\windows-add-models.ps1 -All pro -Target W: -Cache D:\zero-model-cache
.EXAMPLE
  .\provision\windows-add-models.ps1 -Models qwen3.8-27b,gpt-oss-20b -Tier ultra -Target W:
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(ParameterSetName = 'All', Mandatory = $true)][string]$All,
    [Parameter(ParameterSetName = 'Ids', Mandatory = $true)][string[]]$Models,
    [Parameter(ParameterSetName = 'Ids', Mandatory = $true)][string]$Tier,
    [string]$Default,
    [string]$Catalog = (Join-Path (Split-Path -Parent $PSScriptRoot) 'models\catalog.json'),
    [string]$Target = 'C:',
    [string]$Cache,
    [string]$HfToken = $env:HF_TOKEN,
    [switch]$SkipCopyVerify,
    [switch]$DryRun
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Say([string]$m) { Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }
function Get-Sha256([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-Prop($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $p = $obj.PSObject.Properties[$name]
    if ($p) { return $p.Value } else { return $null }
}

if ($PSCmdlet.ParameterSetName -eq 'All') { $Tier = $All }
$Tier = $Tier.ToLowerInvariant()
$Target = $Target.TrimEnd('\')
if ($Target -match '^[A-Za-z]$') { $Target += ':' }
# String paths (Join-Path refuses a drive that is not attached yet, e.g. for -DryRun)
$dataDir = "$Target\ProgramData\leCore+"
$modelsDir = "$dataDir\models"
$defaultCache = -not $Cache
if ($defaultCache) { $Cache = "$modelsDir\.download" }

Say "catalog $Catalog"
$cat = Get-Content -Raw -LiteralPath $Catalog | ConvertFrom-Json
$byId = @{}
foreach ($m in $cat.models) { $byId[$m.id] = $m }

# ---- choose models -------------------------------------------------------------------------------
$chosen = @()
if ($PSCmdlet.ParameterSetName -eq 'All') {
    foreach ($m in $cat.models) { if ($null -ne (Get-Prop $m.builds $Tier)) { $chosen += $m } }
    if (-not $chosen) { throw "no model in the catalog has a build for tier '$Tier'" }
} else {
    foreach ($id in ($Models | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if (-not $byId.ContainsKey($id)) { throw "unknown model id '$id' (not in $Catalog)" }
        if ($null -eq (Get-Prop $byId[$id].builds $Tier)) { throw "model '$id' has no build for tier '$Tier' (it does not fit)" }
        $chosen += $byId[$id]
    }
}
if ($Default) {
    if (-not ($chosen | Where-Object { $_.id -eq $Default })) { throw "-Default '$Default' is not among the models being installed" }
    $defaultModel = $chosen | Where-Object { $_.id -eq $Default } | Select-Object -First 1
} else {
    $defaultModel = $chosen | Where-Object { @(Get-Prop $_ 'default_for') -contains $Tier } | Select-Object -First 1
    if (-not $defaultModel) { $defaultModel = $chosen[0] }
}

# ---- plan ----------------------------------------------------------------------------------------
$plan = @()
$seen = @{}
foreach ($m in $chosen) {
    $b = Get-Prop $m.builds $Tier
    foreach ($f in $b.files) {
        $leaf = ($f.path -split '/')[-1]
        if ($seen.ContainsKey($leaf)) {
            if ($seen[$leaf] -ne $f.sha256) { throw "file name collision in models dir: $leaf (from $($m.id))" }
            continue
        }
        $seen[$leaf] = $f.sha256
        $plan += [pscustomobject]@{ Id = $m.id; Repo = $b.repo; Path = $f.path; Leaf = $leaf; Bytes = [long]$f.bytes; Sha256 = $f.sha256.ToLowerInvariant() }
    }
}
$total = ($plan | Measure-Object -Property Bytes -Sum).Sum
Say ("tier {0}: {1} model(s), {2} file(s), {3:N1} GB -> {4}" -f $Tier, $chosen.Count, $plan.Count, ($total / 1e9), $modelsDir)
foreach ($m in $chosen) { Say "  - $($m.id)$(if ($m.id -eq $defaultModel.id) { '   (default -> model.txt)' })" }
$firstOfDefault = $plan | Where-Object { $_.Id -eq $defaultModel.id } | Sort-Object { if ($_.Leaf -match '-00001-of-\d+\.gguf$') { 0 } else { 1 } } | Select-Object -First 1
if ($DryRun) { Say "dry run: model.txt would be '$($firstOfDefault.Leaf)'"; return }

New-Item -ItemType Directory -Force -Path $modelsDir, $Cache | Out-Null
$need = ($plan | Where-Object { -not ((Test-Path -LiteralPath (Join-Path $modelsDir $_.Leaf)) -and (Get-Item -LiteralPath (Join-Path $modelsDir $_.Leaf)).Length -eq $_.Bytes) } | Measure-Object -Property Bytes -Sum).Sum
$drive = Get-PSDrive -Name ($modelsDir.Substring(0, 1)) -ErrorAction SilentlyContinue
if ($drive -and $need -and $drive.Free -lt $need) { throw ("target needs {0:N1} GB more, has {1:N1} GB free" -f ($need / 1e9), ($drive.Free / 1e9)) }

# ---- download, verify, copy ----------------------------------------------------------------------
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
foreach ($f in $plan) {
    $dest = Join-Path $modelsDir $f.Leaf
    if ((Test-Path -LiteralPath $dest) -and (Get-Item -LiteralPath $dest).Length -eq $f.Bytes -and (Get-Sha256 $dest) -eq $f.Sha256) {
        Say "ok (already present): $($f.Leaf)"; continue
    }
    $cached = Join-Path $Cache $f.Leaf
    $verified = "$cached.sha256-ok"
    if (-not ((Test-Path -LiteralPath $cached) -and (Test-Path -LiteralPath $verified) -and (Get-Item -LiteralPath $cached).Length -eq $f.Bytes)) {
        $url = "https://huggingface.co/$($f.Repo)/resolve/main/$($f.Path)"
        Say ("download {0} ({1:N1} GB)" -f $url, ($f.Bytes / 1e9))
        $a = @('--fail', '--location', '--retry', '20', '--retry-delay', '15', '--retry-all-errors', '--continue-at', '-',
               '--speed-limit', '1024', '--speed-time', '120', '--output', $cached)
        if ($HfToken) { $a += @('--header', "Authorization: Bearer $HfToken") }
        $a += $url
        & $curl @a
        if ($LASTEXITCODE -ne 0) { throw "download failed (curl $LASTEXITCODE): $url" }
        $len = (Get-Item -LiteralPath $cached).Length
        if ($len -ne $f.Bytes) { Remove-Item -Force $cached; throw "size mismatch $($f.Leaf): expected $($f.Bytes), got $len" }
        $h = Get-Sha256 $cached
        if ($h -ne $f.Sha256) { Remove-Item -Force $cached; throw "sha256 mismatch $($f.Leaf): expected $($f.Sha256), got $h" }
        Set-Content -LiteralPath $verified -Value $h -Encoding ascii
        Say "verified sha256 $h"
    } else {
        Say "cache hit (verified earlier): $($f.Leaf)"
    }
    if ($defaultCache) {
        # cache lives on the target volume: a rename, no second copy
        Move-Item -LiteralPath $cached -Destination $dest -Force
        Remove-Item -LiteralPath $verified -Force
        Say "installed $dest"
        continue
    }
    $tmp = "$dest.partial"
    Copy-Item -LiteralPath $cached -Destination $tmp -Force
    if (-not $SkipCopyVerify) {
        $h2 = Get-Sha256 $tmp
        if ($h2 -ne $f.Sha256) { Remove-Item -Force $tmp; throw "copy of $($f.Leaf) is corrupt (sha256 $h2)" }
    }
    Move-Item -LiteralPath $tmp -Destination $dest -Force
    Say "installed $dest"
}
if ($defaultCache -and (Test-Path -LiteralPath $Cache) -and -not (Get-ChildItem -LiteralPath $Cache -Force | Select-Object -First 1)) {
    Remove-Item -LiteralPath $Cache -Force
}

[IO.File]::WriteAllText((Join-Path $dataDir 'model.txt'), $firstOfDefault.Leaf + "`r`n", (New-Object Text.UTF8Encoding($false)))
$inventory = [ordered]@{
    tier = $Tier; default = $defaultModel.id; model_txt = $firstOfDefault.Leaf
    written_utc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    catalog_updated = (Get-Prop $cat 'updated')
    models = @($chosen | ForEach-Object { $_.id })
    files = @($plan | ForEach-Object { [ordered]@{ id = $_.Id; file = $_.Leaf; bytes = $_.Bytes; sha256 = $_.Sha256 } })
}
[IO.File]::WriteAllText((Join-Path $dataDir 'models.json'), ($inventory | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Say "model.txt -> $($firstOfDefault.Leaf)   (inventory: $(Join-Path $dataDir 'models.json'))"
