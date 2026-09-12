<#
.SYNOPSIS
    Installs a local compatibility shim for Codex task scheduling and
    cross-task messaging when Codex uses an Azure Foundry Responses provider.

.DESCRIPTION
    Codex Desktop can submit app-injected turns as standalone toolOutput items.
    Codex app-server serializes those as function_call_output records without a
    call_id. OpenAI's internal Codex backend accepts that extension, but the
    standard Azure Foundry Responses endpoint rejects it.

    This installer compiles a small local stdio shim with the Windows .NET
    Framework compiler already present on supported Windows systems. The shim
    changes only affected turn/start JSON-RPC requests into Codex's normal text
    input fallback before the real Codex CLI sees or persists them. It never
    proxies network traffic, reads credentials, or logs message content.

    Fully quit and reopen Codex after Install or Uninstall.

.PARAMETER Action
    Install (default), Status, Uninstall, or Test. Test compiles the shim in a
    temporary directory and runs its built-in rewrite test without changing the
    environment or Codex files.

.PARAMETER CodexHome
    Native Windows Codex home. Defaults to CODEX_HOME, then
    %USERPROFILE%\.codex.

.PARAMETER Force
    During Install, allow replacing a pre-existing user CODEX_CLI_PATH. Its
    previous value is preserved in the install manifest for Uninstall.

.EXAMPLE
    .\Install-CodexAzureTaskTransportFix.ps1

.EXAMPLE
    .\Install-CodexAzureTaskTransportFix.ps1 -Action Status

.EXAMPLE
    .\Install-CodexAzureTaskTransportFix.ps1 -Action Uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Status', 'Uninstall', 'Test')]
    [string] $Action = 'Install',
    [string] $CodexHome = $env:CODEX_HOME,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok { param([string] $Message) Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host "  [warn] $Message" -ForegroundColor Yellow }

function Resolve-NativeCodexHome {
    param([string] $Path, [string] $UserProfile = $env:USERPROFILE)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = Join-Path $UserProfile '.codex' }
    if ($Path -notmatch '\A(?:[A-Za-z]:[\\/]|\\\\[^\\/?]+[\\/][^\\/?]+(?:[\\/]|$))' -or
        $Path -match '[\x00-\x1f]' -or $Path.StartsWith('\\.\') -or $Path.StartsWith('\\?\')) {
        throw 'CodexHome must be an absolute native Windows drive or UNC path.'
    }
    [IO.Path]::GetFullPath($Path)
}

