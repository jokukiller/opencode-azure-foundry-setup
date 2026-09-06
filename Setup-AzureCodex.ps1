# Loaded only by Setup-AzureOpenCode.ps1 -Codex. No work is performed on import.
$script:CodexCatalogUrl = 'https://raw.githubusercontent.com/openai/codex/rust-v0.153.4/codex-rs/models-manager/models.json'
$script:CodexSecurityInstructions = @(
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

function Resolve-CodexEndpoint {
    param([string] $Endpoint)
    $uri = $null
    if ($Endpoint -notmatch '\Ahttps://[^/?#@\\\s]+/?\z' -or
        -not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref] $uri) -or
        -not $uri.IsWellFormedOriginalString() -or $uri.Scheme -ne 'https' -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') {
        throw 'Codex requires an HTTPS resource root, without credentials, path, query or fragment (https://YOUR-RESOURCE.services.ai.azure.com).'
    }
    $uri.GetLeftPart([UriPartial]::Authority)
}

function Resolve-CodexHome {
    param([string] $HomePath = $env:CODEX_HOME, [string] $UserProfile = $env:USERPROFILE)
    if ([string]::IsNullOrEmpty($HomePath)) { $HomePath = Join-Path $UserProfile '.codex' }
    if ($HomePath -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/?]+[\\/][^\\/?]+(?:[\\/]|$))' -or
        $HomePath -match '[\x00-\x1f]' -or $HomePath.StartsWith('\\.\') -or $HomePath.StartsWith('\\?\')) {
        throw 'CODEX_HOME must be an absolute native Windows path (drive-rooted or UNC), not a relative or WSL path.'
    }
    [IO.Path]::GetFullPath($HomePath)
}

function Assert-CodexInstalled {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'This setup supports native Windows only. WSL has separate Codex configuration and environment.'
    }
    $found = $false
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        foreach ($name in @('OpenAI.Codex', 'OpenAI.ChatGPT-Desktop', 'OpenAI.ChatGPT')) {
            try {
                foreach ($package in @(Get-AppxPackage -Name $name -ErrorAction Stop)) {
                    Write-Ok "$($package.Name) $($package.Version)"
                    $found = $true
                }
            } catch { Write-Warn "Could not query the $name package; checking the CLI too." }
        }
    }
    $cli = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cli) {
        $version = 'version unavailable'
        # Never execute a WindowsApps alias or protected package executable.
        try {
            $productVersion = (Get-Item -LiteralPath $cli.Source -ErrorAction Stop).VersionInfo.ProductVersion
            $npmPackage = Join-Path (Split-Path $cli.Source -Parent) 'node_modules\@openai\codex\package.json'
            if ($productVersion) { $version = $productVersion }
            elseif (Test-Path -LiteralPath $npmPackage) { $version = (Get-Content -LiteralPath $npmPackage -Raw | ConvertFrom-Json).version }
        } catch { }
        Write-Ok "Codex CLI on PATH ($version)"
        $found = $true
    }
    if (-not $found) { throw 'Install the official Windows Codex/ChatGPT coding app or put the Codex CLI on PATH, then rerun. OpenCode is not required.' }
    Write-Warn 'Use an up-to-date desktop app AND bundled Codex engine. The catalog snapshot was tested with engine 0.153.4.'
}

function Get-CodexOfficialCatalog {
    try {
        (Invoke-WebRequest -UseBasicParsing -Uri $script:CodexCatalogUrl -TimeoutSec 30 -MaximumRedirection 0 -ErrorAction Stop).Content
    } catch { throw 'Could not download the pinned official Codex catalog. Check access to raw.githubusercontent.com and rerun. Nothing was written.' }
}

function Add-CodexSecurityInstructions {
    param([string] $Text)
    $block = $script:CodexSecurityInstructions
    $first = $Text.IndexOf($block, [StringComparison]::Ordinal)
    if ($first -ge 0) {
        if ($first -ne $Text.LastIndexOf($block, [StringComparison]::Ordinal) -or
            -not $Text.EndsWith($block, [StringComparison]::Ordinal)) {
            throw 'Catalog contains an ambiguous or duplicated security instruction block.'
        }
        return $Text
    }
    $Text + "`n`n" + $block
}

