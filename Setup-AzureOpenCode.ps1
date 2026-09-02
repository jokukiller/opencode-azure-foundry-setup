<#
.SYNOPSIS
    Points OpenCode at an Azure AI Foundry resource so its Claude and GPT
    deployments work as native models.

.DESCRIPTION
    An Azure AI Foundry resource exposes TWO different API surfaces on the same
    hostname and the same key:

      /anthropic/v1   Anthropic Messages API   (x-api-key)
      /openai/v1      OpenAI-compatible v1     (Authorization: Bearer)

    OpenCode has native providers for both, but its built-in `azure` provider
    speaks the OLDER classic protocol (/openai/deployments/<name>/...?api-version=)
    which this resource does not use. Pointing `azure` at it fails even with a
    valid key. The fix is to override the built-in `anthropic` and `openai`
    providers' baseURL instead.

    This script validates the key against both surfaces, discovers which models
    are actually deployed, then writes the config. It backs up any existing
    config first and never writes anything if validation fails.

.PARAMETER ApiKey
    Azure resource key. Prompted for securely if omitted.

.PARAMETER Endpoint
    Resource base URL, no trailing slash.

.PARAMETER Force
    Overwrite existing anthropic/openai provider entries without confirming.

.EXAMPLE
    .\Setup-AzureOpenCode.ps1

.EXAMPLE
    .\Setup-AzureOpenCode.ps1 -ApiKey "abc123..." -Force
