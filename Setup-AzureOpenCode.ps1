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
    [switch] $Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Candidate deployments. Anything not deployed is skipped, so extra entries are
# harmless - add new model ids here as they are deployed.
$AnthropicModels = @("claude-opus-5", "claude-opus-4-8")
$OpenAiModels    = @("gpt-5.6-sol-1", "gpt-5.6-luna-1", "gpt-5.6-terra-1")

# Preferred background model, best first. Titles and summaries use this.
$SmallModelPreference = @("openai/gpt-5.6-luna-1", "openai/gpt-5.6-sol-1", "openai/gpt-5.6-terra-1", "anthropic/claude-opus-4-8")

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

$Endpoint = $Endpoint.TrimEnd("/")

# --------------------------------------------------------------------------
# 3. Probe deployments
# --------------------------------------------------------------------------
function Test-AnthropicModel {
    param($Model)
    $body = @{ model = $Model; max_tokens = 8; messages = @(@{ role = "user"; content = "hi" }) } | ConvertTo-Json -Depth 6
    try {
        Invoke-RestMethod -Method Post -Uri "$Endpoint/anthropic/v1/messages" -Body $body -ContentType "application/json" `
            -Headers @{ "x-api-key" = $ApiKey; "anthropic-version" = "2023-06-01" } -TimeoutSec 60 | Out-Null
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
    $r = Test-AnthropicModel -Model $m
    if ($r.ok) { $deployed.anthropic += $m; Write-Ok "anthropic/$m" }
    elseif ($r.status -eq 401 -or $r.status -eq 403) { Write-Bad "anthropic/$m - auth rejected ($($r.status))"; $authFailed = $true }
    else { Write-Warn "anthropic/$m - not deployed ($($r.status))" }
}
foreach ($m in $OpenAiModels) {
    $r = Test-OpenAiModel -Model $m
    if ($r.ok) { $deployed.openai += $m; Write-Ok "openai/$m" }
    elseif ($r.status -eq 401 -or $r.status -eq 403) { Write-Bad "openai/$m - auth rejected ($($r.status))"; $authFailed = $true }
    else { Write-Warn "openai/$m - not deployed ($($r.status))" }
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
if ($deployed.openai.Count -gt 0) {
    if (-not $cfg.provider.PSObject.Properties['openai']) {
        $cfg.provider | Add-Member -NotePropertyName openai -NotePropertyValue ([PSCustomObject]@{})
    }
    $openai = $cfg.provider.openai
    $openai | Add-Member -NotePropertyName npm -NotePropertyValue "@ai-sdk/openai" -Force
    if (-not $openai.PSObject.Properties['options']) {
        $openai | Add-Member -NotePropertyName options -NotePropertyValue ([PSCustomObject]@{})
    }
    $openai.options | Add-Member -NotePropertyName apiKey -NotePropertyValue $ApiKey -Force
    $openai.options | Add-Member -NotePropertyName baseURL -NotePropertyValue "$Endpoint/openai/v1" -Force
    if (-not $openai.PSObject.Properties['models']) {
        $openai | Add-Member -NotePropertyName models -NotePropertyValue ([PSCustomObject]@{})
    }
    foreach ($m in $deployed.openai) {
        $displayName = switch ($m) {
            "gpt-5.6-sol-1" { "GPT-5.6 Sol" }
            "gpt-5.6-terra-1" { "GPT-5.6 Terra" }
            "gpt-5.6-luna-1" { "GPT-5.6 Luna" }
            default { $m }
        }
        $openai.models | Add-Member -NotePropertyName $m -NotePropertyValue ([PSCustomObject]@{
            name = $displayName
            reasoning = $true
            tool_call = $true
            limit = [PSCustomObject]@{ context = 1050000; output = 128000 }
        }) -Force
    }
    Write-Ok "provider.openai -> $Endpoint/openai/v1"
}

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