function New-CodexCatalog {
    param([string] $Json, [string[]] $Models, [switch] $UseCodexDefaults)
    if (-not $Models -or $Models.Count -eq 0) { throw 'No verified Codex models were supplied.' }
    try { $catalog = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'The pinned Codex catalog is not valid JSON. Nothing was written.' }
    if (-not $catalog.models) { throw 'The pinned Codex catalog has no models.' }
    $selected = @()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $Models) {
        if (-not $seen.Add($id)) { throw "Duplicate requested Codex model: $id" }
        $matches = @($catalog.models | Where-Object { $_.slug -ceq $id })
        if ($matches.Count -ne 1) { throw "The pinned catalog must contain exactly one native entry for $id. Update the tested pin instead of using a generic prompt." }
        $model = $matches[0]
        if ($model.model_messages.instructions_template -isnot [string] -or
            [string]::IsNullOrWhiteSpace($model.model_messages.instructions_template)) {
            throw "No native instructions_template for $id. Nothing was written; no generic prompt will be substituted."
        }
        $model.model_messages.instructions_template = Add-CodexSecurityInstructions $model.model_messages.instructions_template
        if ($model.PSObject.Properties['base_instructions']) {
            if ($model.base_instructions -isnot [string] -or [string]::IsNullOrWhiteSpace($model.base_instructions)) {
                throw "Invalid legacy base_instructions for $id. Nothing was written."
            }
            $model.base_instructions = Add-CodexSecurityInstructions $model.base_instructions
        }
        if (-not $UseCodexDefaults) {
            foreach ($entry in ([ordered]@{ context_window = 1050000; max_context_window = 1050000; auto_compact_token_limit = 900000; effective_context_window_percent = 87 }).GetEnumerator()) {
                if ($model.PSObject.Properties[$entry.Key]) { $model.PSObject.Properties[$entry.Key].Value = $entry.Value }
                else { $model | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value }
            }
        }
        $selected += $model
    }
    $catalog.models = @($selected)
    $catalog | ConvertTo-Json -Depth 100
}

function ConvertTo-CodexTomlString {
    param([string] $Value)
    ConvertTo-Json -InputObject $Value -Compress
}