function Get-FrameworkCompiler {
    $roots = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    $compiler = @($roots | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
    if (-not $compiler) {
        throw 'The Windows .NET Framework C# compiler was not found. Install/repair .NET Framework 4.8, then rerun.'
    }
    $compiler
}

function Get-ShimSource {
    @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

internal static class Program
{
    private static readonly HashSet<string> CompatibleToolNames = new HashSet<string>(StringComparer.Ordinal)
    {
        "automation_update",
        "create_thread",
        "fork_thread",
        "handoff_thread",
        "send_message_to_thread"
    };

    private static int Main(string[] args)
    {
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);

        if (args.Length == 1 && args[0] == "--shim-self-test")
        {
            return RunSelfTest();
        }

        string realCodex;
        try
        {
            realCodex = ResolveRealCodexPath();
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("Codex compatibility shim could not locate the real Codex CLI: " + error.Message);
            return 127;
        }

        bool appServer = Array.IndexOf(args, "app-server") >= 0;
        return appServer ? RunAppServerProxy(realCodex, args) : RunPassThrough(realCodex, args);
    }

    private static int RunAppServerProxy(string realCodex, string[] args)
    {
        Process child = StartChild(realCodex, args, true);
        Thread input = new Thread(delegate() { PumpInput(child); });
        Thread output = new Thread(delegate() { PumpOutput(child.StandardOutput, Console.Out); });
        Thread error = new Thread(delegate() { PumpOutput(child.StandardError, Console.Error); });
        input.IsBackground = true;
        output.IsBackground = true;
        error.IsBackground = true;
        input.Start();
        output.Start();
        error.Start();
        child.WaitForExit();
        try { child.StandardInput.Close(); } catch { }
        output.Join();
        error.Join();
        int exitCode = child.ExitCode;
        child.Dispose();
        return exitCode;
    }

    private static void PumpInput(Process child)
    {
        try
        {
            string line;
            while (!child.HasExited && (line = Console.ReadLine()) != null)
            {
                child.StandardInput.WriteLine(RewriteTurnStart(line));
                child.StandardInput.Flush();
            }
        }
        catch (IOException) { }
        catch (InvalidOperationException) { }
        finally
        {
            try { child.StandardInput.Close(); } catch { }
        }
    }

    private static void PumpOutput(StreamReader reader, TextWriter writer)
    {
        try
        {
            string line;
            while ((line = reader.ReadLine()) != null)
            {
                writer.WriteLine(line);
                writer.Flush();
            }
        }
        catch (IOException) { }
    }

    private static string RewriteTurnStart(string line)
    {
        JavaScriptSerializer serializer = NewSerializer();
        Dictionary<string, object> request;
        try
        {
            request = serializer.DeserializeObject(line) as Dictionary<string, object>;
        }
        catch
        {
            return line;
        }
        if (request == null) { return line; }

        object methodValue;
        object paramsValue;
        if (!request.TryGetValue("method", out methodValue) || !String.Equals(methodValue as string, "turn/start", StringComparison.Ordinal) ||
            !request.TryGetValue("params", out paramsValue)) { return line; }

        Dictionary<string, object> parameters = paramsValue as Dictionary<string, object>;
        if (parameters == null) { return line; }
        object inputValue;
        object toolOutputValue;
        if (!parameters.TryGetValue("input", out inputValue) || !parameters.TryGetValue("toolOutput", out toolOutputValue)) { return line; }
        IList input = inputValue as IList;
        Dictionary<string, object> toolOutput = toolOutputValue as Dictionary<string, object>;
        if (input == null || input.Count != 0 || toolOutput == null) { return line; }

        object namespaceValue;
        object nameValue;
        object outputValue;
        if (!toolOutput.TryGetValue("namespace", out namespaceValue) || !String.Equals(namespaceValue as string, "codex_app", StringComparison.Ordinal) ||
            !toolOutput.TryGetValue("name", out nameValue) || !CompatibleToolNames.Contains(nameValue as string ?? String.Empty) ||
            !toolOutput.TryGetValue("output", out outputValue) || !(outputValue is string)) { return line; }

        Dictionary<string, object> textInput = new Dictionary<string, object>();
        textInput["type"] = "text";
        textInput["text"] = (string)outputValue;
        textInput["text_elements"] = new object[0];
        parameters["input"] = new object[] { textInput };
        parameters.Remove("toolOutput");
        return serializer.Serialize(request);
    }

    private static JavaScriptSerializer NewSerializer()
    {
        JavaScriptSerializer serializer = new JavaScriptSerializer();
        serializer.MaxJsonLength = Int32.MaxValue;
        serializer.RecursionLimit = 512;
        return serializer;
    }

    private static int RunPassThrough(string realCodex, string[] args)
    {
        Process child = StartChild(realCodex, args, false);
        child.WaitForExit();
        int exitCode = child.ExitCode;
        child.Dispose();
        return exitCode;
    }

    private static Process StartChild(string realCodex, string[] args, bool redirect)
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = realCodex;
        start.Arguments = JoinArguments(args);
        start.UseShellExecute = false;
        start.CreateNoWindow = redirect;
        start.RedirectStandardInput = redirect;
        start.RedirectStandardOutput = redirect;
        start.RedirectStandardError = redirect;
        start.EnvironmentVariables["CODEX_CLI_PATH"] = realCodex;
        start.EnvironmentVariables["CODEX_REAL_CLI_PATH"] = realCodex;
        if (redirect)
        {
            start.StandardOutputEncoding = new UTF8Encoding(false);
            start.StandardErrorEncoding = new UTF8Encoding(false);
        }
        Process child = Process.Start(start);
        if (child == null) { throw new InvalidOperationException("The real Codex CLI did not start."); }
        return child;
    }

    private static string ResolveRealCodexPath()
    {
        string current = Process.GetCurrentProcess().MainModule.FileName;
        string explicitPath = Environment.GetEnvironmentVariable("CODEX_REAL_CLI_PATH");
        if (IsUsableRealCli(explicitPath, current)) { return Path.GetFullPath(explicitPath); }

        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenAI", "Codex", "bin");
        if (!Directory.Exists(root)) { throw new DirectoryNotFoundException(root); }
        string best = null;
        DateTime bestTime = DateTime.MinValue;
        foreach (string candidate in Directory.GetFiles(root, "codex.exe", SearchOption.AllDirectories))
        {
            if (!IsUsableRealCli(candidate, current)) { continue; }
            DateTime modified = File.GetLastWriteTimeUtc(candidate);
            if (best == null || modified > bestTime) { best = candidate; bestTime = modified; }
        }
        if (best == null) { throw new FileNotFoundException("No real codex.exe was found below " + root + "."); }
        return Path.GetFullPath(best);
    }

    private static bool IsUsableRealCli(string candidate, string current)
    {
        if (String.IsNullOrWhiteSpace(candidate) || !File.Exists(candidate)) { return false; }
        return !String.Equals(Path.GetFullPath(candidate), Path.GetFullPath(current), StringComparison.OrdinalIgnoreCase);
    }

    private static string JoinArguments(string[] args)
    {
        StringBuilder joined = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) { joined.Append(' '); }
            joined.Append(QuoteArgument(args[i]));
        }
        return joined.ToString();
    }

    private static string QuoteArgument(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) { return value; }
        StringBuilder quoted = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value)
        {
            if (character == '\\') { slashes++; continue; }
            if (character == '"')
            {
                quoted.Append('\\', slashes * 2 + 1);
                quoted.Append('"');
                slashes = 0;
                continue;
            }
            quoted.Append('\\', slashes);
            slashes = 0;
            quoted.Append(character);
        }
        quoted.Append('\\', slashes * 2);
        quoted.Append('"');
        return quoted.ToString();
    }

    private static int RunSelfTest()
    {
        const string source = "{\"id\":1,\"method\":\"turn/start\",\"params\":{\"threadId\":\"thread\",\"input\":[],\"toolOutput\":{\"name\":\"send_message_to_thread\",\"namespace\":\"codex_app\",\"output\":\"<codex_delegation>test</codex_delegation>\"}}}";
        string rewritten = RewriteTurnStart(source);
        Dictionary<string, object> request = NewSerializer().DeserializeObject(rewritten) as Dictionary<string, object>;
        Dictionary<string, object> parameters = request == null ? null : request["params"] as Dictionary<string, object>;
        IList input = parameters == null ? null : parameters["input"] as IList;
        Dictionary<string, object> text = input == null || input.Count != 1 ? null : input[0] as Dictionary<string, object>;
        bool ok = parameters != null && !parameters.ContainsKey("toolOutput") && text != null &&
            String.Equals(text["text"] as string, "<codex_delegation>test</codex_delegation>", StringComparison.Ordinal);
        Console.WriteLine(ok ? "Codex compatibility shim self-test passed." : "Codex compatibility shim self-test failed.");
        return ok ? 0 : 1;
    }
}
'@
}