#>
[CmdletBinding()]
param(
    [string] $ApiKey,
    [string] $Endpoint = "https://crosssans0786-3936-resource.services.ai.azure.com",
    [string] $AnthropicEndpoint,
    [string] $AnthropicApiKey,
    [string] $AnthropicModel = "claude-opus-4-8",
    [switch] $Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Candidate deployments. Anything not deployed is skipped, so extra entries are
# harmless - add new model ids here as they are deployed.
$AnthropicModels = @("claude-opus-5", "claude-opus-4-8")
$OpenAiModels = [ordered]@{
    "gpt-5.6-sol"   = "gpt-5.6-sol-1"
    "gpt-5.6-luna"  = "gpt-5.6-luna-1"
    "gpt-5.6-terra" = "gpt-5.6-terra-1"
}

# Preferred background model, best first. Titles and summaries use this.
$SmallModelPreference = @("openai/gpt-5.6-luna", "openai/gpt-5.6-sol", "openai/gpt-5.6-terra", "anthropic/claude-opus-4-8")

function Write-Step { param($m) Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Bad  { param($m) Write-Host "  [fail] $m" -ForegroundColor Red }

# --------------------------------------------------------------------------
# 1. Preflight
# --------------------------------------------------------------------------
Write-Step "Checking OpenCode"

$openCodeCmd = Get-Command opencode -ErrorAction SilentlyContinue
$desktopExe  = Join-Path $env:LOCALAPPDATA "Programs\@opencode-aidesktop\OpenCode.exe"
$foundAny    = $false

if ($openCodeCmd) {
    $pkg = Join-Path (Split-Path $openCodeCmd.Source -Parent) "node_modules\opencode-ai\package.json"
    $cliVer = if (Test-Path $pkg) { (Get-Content $pkg -Raw | ConvertFrom-Json).version } else { "unknown" }
    Write-Ok "CLI $cliVer"
    $foundAny = $true
}
if (Test-Path $desktopExe) {
    Write-Ok "Desktop app $((Get-Item $desktopExe).VersionInfo.ProductVersion)"
    $foundAny = $true
}
if (-not $foundAny) {
    Write-Bad "OpenCode not found. Install it first: https://opencode.ai"
    exit 1
}

Write-Warn "The desktop app and the CLI update independently. If one behaves"
Write-Warn "differently from the other, check both versions before debugging."

# --------------------------------------------------------------------------
# 2. Key
# --------------------------------------------------------------------------
if (-not $ApiKey) {
    $secure = Read-Host -Prompt "`nAzure resource key" -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { $ApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) { Write-Bad "No key supplied."; exit 1 }

if ($AnthropicApiKey -and -not $AnthropicEndpoint) {
    Write-Bad "AnthropicApiKey requires AnthropicEndpoint."
    exit 1
}
if ($AnthropicEndpoint) {
    $AnthropicEndpoint = $AnthropicEndpoint.TrimEnd("/")
    if (-not $AnthropicApiKey) {
        $secure = Read-Host -Prompt "`nSeparate Anthropic resource key" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { $AnthropicApiKey = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    if ([string]::IsNullOrWhiteSpace($AnthropicApiKey)) {
        Write-Bad "No separate Anthropic key supplied."
        exit 1
    }
}

$Endpoint = $Endpoint.TrimEnd("/")

# --------------------------------------------------------------------------
# 3. Probe deployments
# --------------------------------------------------------------------------
function Test-AnthropicModel {
    param($Model, $TargetEndpoint, $TargetApiKey)
    $body = @{ model = $Model; max_tokens = 8; messages = @(@{ role = "user"; content = "hi" }) } | ConvertTo-Json -Depth 6
    try {
        Invoke-RestMethod -Method Post -Uri "$TargetEndpoint/anthropic/v1/messages" -Body $body -ContentType "application/json" `
            -Headers @{ "x-api-key" = $TargetApiKey; "anthropic-version" = "2023-06-01" } -TimeoutSec 60 | Out-Null
        return @{ ok = $true }
    } catch {
        return @{ ok = $false; status = $_.Exception.Response.StatusCode.value__ }
    }
}

function Test-OpenAiModel {
    param($Model)
    # Test the same API that OpenCode's native `openai` provider uses for GPT-5
    # models. A successful Chat Completions request alone does not prove that
    # reasoning, cache, and tool workflows through the Responses API will work.
    $body = @{ model = $Model; max_output_tokens = 16; input = "hi" } | ConvertTo-Json -Depth 6
    try {
        Invoke-RestMethod -Method Post -Uri "$Endpoint/openai/v1/responses" -Body $body -ContentType "application/json" `
            -Headers @{ "Authorization" = "Bearer $ApiKey" } -TimeoutSec 60 | Out-Null
        return @{ ok = $true }
    } catch {
        return @{ ok = $false; status = $_.Exception.Response.StatusCode.value__ }
    }
}

Write-Step "Probing deployments at $Endpoint"

$deployed = @{ anthropic = @(); openai = @() }
$authFailed = $false

foreach ($m in $AnthropicModels) {
    $r = Test-AnthropicModel -Model $m -TargetEndpoint $Endpoint -TargetApiKey $ApiKey
    if ($r.ok) { $deployed.anthropic += $m; Write-Ok "anthropic/$m" }
    elseif ($r.status -eq 401 -or $r.status -eq 403) { Write-Bad "anthropic/$m - auth rejected ($($r.status))"; $authFailed = $true }
    else { Write-Warn "anthropic/$m - not deployed ($($r.status))" }
}
foreach ($m in $OpenAiModels.Keys) {
    $deployment = $OpenAiModels[$m]
    $r = Test-OpenAiModel -Model $deployment
    if ($r.ok) { $deployed.openai += $m; Write-Ok "openai/$m -> $deployment" }
    elseif ($r.status -eq 401 -or $r.status -eq 403) { Write-Bad "openai/$m - auth rejected ($($r.status))"; $authFailed = $true }
    else { Write-Warn "openai/$m - deployment $deployment unavailable ($($r.status))" }
}

if ($deployed.openai.Count -eq 0) {
    if ($authFailed) {
        Write-Bad "`nNo GPT deployment probe succeeded; authentication was rejected. Nothing was written. Check the key and endpoint."
    } else {
        Write-Bad "`nNo GPT deployment probe succeeded. Nothing was written."
    }
    exit 1
}

# --------------------------------------------------------------------------
# 4. Merge into config
# --------------------------------------------------------------------------
Write-Step "Writing config"

$cfgDir = Join-Path $env:USERPROFILE ".config\opencode"
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }

# OpenCode reads either name; prefer whichever already exists.
$jsonc = Join-Path $cfgDir "opencode.jsonc"
$json  = Join-Path $cfgDir "opencode.json"
$cfgPath = if (Test-Path $jsonc) { $jsonc } elseif (Test-Path $json) { $json } else { $json }

$cfg = [PSCustomObject]@{ '$schema' = "https://opencode.ai/config.json" }
if (Test-Path $cfgPath) {
    $backup = "$cfgPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $cfgPath $backup -Force
    Write-Ok "Backed up existing config to $(Split-Path $backup -Leaf)"

    # Strip whole-line // comments so JSONC parses. URLs are mid-line, so they
    # are never touched by this.
    $raw = (Get-Content $cfgPath -Raw) -replace '(?m)^\s*//.*$', ''
    try {
        $cfg = $raw | ConvertFrom-Json
        if ($cfgPath -eq $jsonc) { Write-Warn "Comments in opencode.jsonc are dropped on rewrite (backup retains them)." }
    } catch {
        Write-Bad "Existing config is not valid JSON. Fix or remove it first: $cfgPath"
        exit 1
    }

    $existing = @()
    if ($cfg.PSObject.Properties['provider']) {
        foreach ($p in @('anthropic','openai')) {
            if ($cfg.provider.PSObject.Properties[$p]) { $existing += $p }
        }
    }
    if ($existing.Count -gt 0 -and -not $Force) {
        Write-Warn "Config already defines provider(s): $($existing -join ', ')"
        if ((Read-Host "Overwrite them? (y/N)") -notmatch '^[Yy]') {
            Write-Bad "Aborted. Config unchanged (backup left in place)."
            exit 1
        }
    }
}

if (-not $cfg.PSObject.Properties['provider']) {
    $cfg | Add-Member -NotePropertyName provider -NotePropertyValue ([PSCustomObject]@{}) -Force
}

if ($deployed.anthropic.Count -gt 0) {
    $cfg.provider | Add-Member -NotePropertyName anthropic -NotePropertyValue ([PSCustomObject]@{
        options = [PSCustomObject]@{ apiKey = $ApiKey; baseURL = "$Endpoint/anthropic/v1" }
    }) -Force
    Write-Ok "provider.anthropic -> $Endpoint/anthropic/v1"
} else {
    Write-Warn "No Anthropic deployment found; GPT setup will continue."
}
if ($separateAnthropicDeployed) {
    if (-not $cfg.provider.PSObject.Properties['anthropic-2']) {
        $cfg.provider | Add-Member -NotePropertyName 'anthropic-2' -NotePropertyValue ([PSCustomObject]@{})
    }
    $anthropic2 = $cfg.provider.'anthropic-2'
    $anthropic2 | Add-Member -NotePropertyName name -NotePropertyValue 'anthropic (region 2)' -Force
    $anthropic2 | Add-Member -NotePropertyName npm -NotePropertyValue '@ai-sdk/anthropic' -Force
    $anthropic2 | Add-Member -NotePropertyName options -NotePropertyValue ([PSCustomObject]@{}) -Force
    $anthropic2.options | Add-Member -NotePropertyName apiKey -NotePropertyValue $AnthropicApiKey -Force
    $anthropic2.options | Add-Member -NotePropertyName baseURL -NotePropertyValue "$AnthropicEndpoint/anthropic/v1" -Force
    $anthropic2 | Add-Member -NotePropertyName models -NotePropertyValue ([PSCustomObject]@{}) -Force
    $anthropic2.models | Add-Member -NotePropertyName $AnthropicModel -NotePropertyValue ([PSCustomObject]@{
        name = "$AnthropicModel #2"
    }) -Force
    Write-Ok "provider.anthropic-2 -> $AnthropicEndpoint/anthropic/v1"
}
if ($deployed.openai.Count -gt 0) {
    if (-not $cfg.provider.PSObject.Properties['openai']) {
        $cfg.provider | Add-Member -NotePropertyName openai -NotePropertyValue ([PSCustomObject]@{})
    }
    $openai = $cfg.provider.openai
    if (-not $openai.PSObject.Properties['options']) {
        $openai | Add-Member -NotePropertyName options -NotePropertyValue ([PSCustomObject]@{})
    }
    $openai.options | Add-Member -NotePropertyName apiKey -NotePropertyValue $ApiKey -Force
    $openai.options | Add-Member -NotePropertyName baseURL -NotePropertyValue "$Endpoint/openai/v1" -Force
    # Remove entries created by versions of this script that exposed deployment
    # names as custom models. Canonical native models keep models.dev metadata.
    if ($openai.PSObject.Properties['models']) {
        foreach ($deployment in $OpenAiModels.Values) {
            $openai.models.PSObject.Properties.Remove($deployment)
        }
        if ($openai.models.PSObject.Properties.Count -eq 0) {
            $openai.PSObject.Properties.Remove('models')
        }
    }
    Write-Ok "provider.openai -> $Endpoint/openai/v1"
}

$separateAnthropicDeployed = $false
if ($AnthropicEndpoint) {
    $r = Test-AnthropicModel -Model $AnthropicModel -TargetEndpoint $AnthropicEndpoint -TargetApiKey $AnthropicApiKey
    if ($r.ok) {
        $separateAnthropicDeployed = $true
        Write-Ok "anthropic-2/$AnthropicModel -> $AnthropicEndpoint/anthropic/v1"
    } elseif ($r.status -eq 401 -or $r.status -eq 403) {
        Write-Warn "anthropic-2/$AnthropicModel - authentication rejected ($($r.status)); provider not written"
    } else {
        Write-Warn "anthropic-2/$AnthropicModel - deployment unavailable ($($r.status)); provider not written"
    }
}

# Keep canonical OpenAI model ids in the picker while translating them to Azure
# deployment names only on the wire. This preserves native metadata and variants.
$extDir = Join-Path $cfgDir "ext"
if (-not (Test-Path $extDir)) { New-Item -ItemType Directory -Path $extDir -Force | Out-Null }
$mapSource = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "openai-deployment-map.ts"
$mapTarget = Join-Path $extDir "openai-deployment-map.ts"
Copy-Item $mapSource $mapTarget -Force
$mapUri = ([Uri]$mapTarget).AbsoluteUri
$plugins = if ($cfg.PSObject.Properties['plugin']) { @($cfg.plugin) } else { @() }
if ($plugins -notcontains $mapUri) { $plugins += $mapUri }
$cfg | Add-Member -NotePropertyName plugin -NotePropertyValue $plugins -Force
Write-Ok "Installed native OpenAI deployment mapper"

# small_model MUST be set. Overriding the built-in anthropic provider makes
# OpenCode inherit Anthropic's default small model (claude-haiku-4-5), which is
# not deployed here - every session title then 404s silently and you get no
# error anywhere, just sessions that never get titles.
$allDeployed = @($deployed.anthropic | ForEach-Object { "anthropic/$_" }) + @($deployed.openai | ForEach-Object { "openai/$_" })
$small = $SmallModelPreference | Where-Object { $allDeployed -contains $_ } | Select-Object -First 1
if (-not $small) { $small = $allDeployed[0] }
$cfg | Add-Member -NotePropertyName small_model -NotePropertyValue $small -Force
Write-Ok "small_model -> $small"

if (-not $cfg.PSObject.Properties['model']) {
    $default = if ($allDeployed -contains "anthropic/claude-opus-5") { "anthropic/claude-opus-5" } else { $allDeployed[0] }
    $cfg | Add-Member -NotePropertyName model -NotePropertyValue $default -Force
    Write-Ok "model -> $default"
} else {
    Write-Warn "Existing 'model' left as-is: $($cfg.model)"
}

$cfg | ConvertTo-Json -Depth 12 | Set-Content -Path $cfgPath -Encoding UTF8
Write-Ok "Wrote $cfgPath"

# --------------------------------------------------------------------------
# 5. Summary
# --------------------------------------------------------------------------
Write-Step "Done"
Write-Host "  Available models:" -ForegroundColor White
$allDeployed | ForEach-Object { Write-Host "    $_" }

Write-Host @"

  Restart OpenCode fully before use. Config is read once at startup, and the
  desktop keeps background processes alive, so closing the window is not enough:

      Get-Process opencode, OpenCode -ErrorAction SilentlyContinue | Stop-Process -Force

  Notes:
   - The picker will also list models this resource does NOT serve. Selecting
     one returns a 404. Only the models listed above exist.
   - If reasoning traces do not appear on Claude models, update OpenCode.
     Versions <= 1.18.4 fail to request visible thinking for model ids without
     a minor version (e.g. claude-opus-5). Fixed in 1.18.5.
   - Writing curl by hand against /openai/v1? Use max_completion_tokens, not
     max_tokens. Azure's own sample is stale and these models reject max_tokens.
"@ -ForegroundColor Gray