# A lexical scanner, not a general TOML parser. Only edit value spans after
# identifying real statements outside comments, strings, arrays and inline tables.
function Get-CodexTomlStatements {
    param([string] $Text)
    $start = 0; $equals = -1; $commentAt = -1
    $quote = ''; $multiline = $false; $comment = $false
    $stack = [Collections.Generic.Stack[char]]::new()
    for ($i = 0; $i -le $Text.Length; $i++) {
        $eof = $i -eq $Text.Length
        $c = if ($eof) { "`n" } else { $Text[$i] }
        if ($eof -and ($quote -or $stack.Count)) { throw 'Unterminated TOML string or collection. Fix config.toml before rerunning.' }
        if ($c -eq "`n" -and -not $quote) {
            $comment = $false
            if ($stack.Count -eq 0) {
                $codeEnd = if ($commentAt -ge 0) { $commentAt } else { $i }
                $code = $Text.Substring($start, $codeEnd - $start).Trim()
                if ($code) {
                    $statementEnd = if ($eof) { $i } else { $i + 1 }
                    $statement = [pscustomobject]@{ Start = $start; End = $statementEnd; Code = $code; Key = $null; Value = $null; ValueStart = 0 }
                    if ($equals -ge 0) {
                        $statement.Key = $Text.Substring($start, $equals - $start).Trim()
                        $valueStart = $equals + 1
                        while ($valueStart -lt $codeEnd -and [char]::IsWhiteSpace($Text[$valueStart])) { $valueStart++ }
                        $statement.ValueStart = $valueStart
                        $statement.Value = $Text.Substring($valueStart, $codeEnd - $valueStart).TrimEnd()
                    }
                    $statement
                }
                $start = $i + 1; $equals = -1; $commentAt = -1
            }
            continue
        }
        if ($comment) { continue }
        if ($quote) {
            if (-not $multiline -and ($c -eq "`n" -or $c -eq "`r")) { throw 'Newline in a single-line TOML string.' }
            if ($quote -eq '"' -and $c -eq '\') {
                if (-not $multiline -and ($i + 1 -ge $Text.Length -or $Text[$i + 1] -eq "`n" -or $Text[$i + 1] -eq "`r")) {
                    throw 'Invalid escape in a single-line TOML string.'
                }
                $i++; continue
            }
            if ($c -eq $quote) {
                if (-not $multiline) { $quote = '' }
                elseif ($i + 2 -lt $Text.Length -and $Text.Substring($i, 3) -ceq ($quote * 3)) {
                    $run = 3
                    while ($i + $run -lt $Text.Length -and $Text[$i + $run] -eq $quote) { $run++ }
                    if ($run -gt 5) { throw 'Unsupported TOML multiline quote sequence.' }
                    $i += $run - 1; $quote = ''; $multiline = $false
                }
            }
            continue
        }
        if ($c -eq '#') {
            $comment = $true
            if ($stack.Count -eq 0) { $commentAt = $i }
        } elseif ($c -eq '"' -or $c -eq "'") {
            $quote = [string] $c
            $multiline = $i + 2 -lt $Text.Length -and $Text.Substring($i, 3) -ceq ($quote * 3)
            if ($multiline) { $i += 2 }
        } elseif ($c -eq '[' -or $c -eq '{') {
            $stack.Push($c)
        } elseif ($c -eq ']' -or $c -eq '}') {
            $expected = if ($c -eq ']') { '[' } else { '{' }
            if ($stack.Count -eq 0 -or $stack.Pop() -ne $expected) { throw 'Unbalanced TOML collection or table header.' }
        } elseif ($c -eq '=' -and $stack.Count -eq 0 -and $equals -lt 0) {
            $equals = $i
        }
    }
}

function ConvertFrom-CodexTomlKey {
    param([string] $Text)
    $offset = 0
    do {
        # Escaped quoted key names are deliberately rejected, even when unrelated:
        # they could spell a managed key after decoding. Quoted dots stay literal.
        $match = [regex]::Match($Text.Substring($offset), '\A\s*(?:([A-Za-z0-9_-]+)|"([^"\\\x00-\x1f]*)"|''([^''\x00-\x1f]*)'')\s*(?:(\.)|$)')
        if (-not $match.Success) { throw 'Unsupported TOML key syntax. Use bare or unescaped quoted keys, and ordinary tables for Codex-managed settings.' }
        if ($match.Groups[1].Success) { $match.Groups[1].Value }
        elseif ($match.Groups[2].Success) { $match.Groups[2].Value }
        else { $match.Groups[3].Value }
        $offset += $match.Length
        if ($match.Groups[4].Success -and $offset -eq $Text.Length) { throw 'Incomplete dotted TOML key.' }
    } while ($offset -lt $Text.Length)
}