function Build-Shim {
    param([string] $OutputPath)
    $compiler = Get-FrameworkCompiler
    $directory = Split-Path $OutputPath -Parent
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $sourcePath = Join-Path $directory ('shim-' + [Guid]::NewGuid().ToString('N') + '.cs')
    [IO.File]::WriteAllText($sourcePath, (Get-ShimSource), [Text.UTF8Encoding]::new($false))
    try {
        $compilerOutput = & $compiler /nologo /target:exe /optimize+ /platform:anycpu /reference:System.Web.Extensions.dll "/out:$OutputPath" $sourcePath 2>&1
        if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($OutputPath)) {
            throw "Shim compilation failed: $($compilerOutput -join [Environment]::NewLine)"
        }
    } finally {
        if ([IO.File]::Exists($sourcePath)) { [IO.File]::Delete($sourcePath) }
    }
}

function Assert-Shim {
    param([string] $Path, [switch] $RequireRealCli)
    $selfTest = & $Path --shim-self-test 2>&1
    if ($LASTEXITCODE -ne 0 -or ($selfTest -join ' ') -notlike '*self-test passed*') {
        throw "Shim self-test failed: $($selfTest -join ' ')"
    }
    if ($RequireRealCli) {
        $version = & $Path --version 2>&1
        if ($LASTEXITCODE -ne 0 -or ($version -join ' ') -notmatch 'codex-cli\s+\S+') {
            throw "Shim could not launch the real Codex CLI: $($version -join ' ')"
        }
        $version -join ' '
    }
}

function Broadcast-EnvironmentChange {
    if (-not ('CodexAzureEnvironmentBroadcast' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CodexAzureEnvironmentBroadcast {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint message, UIntPtr wParam, string lParam, uint flags, uint timeout, out UIntPtr result);
}
'@
    }
    $result = [UIntPtr]::Zero
    [void][CodexAzureEnvironmentBroadcast]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref] $result)
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This compatibility fix supports native Windows Codex only.'
}

$CodexHome = Resolve-NativeCodexHome $CodexHome
$installDirectory = Join-Path $CodexHome 'compat\azure-task-transport'
$shimPath = Join-Path $installDirectory 'codex-azure-task-transport-shim.exe'
$manifestPath = Join-Path $installDirectory 'install-manifest.json'

if ($Action -eq 'Test') {
    Write-Step 'Compiling compatibility shim in a temporary directory'
    $testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('codex-azure-task-transport-test-' + [Guid]::NewGuid().ToString('N'))
    try {
        $testShim = Join-Path $testDirectory 'shim.exe'
        Build-Shim $testShim
        Assert-Shim $testShim
        Write-Ok 'Compilation and rewrite self-test passed; no Codex files or environment values were changed.'
    } finally {
        if ([IO.Directory]::Exists($testDirectory)) { [IO.Directory]::Delete($testDirectory, $true) }
    }
    return
}

