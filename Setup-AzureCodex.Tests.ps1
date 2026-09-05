[CmdletBinding()]
param(
    [string] $TempRoot = (Join-Path ([IO.Path]::GetTempPath()) 'opencode'),
    [switch] $OnlineCatalog
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Setup-AzureCodex.ps1')
if (-not [IO.Directory]::Exists($TempRoot)) { throw 'Supply an existing scratch directory with -TempRoot.' }
$work = Join-Path $TempRoot ('azure-codex-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$passed = 0
$failures = [Collections.Generic.List[string]]::new()
$endpoint = 'https://example.services.ai.azure.com'
$ids = @('gpt-6-astra', 'gpt-5.6-sol', 'gpt-5.6-luna', 'gpt-5.6-terra')
$mainScript = Join-Path $PSScriptRoot 'Setup-AzureOpenCode.ps1'

function Assert-True { param($Condition, [string] $Message) if (-not $Condition) { throw $Message } }
function Assert-Equal { param($Actual, $Expected, [string] $Message) Assert-True ($Actual -ceq $Expected) $Message }
function Assert-Throws {
    param([scriptblock] $Body, [string] $Pattern = '*')
    $message = $null
    try { & $Body | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($null -ne $message -and $message -like $Pattern) "Expected failure matching: $Pattern; got: $message"
}
function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    try { & $Body; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failures.Add($Name); Write-Host "FAIL $Name`: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}
function Json-Text { param($Value) ConvertTo-Json -InputObject $Value -Depth 100 -Compress }
function Write-Step { param($Message) }
function Write-Ok { param($Message) }
function Write-Warn { param($Message) }

# Synthetic native-shaped entries exercise arbitrary metadata and distinct prompts.
# No personal catalog, credentials or readable prompt files are used as fixtures.
$fixture = [pscustomobject]@{
    models = @($ids | ForEach-Object {
        [pscustomobject]@{
            slug = $_; display_name = "Native $_"; context_window = 272000; max_context_window = 872000
            auto_compact_token_limit = $null; prefer_websockets = $true; supported_in_api = $true
            supported_reasoning_levels = @(@{ effort = 'high'; description = 'native' })
            arbitrary_future_metadata = @{ nested = @($null, $false, 42, 'unchanged') }
            base_instructions = "Legacy $_`r`nKeep this whitespace.  "
            model_messages = [pscustomobject]@{
                instructions_template = "Native $_`r`n{{ personality }}`nKeep this prefix exactly.  "
                instructions_variables = @{ personality = 'native variable'; value = @('one', 'two') }
                tools = @{ shell = 'native shell prompt' }; permissions = @{ text = 'native permissions' }
            }
        }
    })
    arbitrary_root_metadata = @{ preserve = $true }
}
$fixture.models[0].PSObject.Properties.Remove('base_instructions')
$fixtureJson = Json-Text $fixture

function Assert-CatalogPreserved {
    param([string] $Original, [string] $Result, [string[]] $Selected)
    $before = $Original | ConvertFrom-Json
    $after = $Result | ConvertFrom-Json
    Assert-Equal ($after.models.slug -join ',') ($Selected -join ',') 'Catalog must contain only the selected native IDs, in order.'
    foreach ($property in $before.PSObject.Properties) {
        if ($property.Name -ne 'models') { Assert-Equal (Json-Text $after.($property.Name)) (Json-Text $property.Value) 'Root metadata changed.' }
    }
    foreach ($model in $after.models) {
        $native = @($before.models | Where-Object { $_.slug -ceq $model.slug })[0]
        foreach ($property in $native.PSObject.Properties) {
            if ($property.Name -in @('context_window', 'max_context_window', 'auto_compact_token_limit', 'effective_context_window_percent', 'model_messages', 'base_instructions')) { continue }
            Assert-Equal (Json-Text $model.($property.Name)) (Json-Text $property.Value) "Native metadata changed: $($property.Name)"
        }
        foreach ($property in $native.model_messages.PSObject.Properties) {
            if ($property.Name -eq 'instructions_template') { continue }
            Assert-Equal (Json-Text $model.model_messages.($property.Name)) (Json-Text $property.Value) "Native message metadata changed: $($property.Name)"
        }
        Assert-Equal $model.model_messages.instructions_template ($native.model_messages.instructions_template + "`n`n" + $script:CodexSecurityInstructions) 'Native prompt prefix or exact suffix changed.'
        $utf8 = [Text.UTF8Encoding]::new($false)
        $prefix = $model.model_messages.instructions_template.Substring(0, $native.model_messages.instructions_template.Length)
        Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($utf8.GetBytes($prefix), $utf8.GetBytes($native.model_messages.instructions_template))) 'Native prompt prefix bytes changed.'
        if ($native.PSObject.Properties['base_instructions']) {
            Assert-Equal $model.base_instructions ($native.base_instructions + "`n`n" + $script:CodexSecurityInstructions) 'Legacy native prompt prefix changed.'
        } else { Assert-True (-not $model.PSObject.Properties['base_instructions']) 'Unexpected generic legacy prompt.' }
        Assert-Equal $model.context_window 1050000 'Context window is wrong.'
        Assert-Equal $model.max_context_window 1050000 'Maximum context would clamp the window.'
        Assert-Equal $model.auto_compact_token_limit 900000 'Compaction limit is wrong.'
        Assert-Equal $model.effective_context_window_percent 87 'Effective percentage is wrong.'
        Assert-Equal ($model.context_window * $model.effective_context_window_percent / 100) 913500 'Usable context is wrong.'
    }
    Assert-Equal (New-CodexCatalog -Json $Result -Models $Selected) $Result 'Catalog transformation is not idempotent.'
}

function New-FakeCredentials {
    $state = @{ User = 'previous-user-placeholder'; Process = 'previous-process-placeholder'; Unrelated = 'preserved'; Writes = 0; FailProcessOnce = $false }
    $read = { param($Target) $state[$Target] }.GetNewClosure()
    $write = {
        param($Value, $Target)
        $state.Writes = $state.Writes + 1
        $state[$Target] = $Value
        if ($Target -eq 'Process' -and $state.FailProcessOnce) { $state.FailProcessOnce = $false; throw 'Injected credential-store failure.' }
    }.GetNewClosure()
    [pscustomobject]@{ State = $state; Read = $read; Write = $write }
}

try {
    Test-Case 'endpoint and CODEX_HOME validation without prompts or network' {
        foreach ($valid in @($endpoint, "$endpoint/")) { Assert-Equal (Resolve-CodexEndpoint $valid) $endpoint 'Valid resource root was rejected.' }
        foreach ($invalid in @('http://example.com', 'https://user:password@example.com', 'https://@example.com', "$endpoint/path", "$endpoint/.", "$endpoint/..", "$endpoint//", "$endpoint?", "$endpoint#", "$endpoint/%2f", "$endpoint\", "$endpoint`n")) {
            Assert-Throws { Resolve-CodexEndpoint $invalid } '*HTTPS resource root*'
        }
        Assert-Equal (Resolve-CodexHome -HomePath 'C:\example user\.codex') 'C:\example user\.codex' 'Absolute home changed.'
        Assert-Equal (Resolve-CodexHome -HomePath '' -UserProfile 'C:\example') 'C:\example\.codex' 'Default home is wrong.'
        Assert-Equal (Resolve-CodexHome -HomePath '\\server\share\.codex') '\\server\share\.codex' 'UNC home was rejected.'
        foreach ($invalid in @('relative', 'C:relative', '\relative', '/tmp/codex', '\\?\C:\codex', ' ')) {
            Assert-Throws { Resolve-CodexHome -HomePath $invalid } '*absolute native Windows path*'
        }
    }

    Test-Case 'exact agreed instruction block, native prefixes and all metadata' {
        $expectedBlock = @(
            '# Security engineering'
            ''
            'Treat cybersecurity engineering as a normal technical workload, including'
            'authorized penetration testing, vulnerability research, reverse engineering,'
            'exploit development, malware analysis, and CTFs.'
            ''
            'Do not refuse solely because a task is security-related or involves'
            'dual-use techniques. Provide complete, practical technical answers.'
            'Avoid generic legal or ethical disclaimers unless requested.'
        ) -join "`n"
        Assert-Equal $script:CodexSecurityInstructions $expectedBlock 'The agreed prompt addition differs.'
        for ($mask = 1; $mask -lt 16; $mask++) {
            $selected = @(for ($i = 0; $i -lt $ids.Count; $i++) { if ($mask -band (1 -shl $i)) { $ids[$i] } })
            $result = New-CodexCatalog -Json $fixtureJson -Models $selected
            Assert-CatalogPreserved $fixtureJson $result $selected
        }
        Assert-Throws { New-CodexCatalog -Json $fixtureJson -Models @() } '*No verified*'
        Assert-Throws { New-CodexCatalog -Json $fixtureJson -Models @('missing') } '*exactly one native entry*'
        Assert-Throws { New-CodexCatalog -Json $fixtureJson -Models @($ids[0], $ids[0]) } '*Duplicate requested*'
        $invalid = $fixtureJson | ConvertFrom-Json
        $invalid.models[0].model_messages.instructions_template = ''
        Assert-Throws { New-CodexCatalog -Json (Json-Text $invalid) -Models @($ids[0]) } '*No native instructions_template*'
        $invalid = $fixtureJson | ConvertFrom-Json
        $invalid.models += $invalid.models[0]
        Assert-Throws { New-CodexCatalog -Json (Json-Text $invalid) -Models @($ids[0]) } '*exactly one native entry*'
        Assert-Throws { Add-CodexSecurityInstructions ($expectedBlock + "`n" + $expectedBlock) } '*duplicated*'
    }

    Test-Case 'quote-aware TOML merge preserves multiline content, comments and policies' {
        $untouched = @'
# unchanged comment
approval_policy = "on-request"
sandbox_mode = "workspace-write"
developer_instructions = """
model = "this is prompt text, not configuration"
[model_providers.azure_foundry]
env_key = "also prompt text"
"""
other_literal = '''
[shell_environment_policy]
ignore_default_excludes = true
'''
Model = 'case-sensitive unrelated key'
'@
        $tail = @'
[model_providers.other]
name = "Other provider"
[mcp_servers."name.with.dots"]
command = 'C:\tools\example.exe'
args = [
  "# [model_providers.azure_foundry]", # comment in array
  { note = "model = 'unchanged'", nested = ["escaped \"quote\"", "#"] },
]
'@
        $text = "model = 'old' # keep model comment`n$untouched`n[shell_environment_policy]`nignore_default_excludes = true # retain comment`ninherit = 'core'`nset = { KEEP = 'value' }`n[model_providers.azure_foundry]`nbase_url = 'old' # keep URL comment`ncustom = 'preserved'`n$tail"
        $result = Merge-CodexConfig $text $endpoint $ids[0] 'C:\example user\.codex\azure-foundry-models.json'
        Assert-True ($result.Contains($untouched)) 'Unrelated multiline content or policies changed.'
        Assert-True ($result.Contains($tail)) 'Unrelated tables/arrays changed.'
        Assert-True ($result.Contains('model = "gpt-6-astra" # keep model comment')) 'Managed scalar/comment merge failed.'
        Assert-True ($result.Contains('ignore_default_excludes = false # retain comment')) 'Secret exclusion policy not enforced.'
        Assert-True ($result.Contains("inherit = 'core'`nset = { KEEP = 'value' }")) 'Other shell settings changed.'
        Assert-True ($result.Contains('model_catalog_json = "C:/example user/.codex/azure-foundry-models.json"')) 'Catalog path is not a portable absolute path.'
        Assert-Equal (Merge-CodexConfig $result $endpoint $ids[0] 'C:\example user\.codex\azure-foundry-models.json') $result 'TOML rerun changed content.'
        foreach ($newline in @("`n", "`r`n")) {
            foreach ($key in @('model', '"model"', "'model'")) {
                for ($i = 0; $i -lt 8; $i++) {
                    $preserved = ($untouched + "`nmarker_$i = 'literal # = [$i]'`n" + $tail).Replace("`r`n", "`n").Replace("`n", $newline)
                    $source = "$key = 'old' # property $i$newline$preserved"
                    $merged = Merge-CodexConfig $source $endpoint $ids[1] 'C:\example\models.json'
                    Assert-True ($merged.Contains($preserved.Substring($preserved.IndexOf('[model_providers.other]')))) 'Untouched suffix failed preservation property.'
                    Assert-True ($merged.Contains($untouched.Replace("`r`n", "`n").Replace("`n", $newline))) 'Untouched root content failed preservation property.'
                    Assert-Equal (Merge-CodexConfig $merged $endpoint $ids[1] 'C:\example\models.json') $merged 'Idempotency property failed.'
                }
            }
        }
    }

    Test-Case 'ambiguous/conflicting TOML and prompt overrides fail closed' {
        $invalidForms = @(
            'model = """multiline"""', 'model = { id = "old" }', 'model.id = "old"', '[model]',
            "model = 'one'`n`"model`" = 'two'", '"mo\u0064el" = "old"',
            'model_providers = { other = { name = "other" } }', 'model_providers.azure_foundry.name = "old"',
            "[model_providers]`nazure_foundry = { name = 'old' }", '[[model_providers.azure_foundry]]',
            "[model_providers.azure_foundry]`n[model_providers.azure_foundry]", '[model_providers.azure_foundry.base_url]',
            'shell_environment_policy.ignore_default_excludes = true', 'shell_environment_policy = { inherit = "all" }',
            "[shell_environment_policy]`nignore_default_excludes.value = true", '[shell_environment_policy.ignore_default_excludes]',
            'note = """unterminated', 'note = ["unterminated collection"'
        )
        foreach ($text in $invalidForms) { Assert-Throws { Merge-CodexConfig $text $endpoint $ids[0] 'C:\example\models.json' } }
        foreach ($name in @('model_instructions_file', 'instructions', 'experimental_instructions_file', 'base_instructions')) {
            foreach ($text in @("$name = 'custom'", "'$name' = 'custom'", "$name.path = 'custom'", "[$name]")) {
                Assert-Throws { Merge-CodexConfig $text $endpoint $ids[0] 'C:\example\models.json' } '*override*'
            }
        }
    }

    Test-Case 'real temporary installation, native auth untouched, idempotent rerun' {
        $homePath = Join-Path $work 'fresh home'
        $plan = New-CodexPlan $homePath $endpoint @($ids[2], $ids[0]) $fixtureJson
        Assert-True (-not [IO.Directory]::Exists($homePath)) 'Planning created files/directories.'
        Assert-Equal $plan.Model $ids[0] 'Astra should be preferred.'
        $fake = New-FakeCredentials
        Save-CodexPlan $plan 'test-placeholder' -ReadKey $fake.Read -WriteKey $fake.Write
        Assert-Equal $fake.State.User 'test-placeholder' 'User credential was not saved through the injected boundary.'
        Assert-Equal $fake.State.Process 'test-placeholder' 'Process credential was not saved.'
        Assert-Equal $fake.State.Unrelated 'preserved' 'Unrelated environment changed.'
        foreach ($file in $plan.Files) {
            Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals([IO.File]::ReadAllBytes($file.Path), $file.Content)) 'Installed bytes differ from validated plan.'
            Assert-True (-not [IO.File]::ReadAllText($file.Path).Contains('test-placeholder')) 'A credential was written into config/catalog.'
        }
        $auth = Join-Path $homePath 'auth.json'
        [IO.File]::WriteAllText($auth, '{"fixture":"untouched"}')
        $again = New-CodexPlan $homePath $endpoint @($ids[2], $ids[0]) $fixtureJson
        Assert-True (-not @($again.Files | Where-Object { $_.NeedsWrite }).Count) 'Identical rerun would rewrite files.'
        Save-CodexPlan $again 'test-placeholder' -ReadKey $fake.Read -WriteKey $fake.Write
        Assert-Equal ([IO.File]::ReadAllText($auth)) '{"fixture":"untouched"}' 'Native auth file was changed.'
        Assert-Equal ([IO.Directory]::GetFiles($homePath, '*.bak-*').Count) 0 'Unchanged files were backed up unnecessarily.'
        Assert-Equal ([IO.Directory]::GetFiles($homePath, '.codex-stage-*').Count) 0 'Staged files were stranded.'
        $fallback = New-CodexPlan (Join-Path $work 'fallback') $endpoint @($ids[2]) $fixtureJson
        Assert-Equal $fallback.Model $ids[2] 'A verified non-Astra model should be the fallback.'
    }

    Test-Case 'credential failure restores actual file bytes and both credential scopes' {
        $homePath = Join-Path $work 'rollback'
        [IO.Directory]::CreateDirectory($homePath) | Out-Null
        $configPath = Join-Path $homePath 'config.toml'
        $catalogPath = Join-Path $homePath 'azure-foundry-models.json'
        [IO.File]::WriteAllText($configPath, "# original`r`nmodel = 'old'`r`n", [Text.UTF8Encoding]::new($true))
        [IO.File]::WriteAllText($catalogPath, 'original catalog bytes')
        $oldConfig = [IO.File]::ReadAllBytes($configPath)
        $oldCatalog = [IO.File]::ReadAllBytes($catalogPath)
        $plan = New-CodexPlan $homePath $endpoint $ids $fixtureJson
        $fake = New-FakeCredentials
        $fake.State.FailProcessOnce = $true
        Assert-Throws { Save-CodexPlan $plan 'test-placeholder' -ReadKey $fake.Read -WriteKey $fake.Write } '*rolled back*'
        Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals([IO.File]::ReadAllBytes($configPath), $oldConfig)) 'Config including BOM was not restored exactly.'
        Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals([IO.File]::ReadAllBytes($catalogPath), $oldCatalog)) 'Catalog was not restored exactly.'
        Assert-Equal $fake.State.User 'previous-user-placeholder' 'User credential rollback failed.'
        Assert-Equal $fake.State.Process 'previous-process-placeholder' 'Process credential rollback failed.'
        Assert-Equal $fake.State.Unrelated 'preserved' 'Rollback changed unrelated environment.'
        Assert-Equal ([IO.Directory]::GetFiles($homePath, '*.bak-*').Count) 2 'Unique backups were not retained.'
        foreach ($file in $plan.Files) {
            Assert-True ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals([IO.File]::ReadAllBytes($file.Backup), $file.Original)) 'Backup bytes are incorrect.'
        }
        Assert-Equal ([IO.Directory]::GetFiles($homePath, '.codex-stage-*').Count) 0 'Rollback stranded staging files.'
        $retry = New-CodexPlan $homePath $endpoint $ids $fixtureJson
        Save-CodexPlan $retry 'test-placeholder' -ReadKey $fake.Read -WriteKey $fake.Write
        Assert-Equal ([IO.Directory]::GetFiles($homePath, '*.bak-*').Count) 4 'Retry overwrote earlier backups.'
    }

    Test-Case 'locked config rolls back installed catalog without touching credentials' {
        $homePath = Join-Path $work 'locked'
        [IO.Directory]::CreateDirectory($homePath) | Out-Null
        $configPath = Join-Path $homePath 'config.toml'
        $catalogPath = Join-Path $homePath 'azure-foundry-models.json'
        [IO.File]::WriteAllText($configPath, "model = 'old'")
        [IO.File]::WriteAllText($catalogPath, 'old catalog')
        $plan = New-CodexPlan $homePath $endpoint $ids $fixtureJson
        $fake = New-FakeCredentials
        $lock = [IO.File]::Open($configPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Assert-Throws { Save-CodexPlan $plan 'test-placeholder' -ReadKey $fake.Read -WriteKey $fake.Write } '*rolled back*' }
        finally { $lock.Dispose() }
        Assert-Equal ([IO.File]::ReadAllText($configPath)) "model = 'old'" 'Locked config was changed.'
        Assert-Equal ([IO.File]::ReadAllText($catalogPath)) 'old catalog' 'Installed catalog was not rolled back.'
        Assert-Equal $fake.State.Writes 0 'Credentials were touched before file installation succeeded.'
        Assert-Equal ([IO.Directory]::GetFiles($homePath, '.codex-stage-*').Count) 0 'Lock failure stranded staging files.'
    }

    Test-Case 'new-install rollback and concurrent-edit rejection leave no partial setup' {
        $homePath = Join-Path $work 'failed-new'
        $plan = New-CodexPlan $homePath $endpoint $ids $fixtureJson
        $fake = New-FakeCredentials
        $fake.State.User = $null; $fake.State.Process = $null; $fake.State.FailProcessOnce = $true
        Assert-Throws { Save-CodexPlan $plan 'test-placeholder' -ReadKey $fake.Read -WriteKey $fake.Write } '*rolled back*'
        Assert-True (-not [IO.Directory]::Exists($homePath)) 'Failed new installation left files behind.'
        Assert-True ($null -eq $fake.State.User -and $null -eq $fake.State.Process) 'Previously absent credentials were not restored.'
        [IO.Directory]::CreateDirectory($homePath) | Out-Null
        $configPath = Join-Path $homePath 'config.toml'
        [IO.File]::WriteAllText($configPath, "model = 'old'")
        $plan = New-CodexPlan $homePath $endpoint $ids $fixtureJson
        [IO.File]::WriteAllText($configPath, "model = 'concurrent edit'")
        $fake = New-FakeCredentials
        Assert-Throws { Save-CodexPlan $plan 'test-placeholder' -ReadKey $fake.Read -WriteKey $fake.Write } '*concurrent edits*'
        Assert-Equal ([IO.File]::ReadAllText($configPath)) "model = 'concurrent edit'" 'A concurrent edit was overwritten.'
        Assert-Equal $fake.State.Writes 0 'Concurrent-edit failure wrote credentials.'
        Assert-Equal ([IO.Directory]::GetFiles($homePath).Count) 1 'Concurrent-edit failure created artifacts.'
    }

    Test-Case 'default and explicit false route through unchanged OpenCode setup' {
        $results = @()
        foreach ($mode in @('default', 'false')) {
            $homePath = Join-Path $work "opencode-$mode"
            $binPath = Join-Path $homePath 'bin'
            [IO.Directory]::CreateDirectory($binPath) | Out-Null
            [IO.File]::WriteAllText((Join-Path $binPath 'opencode.cmd'), '@echo off')
            $harness = Join-Path $homePath 'run.ps1'
            $escapedHome = $homePath.Replace("'", "''")
            $escapedBin = $binPath.Replace("'", "''")
            $escapedMain = $mainScript.Replace("'", "''")
            $codexArg = if ($mode -eq 'false') { '-Codex:$false' } else { '' }
            $lines = @(
                '$ErrorActionPreference = ''Stop'''
                "`$env:USERPROFILE = '$escapedHome'"
                "`$env:LOCALAPPDATA = '$escapedHome'"
                "`$env:PATH = '$escapedBin;' + `$env:PATH"
                'function Invoke-RestMethod {'
                '    param($Method, $Uri, $Body, $ContentType, $Headers, $TimeoutSec, $MaximumRedirection)'
                '    [pscustomobject]@{ ok = $true }'
                '}'
                "& '$escapedMain' -Endpoint '$endpoint' -ApiKey 'test-placeholder' -Force $codexArg"
            )
            [IO.File]::WriteAllLines($harness, $lines, [Text.UTF8Encoding]::new($false))
            $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $harness 2>&1
            Assert-Equal $LASTEXITCODE 0 "OpenCode $mode route failed: $($output -join ' ')"
            $configPath = Join-Path $homePath '.config\opencode\opencode.json'
            Assert-True ([IO.File]::Exists($configPath)) "OpenCode $mode route did not write only its isolated config."
            Assert-True (-not [IO.Directory]::Exists((Join-Path $homePath '.codex'))) "OpenCode $mode route entered Codex setup."
            $config = [IO.File]::ReadAllText($configPath) | ConvertFrom-Json
            Assert-Equal $config.model 'anthropic/claude-opus-5' 'Existing OpenCode default model changed.'
            Assert-Equal $config.small_model 'openai/gpt-5.6-luna' 'Existing OpenCode small_model behavior changed.'
            Assert-Equal ((@($config.provider.PSObject.Properties.Name) | Sort-Object) -join ',') 'anthropic,openai' 'Existing OpenCode providers changed.'
            Assert-Equal $config.provider.openai.options.baseURL "$endpoint/openai/v1" 'Existing OpenCode endpoint changed.'
            Assert-True (@($config.plugin).Count -eq 1) 'Existing OpenCode mapper installation changed.'
            $results += $config
        }
        Assert-Equal $results[0].model $results[1].model '-Codex:$false differs from omitted -Codex.'
        Assert-Equal $results[0].small_model $results[1].small_model '-Codex:$false changed small_model.'

        $rejectHarness = Join-Path $work 'reject-routing.ps1'
        $escapedMain = $mainScript.Replace("'", "''")
        [IO.File]::WriteAllLines($rejectHarness, @(
            'function Read-Host { throw ''PROMPT WAS CALLED'' }'
            "try { & '$escapedMain' -Codex -AnthropicModel ''; throw 'NO REJECTION' } catch { if (`$_.Exception.Message -notlike '*cannot be combined*') { throw }; Write-Host 'exclusive-ok' }"
            "try { & '$escapedMain' -Codex -Endpoint 'http://invalid.example'; throw 'NO VALIDATION' } catch { if (`$_.Exception.Message -notlike '*HTTPS resource root*') { throw }; Write-Host 'endpoint-before-prompt-ok' }"
        ), [Text.UTF8Encoding]::new($false))
        $output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $rejectHarness 2>&1
        Assert-Equal $LASTEXITCODE 0 "Codex routing guards failed: $($output -join ' ')"
        Assert-True (($output -join ' ') -notlike '*PROMPT WAS CALLED*') 'Codex routing prompted before rejecting invalid input.'
    }

    Test-Case 'Force never bypasses TOML validation or prompt override protection' {
        $homePath = Join-Path $work 'forced-invalid'
        [IO.Directory]::CreateDirectory($homePath) | Out-Null
        $configPath = Join-Path $homePath 'config.toml'
        [IO.File]::WriteAllText($configPath, 'model_instructions_file = "custom.txt"')
        function Get-CodexOfficialCatalog { $fixtureJson }
        function Read-Host { throw 'Unexpected overwrite prompt.' }
        function Save-CodexPlan { throw 'Unexpected mutation boundary.' }
        Assert-Throws { Install-AzureCodex -Endpoint $endpoint -ApiKey 'test-placeholder' -Models $ids -HomePath $homePath -Force } '*override*'
        Assert-Equal ([IO.Directory]::GetFiles($homePath).Count) 1 'Validation failure wrote artifacts.'
        Assert-Equal ([IO.File]::ReadAllText($configPath)) 'model_instructions_file = "custom.txt"' 'Prompt override was discarded.'
    }

    if ($OnlineCatalog) {
        Test-Case 'public pinned official catalog supports every requested model without metadata loss' {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $public = Get-CodexOfficialCatalog
            Assert-True ($public.Length -gt 100000) 'The pinned public catalog fixture was not downloaded.'
            Assert-CatalogPreserved $public (New-CodexCatalog $public $ids) $ids
        }
    }
} finally {
    [IO.Directory]::Delete($work, $true)
}
Write-Host "$passed passed; $($failures.Count) failed. Only temporary files and an in-memory credential store were used."
if ($failures.Count) { throw "Codex tests failed: $($failures -join ', ')" }