function Merge-CodexConfig {
    param([string] $Text, [string] $Endpoint, [string] $Model, [string] $CatalogPath, [switch] $UseCodexDefaults)
    $root = [ordered]@{
        model_provider = '"azure_foundry"'
        model = (ConvertTo-CodexTomlString $Model)
        model_catalog_json = (ConvertTo-CodexTomlString $CatalogPath.Replace('\', '/'))
    }
    $contextKeys = @('model_context_window', 'model_auto_compact_token_limit')
    if (-not $UseCodexDefaults) {
        $root.model_context_window = '1050000'
        $root.model_auto_compact_token_limit = '900000'
    }
    $managedRootKeys = @($root.Keys) + $contextKeys
    $provider = [ordered]@{
        name = '"Azure Foundry"'
        base_url = (ConvertTo-CodexTomlString "$Endpoint/openai/v1")
        wire_api = '"responses"'
        env_key = '"CODEX_AZURE_API_KEY"'
        requires_openai_auth = 'false'
        supports_websockets = 'false'
    }
    $overrides = @('model_instructions_file', 'experimental_instructions_file', 'instructions', 'base_instructions')
    $groups = [ordered]@{}
    foreach ($name in @('root', 'provider', 'shell')) {
        $values = if ($name -eq 'root') { $root } elseif ($name -eq 'provider') { $provider } else { [ordered]@{ ignore_default_excludes = 'false' } }
        $groups[$name] = @{ Values = $values; Seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal); End = $Text.Length; Exists = ($name -eq 'root') }
    }
    $section = 'root'; $path = @()
    $edits = [Collections.Generic.List[object]]::new()
    $removedContextKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $scalar = '\A(?:"(?:[^"\\\x00-\x1f]|\\(?:["\\btnfr]|u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8}))*"|''[^''\x00-\x1f]*''|true|false|[+-]?(?:0|[1-9](?:_?[0-9])*))\z'
    foreach ($statement in @(Get-CodexTomlStatements $Text)) {
        if ($null -eq $statement.Key) {
            if ($groups.Contains($section)) { $groups[$section].End = $statement.Start }
            $arrayTable = $statement.Code.StartsWith('[[')
            $pattern = if ($arrayTable) { '\A\[\[([^\r\n]*)\]\]\z' } else { '\A\[([^\r\n]*)\]\z' }
            $header = [regex]::Match($statement.Code, $pattern)
            if (-not $header.Success) { throw 'Unsupported TOML statement or table header.' }
            $path = @(ConvertFrom-CodexTomlKey $header.Groups[1].Value)
            $section = 'other'
            if ($overrides -ccontains $path[0]) {
                throw 'A root native-prompt override is present (model_instructions_file or legacy instructions). Migrate/remove that override yourself in config.toml, then rerun; it would hide catalog prompts.'
            }
            if ($managedRootKeys -ccontains $path[0]) { throw 'A Codex-managed root scalar is represented as a table. Use a scalar assignment instead.' }
            if ($path[0] -ceq 'model_providers') {
                if ($path.Count -eq 1) {
                    if ($arrayTable) { throw 'model_providers cannot be an array of tables.' }
                    $section = 'providers'
                } elseif ($path[1] -ceq 'azure_foundry') {
                    if ($arrayTable -or ($path.Count -gt 2 -and @($provider.Keys) -ccontains $path[2])) { throw 'Unsupported table representation under model_providers.azure_foundry.' }
                    if ($path.Count -eq 2) { $section = 'provider' }
                }
            } elseif ($path[0] -ceq 'shell_environment_policy') {
                if ($arrayTable -or ($path.Count -gt 1 -and $path[1] -ceq 'ignore_default_excludes')) { throw 'Unsupported table representation under shell_environment_policy.' }
                if ($path.Count -eq 1) { $section = 'shell' }
            }
            if ($groups.Contains($section)) {
                if ($groups[$section].Exists) { throw "Duplicate Codex-managed TOML table: $section" }
                $groups[$section].Exists = $true
                $groups[$section].End = $Text.Length
            }
            continue
        }
        $key = @(ConvertFrom-CodexTomlKey $statement.Key)
        if ($section -eq 'root') {
            if ($overrides -ccontains $key[0]) {
                throw 'A root native-prompt override is present (model_instructions_file or legacy instructions). Migrate/remove that override yourself in config.toml, then rerun; it would hide catalog prompts.'
            }
            if ($key[0] -ceq 'shell_environment_policy' -or
                ($key[0] -ceq 'model_providers' -and ($key.Count -eq 1 -or $key[1] -ceq 'azure_foundry'))) {
                throw 'Inline/dotted Codex provider or shell policy conflicts with setup. Use [model_providers.azure_foundry] and [shell_environment_policy] tables instead.'
            }
        }
        if ($section -eq 'providers' -and $key[0] -ceq 'azure_foundry') { throw 'Use a [model_providers.azure_foundry] table instead of an inline/dotted provider.' }
        if ($section -eq 'root' -and $UseCodexDefaults -and $contextKeys -ccontains $key[0]) {
            if ($key.Count -ne 1) { throw "Dotted representation of managed key $($key[0]) is unsupported." }
            if (-not $removedContextKeys.Add($key[0])) { throw "Duplicate managed TOML key: $($key[0])" }
            if ($statement.Value -cnotmatch $scalar) { throw "Unsupported value for managed key $($key[0]). Use a single-line string, decimal integer or boolean, not a multiline/inline value." }
            $edits.Add(@{ Offset = $statement.Start; Length = $statement.End - $statement.Start; Text = '' })
            continue
        }
        if (-not $groups.Contains($section) -or -not (@($groups[$section].Values.Keys) -ccontains $key[0])) { continue }
        $group = $groups[$section]
        if ($key.Count -ne 1) { throw "Dotted representation of managed key $($key[0]) is unsupported." }
        if (-not $group.Seen.Add($key[0])) { throw "Duplicate managed TOML key: $($key[0])" }
        if ($statement.Value -cnotmatch $scalar) { throw "Unsupported value for managed key $($key[0]). Use a single-line string, decimal integer or boolean, not a multiline/inline value." }
        $edits.Add(@{ Offset = $statement.ValueStart; Length = $statement.Value.Length; Text = $group.Values[$key[0]] })
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $insertions = @{}
    foreach ($name in $groups.Keys) {
        $group = $groups[$name]
        $missing = @($group.Values.Keys | Where-Object { -not $group.Seen.Contains($_) })
        if (-not $missing.Count) { continue }
        $addition = (@($missing | ForEach-Object { "$_ = $($group.Values[$_])" }) -join $newline) + $newline
        if (-not $group.Exists) {
            $header = if ($name -eq 'provider') { 'model_providers.azure_foundry' } else { 'shell_environment_policy' }
            $addition = "$newline[$header]$newline$addition"
        }
        $offset = $group.End
        if (-not $insertions.ContainsKey($offset)) {
            $insertions[$offset] = ''
            if ($offset -gt 0 -and $Text[$offset - 1] -ne "`n") { $insertions[$offset] = $newline }
        }
        $insertions[$offset] += $addition
    }
    foreach ($offset in $insertions.Keys) { $edits.Add(@{ Offset = $offset; Length = 0; Text = $insertions[$offset] }) }
    foreach ($edit in @($edits | Sort-Object { $_.Offset } -Descending)) {
        $Text = $Text.Remove($edit.Offset, $edit.Length).Insert($edit.Offset, $edit.Text)
    }
    $Text
}

function Get-CodexFileSnapshot {
    param([string] $Path)
    $original = $null
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing to overwrite a directory or linked Codex file: $Path"
        }
        $original = [IO.File]::ReadAllBytes($Path)
    }
    [pscustomobject]@{ Path = $Path; Original = $original; Content = $null; NeedsWrite = $false; Stage = $null; Backup = $null; RollbackDiscard = $null; Committed = $false }
}