if ($Action -eq 'Status') {
    Write-Step 'Checking Codex Azure task transport compatibility fix'
    $configured = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    if ([IO.File]::Exists($shimPath)) {
        Assert-Shim $shimPath
        Write-Ok "Installed shim passes its rewrite self-test: $shimPath"
    } else { Write-Warn "Shim is not installed at $shimPath" }
    if ($configured -eq $shimPath) { Write-Ok 'The user CODEX_CLI_PATH selects this shim.' }
    elseif ([string]::IsNullOrWhiteSpace($configured)) { Write-Warn 'The user CODEX_CLI_PATH is not set.' }
    else { Write-Warn "The user CODEX_CLI_PATH points elsewhere: $configured" }
    return
}

if ($Action -eq 'Uninstall') {
    Write-Step 'Removing Codex Azure task transport compatibility fix'
    $current = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    if (-not [string]::IsNullOrWhiteSpace($current) -and $current -ne $shimPath) {
        throw "CODEX_CLI_PATH points somewhere else; refusing to overwrite it: $current"
    }
    $previous = $null
    if ([IO.File]::Exists($manifestPath)) {
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 1) { throw 'The install manifest version is not supported.' }
        $previous = $manifest.previousUserCodexCliPath
    }
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $previous, 'User')
    $env:CODEX_CLI_PATH = $previous
    Broadcast-EnvironmentChange
    if ([IO.Directory]::Exists($installDirectory)) { [IO.Directory]::Delete($installDirectory, $true) }
    Write-Ok 'Compatibility shim removed and the previous user CODEX_CLI_PATH restored.'
    Write-Warn 'Fully quit every Codex window and tray process, then reopen Codex.'
    return
}

Write-Step 'Building Codex Azure task transport compatibility shim'
$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('codex-azure-task-transport-install-' + [Guid]::NewGuid().ToString('N'))
try {
    $temporaryShim = Join-Path $temporaryDirectory 'shim.exe'
    Build-Shim $temporaryShim
    Assert-Shim $temporaryShim

    $current = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'User')
    $existingManifest = $null
    if ([IO.File]::Exists($manifestPath)) {
        $existingManifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        if ($existingManifest.schemaVersion -ne 1) { throw 'The existing install manifest version is not supported.' }
    }
    if (-not $existingManifest -and -not [string]::IsNullOrWhiteSpace($current) -and $current -ne $shimPath -and -not $Force) {
        throw "A user CODEX_CLI_PATH already exists: $current. Review it, then rerun with -Force to preserve and replace it."
    }

    [IO.Directory]::CreateDirectory($installDirectory) | Out-Null
    $stagedShim = Join-Path $installDirectory ('.shim-stage-' + [Guid]::NewGuid().ToString('N') + '.exe')
    [IO.File]::Copy($temporaryShim, $stagedShim, $true)
    if ([IO.File]::Exists($shimPath)) {
        $backup = "$shimPath.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([Guid]::NewGuid().ToString('N'))"
        [IO.File]::Replace($stagedShim, $shimPath, $backup, $true)
    } else { [IO.File]::Move($stagedShim, $shimPath) }

    $previous = if ($existingManifest) { $existingManifest.previousUserCodexCliPath } else { $current }
    $manifest = [ordered]@{
        schemaVersion = 1
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        shimPath = $shimPath
        previousUserCodexCliPath = $previous
    } | ConvertTo-Json
    $manifestStage = Join-Path $installDirectory ('.manifest-stage-' + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($manifestStage, $manifest, [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($manifestPath)) {
        $manifestBackup = "$manifestPath.bak-$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))-$([Guid]::NewGuid().ToString('N'))"
        [IO.File]::Replace($manifestStage, $manifestPath, $manifestBackup, $true)
    } else { [IO.File]::Move($manifestStage, $manifestPath) }

    $realVersion = Assert-Shim $shimPath -RequireRealCli
    [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH', $shimPath, 'User')
    $env:CODEX_CLI_PATH = $shimPath
    Broadcast-EnvironmentChange
    Write-Ok "Installed and selected the compatibility shim: $shimPath"
    Write-Ok "Real CLI passthrough verified: $realVersion"
    Write-Warn 'Fully quit every Codex window and tray process, then reopen Codex.'
    Write-Warn 'Already-corrupted task histories need a separate backed-up repair or a fresh task; this installer prevents new malformed injections.'
} finally {
    if ([IO.Directory]::Exists($temporaryDirectory)) { [IO.Directory]::Delete($temporaryDirectory, $true) }
}
