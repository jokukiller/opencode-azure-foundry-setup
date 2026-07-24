# OpenCode ↔ Azure AI Foundry setup

Configures [OpenCode](https://opencode.ai) to use Claude and GPT models hosted on
an Azure AI Foundry resource.

## Use

1. Install OpenCode (**1.18.5 or newer** — see [Versions](#versions)).
2. Get the resource key from whoever shared this with you. It is **not** in this
   repo and never should be.
3. Run:

   ```powershell
   .\Setup-AzureOpenCode.ps1
   ```

   It prompts for the key, or pass it with `-ApiKey`. Point at a different
   resource with `-Endpoint https://<name>.services.ai.azure.com`.

   **Run it from anywhere.** It does not matter which directory you are in and
   it is not per-project — see [Scope](#scope).

4. Restart OpenCode **fully**. Closing the window is not enough — the desktop
   keeps background processes alive:

   ```powershell
   Get-Process opencode, OpenCode -ErrorAction SilentlyContinue | Stop-Process -Force
   ```

5. Pick a model from the picker.

## Scope

**Global, not per-project.** Run the script from any directory — your Downloads
folder, wherever you cloned this, anywhere. It uses no relative paths and does
not care about the working directory.

It writes one file:

```
%USERPROFILE%\.config\opencode\opencode.json
```

That is OpenCode's **global** config, so every project on the machine gets the
models. You do not run it once per workspace, and you do not need to touch any
project's `opencode.json`.

How OpenCode resolves config, for reference:

| Scope | Path | Used for |
| --- | --- | --- |
| Global | `%USERPROFILE%\.config\opencode\opencode.json` | providers, keys, default models — **what this script writes** |
| Project | `<project>\opencode.json` | per-project overrides, plugins |

The two are **deep-merged**, with project overriding global. So a project can
still pin its own `model` or add plugins, and it keeps using the global provider
credentials. Nothing here interferes with existing project configs.

One consequence worth knowing: because the credentials are global, any project on
the machine can use the key. That is usually what you want, but it does mean the
key is not scoped to one repo.

## What it does

Validates the key, discovers which models are actually deployed, then writes
`~/.config/opencode/opencode.json`.

- Backs up any existing config first (`.bak-<timestamp>`).
- Writes **nothing** if the key is rejected or no deployment responds.
- Merges rather than replaces — your other settings, agents and MCP servers
  survive. An existing `model` choice is left alone.
- Safe to re-run.

Note: if your config is `.jsonc`, comments are lost on rewrite. The backup keeps
them.

## Why a script and not just a config snippet

The endpoint is easy to wire up wrong, and every failure is quiet rather than
loud.

**There are two API surfaces on one hostname**, sharing one key:

| Path | Protocol | Auth | OpenCode provider |
| --- | --- | --- | --- |
| `/anthropic/v1` | Anthropic Messages | `x-api-key` | `anthropic` |
| `/openai/v1` | OpenAI-compatible v1 | `Authorization: Bearer` | `openai` |

The obvious guess — OpenCode's built-in `azure` provider — is wrong. It speaks
the *classic* Azure protocol
(`/openai/deployments/<name>/chat/completions?api-version=...`) which this
resource does not expose. Correct key, correct resource, still fails. The fix is
to override the built-in `anthropic` and `openai` providers' `baseURL`.

**`small_model` must be set explicitly.** Overriding the built-in `anthropic`
provider makes OpenCode inherit Anthropic's default background model
(`claude-haiku-4-5`) for session titles and summaries. That model is not deployed
here, so every title request 404s — silently, with no error surfaced anywhere.
The symptom is just sessions that never get titles. The script sets this for you.

**Model ids are real models.dev ids**, so OpenCode inherits true context limits
(1M+) and reasoning effort levels automatically. No hand-written model
definitions needed.

## Gotchas

**The picker lists models this resource does not serve.** That is cosmetic, but
selecting one returns 404. Only the models the script reported are real.

**Writing curl by hand against `/openai/v1`?** Use `max_completion_tokens`, not
`max_tokens`. Azure's own generated sample still shows `max_tokens`, which these
models reject:

> `Unsupported parameter: 'max_tokens' is not supported with this model.`

For the Responses API it is `max_output_tokens`. The SDK handles this correctly;
it only bites hand-written requests.

## Versions

The **desktop app and the npm CLI are versioned separately** and drift apart.
If one behaves differently from the other, check both before debugging anything:

```powershell
(Get-Item "$env:LOCALAPPDATA\Programs\@opencode-aidesktop\OpenCode.exe").VersionInfo.ProductVersion
(Get-Content "$env:APPDATA\npm\node_modules\opencode-ai\package.json" -Raw | ConvertFrom-Json).version
```

**Use 1.18.5+.** Versions ≤ 1.18.4 fail to request visible reasoning traces for
model ids without a minor version — `claude-opus-5` matched nothing in their
version regex, so thinking happened and was billed but never displayed. Fixed in
1.18.5.

## Cost

Shared key means shared quota and one shared bill, with no per-user attribution.
Rough registry pricing per million tokens (input/output):

| Model | Cost |
| --- | --- |
| `claude-opus-5`, `gpt-5.6-sol` | $5 / $25–30 |
| `gpt-5.6-terra` | $2.50 / $15 |
| `gpt-5.6-luna` | $1 / $6 |

Context windows are ~1M tokens, so a runaway agent loop gets expensive quickly.
`gpt-5.6-luna` is the cheap default for background work, which is why the script
picks it for `small_model`.

## Security

Do not commit the key. Not to this repo, not to a private one — git history keeps
it after deletion, and private repos get cloned, forked and flipped public.

If you are the one sharing access: Azure resources issue **two keys** (key1 and
key2) that work identically. Hand out key2 and keep key1, so you can rotate
someone's access without breaking your own. For real isolation and separate
billing, give them their own resource or an Azure RBAC identity instead.