function New-CodexPlan {
    param([string] $HomePath, [string] $Endpoint, [string[]] $Models, [string] $CatalogJson, [switch] $UseCodexDefaults)
    $HomePath = Resolve-CodexHome -HomePath $HomePath
    $Endpoint = Resolve-CodexEndpoint $Endpoint
    $catalog = New-CodexCatalog -Json $CatalogJson -Models $Models -UseCodexDefaults:$UseCodexDefaults
    $model = if ($Models -ccontains 'gpt-6-astra') { 'gpt-6-astra' } else { $Models[0] }
    $files = @(
        (Get-CodexFileSnapshot (Join-Path $HomePath 'azure-foundry-models.json'))
        (Get-CodexFileSnapshot (Join-Path $HomePath 'config.toml'))
    )
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = ''
    if ($null -ne $files[1].Original) {
        try { $text = $utf8.GetString($files[1].Original).TrimStart([char] 0xfeff) }
        catch { throw 'config.toml must be UTF-8. Convert its encoding before rerunning; nothing was written.' }
    }
    $config = Merge-CodexConfig -Text $text -Endpoint $Endpoint -Model $model -CatalogPath $files[0].Path -UseCodexDefaults:$UseCodexDefaults
    if ((Merge-CodexConfig -Text $config -Endpoint $Endpoint -Model $model -CatalogPath $files[0].Path -UseCodexDefaults:$UseCodexDefaults) -cne $config) {
        throw 'The staged TOML merge was not stable. Nothing was written.'
    }
    $files[0].Content = $utf8.GetBytes($catalog)
    $files[1].Content = $utf8.GetBytes($config)
    foreach ($file in $files) {
        $file.NeedsWrite = -not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($file.Original, $file.Content)
    }
    [pscustomobject]@{ HomePath = $HomePath; Files = $files; Models = @($Models); Model = $model; UseCodexDefaults = [bool] $UseCodexDefaults }
}

