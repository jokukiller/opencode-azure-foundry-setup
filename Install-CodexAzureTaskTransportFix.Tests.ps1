[CmdletBinding()]
param([string] $TempRoot = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'Install-CodexAzureTaskTransportFix.ps1'
if (-not [IO.File]::Exists($scriptPath)) { throw 'Installer script is missing.' }

$source = [IO.File]::ReadAllText($scriptPath)
[void][scriptblock]::Create($source)
if ($source -match 'C:\\Users\\anas|anjumshabana|CODEX_AZURE_API_KEY\s*=') {
    throw 'Installer contains a machine-specific path or credential assignment.'
}

$output = & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptPath `
    -Action Test -CodexHome (Join-Path $TempRoot ('codex-shim-test-' + [Guid]::NewGuid().ToString('N'))) 2>&1
if ($LASTEXITCODE -ne 0 -or ($output -join ' ') -notlike '*rewrite self-test passed*') {
    throw "Installer test failed: $($output -join [Environment]::NewLine)"
}
Write-Host 'PASS PowerShell parsing, privacy guard, compilation and rewrite self-test.'