function Save-CodexPlan {
    param(
        $Plan,
        [string] $ApiKey,
        # These two small boundaries let tests exercise real file transactions
        # without reading or writing the user's actual environment/credentials.
        [scriptblock] $ReadKey = { param([EnvironmentVariableTarget] $Target) [Environment]::GetEnvironmentVariable('CODEX_AZURE_API_KEY', $Target) },
        [scriptblock] $WriteKey = { param($Value, [EnvironmentVariableTarget] $Target) [Environment]::SetEnvironmentVariable('CODEX_AZURE_API_KEY', $Value, $Target) }
    )
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { throw 'No Codex resource key supplied.' }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff') + '-' + [Guid]::NewGuid().ToString('N')
    $previous = @{}; $keyTouched = $false; $createdDirectory = $false; $completed = $false
    foreach ($file in $Plan.Files) { $file.Committed = $false; $file.Stage = $null; $file.Backup = $null; $file.RollbackDiscard = $null }
    try {
        foreach ($file in $Plan.Files) {
            $current = Get-CodexFileSnapshot $file.Path
            if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($current.Original, $file.Original)) {
                throw 'Codex files changed after validation. Rerun setup without concurrent config edits.'
            }
        }
        foreach ($target in @('User', 'Process')) { $previous[$target] = & $ReadKey $target }
        if (-not [IO.Directory]::Exists($Plan.HomePath)) {
            [IO.Directory]::CreateDirectory($Plan.HomePath) | Out-Null
            $createdDirectory = $true
        }
        foreach ($file in $Plan.Files) {
            if (-not $file.NeedsWrite) { continue }
            $file.Stage = Join-Path $Plan.HomePath ('.codex-stage-' + [Guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllBytes($file.Stage, $file.Content)
        }
        # Catalog first, config second; both staged before either is replaced.
        foreach ($file in $Plan.Files) {
            if (-not $file.NeedsWrite) { continue }
            $current = Get-CodexFileSnapshot $file.Path
            if (-not [Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($current.Original, $file.Original)) {
                throw 'Codex files changed during installation.'
            }
            if ($null -ne $file.Original) {
                $file.Backup = "$($file.Path).bak-$stamp"
                [IO.File]::Replace($file.Stage, $file.Path, $file.Backup)
            } else { [IO.File]::Move($file.Stage, $file.Path) }
            $file.Committed = $true
        }
        $keyTouched = $true
        & $WriteKey $ApiKey 'User'
        & $WriteKey $ApiKey 'Process'
        $completed = $true
    } catch {
        $rollbackFailures = @()
        for ($i = $Plan.Files.Count - 1; $i -ge 0; $i--) {
            $file = $Plan.Files[$i]
            if (-not $file.Committed) { continue }
            try {
                if ($null -eq $file.Original) { [IO.File]::Delete($file.Path) }
                else {
                    [IO.File]::Copy($file.Backup, $file.Stage, $true)
                    $file.RollbackDiscard = Join-Path $Plan.HomePath ('.codex-rollback-' + [Guid]::NewGuid().ToString('N'))
                    [IO.File]::Replace($file.Stage, $file.Path, $file.RollbackDiscard)
                    [IO.File]::Delete($file.RollbackDiscard)
                    $file.RollbackDiscard = $null
                }
            } catch { $rollbackFailures += [IO.Path]::GetFileName($file.Path) }
        }
        if ($keyTouched) {
            foreach ($target in @('User', 'Process')) {
                try { & $WriteKey $previous[$target] $target }
                catch { $rollbackFailures += "$target environment" }
            }
        }
        # Do not echo exceptions from credential APIs: they might include values.
        if ($rollbackFailures.Count) {
            throw "Codex setup failed and rollback was incomplete: $($rollbackFailures -join ', '). Restore the .bak-* files in $($Plan.HomePath) and the previous CODEX_AZURE_API_KEY before retrying."
        }
        throw 'Codex setup could not be saved. Any changed files and credential were rolled back. Check file locks, permissions, environment access or concurrent edits; backups were retained.'
    } finally {
        foreach ($file in $Plan.Files) {
            if ($file.Stage -and [IO.File]::Exists($file.Stage)) {
                try { [IO.File]::Delete($file.Stage) } catch { Write-Warning "Could not remove staged file: $($file.Stage)" }
            }
            if ($file.RollbackDiscard -and [IO.File]::Exists($file.RollbackDiscard)) {
                try { [IO.File]::Delete($file.RollbackDiscard) } catch { Write-Warning "Could not remove rollback file: $($file.RollbackDiscard)" }
            }
        }
        if (-not $completed -and $createdDirectory) {
            try { [IO.Directory]::Delete($Plan.HomePath, $false) } catch { }
        }
    }
}

function Install-AzureCodex {
    param([string] $Endpoint, [string] $ApiKey, [string[]] $Models, [switch] $Force, [switch] $UseCodexDefaults, [string] $HomePath = $env:CODEX_HOME)
    Write-Step 'Preparing Codex configuration and native model catalog'
    $json = Get-CodexOfficialCatalog
    $plan = New-CodexPlan -HomePath $HomePath -Endpoint $Endpoint -Models $Models -CatalogJson $json -UseCodexDefaults:$UseCodexDefaults
    Write-Warn 'The resource key will be saved in the Windows USER environment as CODEX_AZURE_API_KEY (not encrypted), and in this PowerShell process. Native auth.json is untouched.'
    if (@($plan.Files | Where-Object { $_.NeedsWrite -and $null -ne $_.Original }).Count -gt 0 -and -not $Force) {
        if ((Read-Host 'Update existing Codex config/catalog (unique backups will be kept)? (y/N)') -notmatch '^[Yy]$') {
            throw 'Aborted. No files or credentials were changed.'
        }
    }
    Save-CodexPlan -Plan $plan -ApiKey $ApiKey
    foreach ($file in $plan.Files) {
        Write-Ok "Ready: $($file.Path)"
        if ($file.Backup) { Write-Ok "Backup: $($file.Backup)" }
    }
    Write-Step 'Codex setup complete'
    Write-Host "  Available native models: $($plan.Models -join ', ')"
    Write-Host "  Default: $($plan.Model)"
    if ($plan.UseCodexDefaults) { Write-Host '  Context: official Codex model and compaction defaults.' }
    else { Write-Host '  Context: 1,050,000 total; 913,500 usable tokens (87%); compaction at 900,000.' }
    Write-Host '  Credential: Windows user environment + this process, CODEX_AZURE_API_KEY (value not shown).'
    Write-Host '  Fully quit and reopen the desktop app, then start a NEW chat. No app was launched or restarted.'
    Write-Host '  Local Azure-backed work does not require a ChatGPT/OpenAI subscription. WSL has separate config/environment.'
}
