// provider-mirror - give cloned providers the same registry metadata as the
// provider they were cloned from.
//
// WHY THIS EXISTS
// ---------------
// A provider entry is exactly one baseURL plus one API key. A second Azure
// region therefore HAS to be its own provider id (`openai-2`), and that is the
// whole problem: opencode resolves models.dev metadata BY PROVIDER ID.
//
//   openai/gpt-5.6-sol     -> reasoning, 6 effort levels, text+image+pdf,
//                             1.05M context, 128K output, cost tiers, fast/pro
//   openai-2/gpt-5.6-sol   -> nothing. Falls back to guessed defaults:
//                             context 200_000, output 64_000, no reasoning,
//                             text-only input.
//
// Two of those are silent and expensive. A 200K context on a 1.05M model makes
// isOverflow() fire compaction at a fifth of the real window, so the clone
// shreds and re-summarises sessions for no reason - and compaction REPLACES
// history, so the damage is invisible and unrecoverable. "No reasoning" simply
// removes the effort dropdown from the picker.
//
// Hand-copying the registry block into opencode.jsonc fixes it once and then
// rots. Effort levels, pricing tiers and context windows all change remotely -
// that is the entire reason models.dev exists, and why new models appear in the
// picker on their own.
//
// So instead: at startup, copy the metadata from the SOURCE provider's registry
// entry onto the clone, touching nothing but `models`. The clone keeps its own
// `options` (its baseURL and key) and tracks upstream automatically. Adding a
// third region later costs one config block and zero code.
//
// CONVENTION 1: CLONE PROVIDERS
// -----------------------------
// A provider id ending in `-<N>` is read as clone N of the id before it:
//
//   openai-2    -> openai,     display names get " #2"
//   anthropic-3 -> anthropic,  display names get " #3"
//
// A provider whose base id is not in the registry is left completely alone, so
// unrelated ids that merely happen to end in a digit are never touched.
//
// CONVENTION 2: MODEL ALIASES VIA `family`
// ----------------------------------------
// Clone mirroring assumes the deployment is named after its models.dev id. Azure
// Foundry does not guarantee that and will not always let a deployment be
// renamed: `FW-Kimi-K3` serves what models.dev publishes as `kimi-k3`.
//
// opencode cannot be told those are the same model, because ONE config field
// carries both meanings:
//
//     const existingModel = parsed.models[model.id ?? modelID]   // metadata key
//     const apiID         = model.id ?? existingModel?.api.id ?? modelID
//
// Setting `id` to reach the metadata sends the wrong string on the wire; leaving
// it alone sends the right string and finds no metadata. Config alone cannot
// separate them.
//
// So: on a provider that IS in the registry, a declared model whose id is NOT
// published upstream is mirrored from `family`, read as the upstream model id.
//
//   "moonshotai": { "models": { "FW-Kimi-K3": { "family": "kimi-k3" } } }
//
// The config key stays the deployment name and goes out on the wire untouched;
// the metadata comes from `kimi-k3`. `family` is a real schema field holding a
// true value - models.dev reports family="kimi-k3" for this model - so the file
// stays valid and meaningful with this plugin absent. A bespoke key is not an
// option: config models are additionalProperties:false, and one unknown key
// hard-fails the entire config.
//
// Only models MISSING from the registry are considered, so a `family` that
// coincides with some other model id can never hijack a model upstream already
// publishes. A `family` naming nothing in the registry is left as declared.
//
// ORDERING
// --------
// opencode runs plugin `config` hooks BEFORE it resolves cfg.provider, so what
// this writes is indistinguishable from values typed into opencode.jsonc by
// hand. (Same window the kiro-parity retry guard uses to inject its fetch.)
//
// Registry values deliberately WIN over hand-written ones. Stale pins in the
// config must not be able to mask an upstream change; those pins exist only as
// a fallback for when this plugin is absent or the cache is unreadable, and the
// one that matters is `limit`.
//
// The cache is refreshed by opencode itself, not by this plugin, so a brand-new
// upstream model or a changed limit can land one launch late. That is the
// accepted trade - it buys us zero network I/O and zero startup latency here.
//
// TWO SCHEMAS, NOT ONE  (learned the hard way - do not "simplify" this)
// ---------------------------------------------------------------------
// The registry entry and the config entry are DIFFERENT SCHEMAS that happen to
// share most field names. Copying one wholesale into the other hard-fails config
// validation and takes the ENTIRE config down with it - every provider, not just
// the clone:
//
//   Expected boolean | undefined, got {"modes":{...}}
//     at ["provider"]["openai-2"]["models"]["gpt-5.6-luna"]["experimental"]
//
//   * `experimental` is an OBJECT in the registry ({modes:{fast,pro}}) and a
//     BOOLEAN in config. Straight type conflict.
//   * config models are `additionalProperties: false`, so registry-only keys
//     (description, reasoning_options, structured_output, knowledge,
//     last_updated, open_weights) are rejected too - `experimental` was simply
//     the first one the validator reached.
//   * `cost` is ALSO additionalProperties:false and the registry ships a
//     `tiers` array it does not accept. Nested filtering is required, not just
//     top-level.
//
// Hence the explicit allowlists below, taken from the published schema at
// https://opencode.ai/config.json ($defs.ProviderConfig.properties.models).
// Anything not on a list is dropped; adding a field is a deliberate act.
//
// NOT RECOVERABLE THIS WAY: `reasoning_options` - the per-model effort levels -
// is registry-only with no config equivalent. Config `variants` only accepts
// `{disabled:boolean}`, so it can hide a variant that already exists but never
// declare one. The clone therefore gets `reasoning: true` (the capability flag)
// while the effort DROPDOWN stays registry-driven, and so absent for a custom
// provider id.
//
// FAILURE MODE: total no-op. Every path is wrapped; an unreadable or malformed
// cache leaves the clone exactly as opencode.jsonc declared it.

import { appendFileSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { declaredModelIds, deriveCloneModel, parseCloneId } from "./provider-derivation.mjs"

const REGISTRY_PATH = join(homedir(), ".cache", "opencode", "models.json")

// The desktop app swallows plugin stderr, so a stderr-only channel is invisible
// exactly where this is hardest to debug. Same reasoning as anthropic-thinking.
const LOG_DIR = join(homedir(), ".local", "share", "opencode", "log")
const LOG_FILE = join(LOG_DIR, "provider-mirror.log")
const LOG_MAX_BYTES = 2_000_000

/**
 * Keys a config model entry may contain. Source: opencode config schema,
 * $defs.ProviderConfig.properties.models.additionalProperties.properties.
 * `experimental` is deliberately EXCLUDED - config wants a boolean, the registry
 * gives an object, and the flag carries nothing worth having.
 */
const MODEL_ALLOW = new Set([
  "id",
  "name",
  "family",
  "release_date",
  "attachment",
  "reasoning",
  "temperature",
  "tool_call",
  "interleaved",
  "cost",
  "limit",
  "modalities",
])

/**
 * `interleaved` names the response field carrying reasoning text. Dropping it is
 * not cosmetic: for a config-declared model the host falls back to `false` unless
 * the api id contains "deepseek", so a Kimi or GLM deployment silently renders no
 * thinking at all.
 *
 * Always normalised to the OBJECT form. The published schema lists a bare string
 * as legal, but config validation on 1.18.4 accepts only `true | object |
 * undefined` and hard-fails the whole file on a string - so the one shape both
 * builds accept is the only one worth emitting.
 */
function toConfigInterleaved(src: unknown): unknown {
  if (typeof src === "boolean") return src
  if (typeof src === "string") return { field: src }
  if (src && typeof src === "object" && !Array.isArray(src)) {
    const field = (src as Record<string, unknown>).field
    if (typeof field === "string") return { field }
  }
  return undefined
}

/** `cost` is additionalProperties:false; the registry's `tiers` is not allowed. */
const COST_ALLOW = new Set(["input", "output", "cache_read", "cache_write", "context_over_200k"])
const COST_TIER_ALLOW = new Set(["input", "output", "cache_read", "cache_write"])
/** `limit` is additionalProperties:false, and requires context + output. */
const LIMIT_ALLOW = new Set(["context", "input", "output"])
/** `modalities` entries are a closed enum. */
const MODALITY_ALLOW = new Set(["text", "audio", "image", "video", "pdf"])

/** A usable `models` map: a plain object, not null and not an array. */
function isModelMap(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function pick(source: any, allowed: Set<string>): Record<string, any> {
  const out: Record<string, any> = {}
  for (const [k, v] of Object.entries(source ?? {})) if (allowed.has(k) && v !== undefined) out[k] = v
  return out
}

/** Reduce a registry model entry to something the config schema will accept. */
function toConfigModel(src: any): Record<string, any> {
  const out = pick(src, MODEL_ALLOW)

  if (src?.cost && typeof src.cost === "object") {
    const cost = pick(src.cost, COST_ALLOW)
    if (cost.context_over_200k) cost.context_over_200k = pick(cost.context_over_200k, COST_TIER_ALLOW)
    // input+output are required by the schema; a partial cost is worse than none.
    if (typeof cost.input === "number" && typeof cost.output === "number") out.cost = cost
    else delete out.cost
  }

  if (src?.limit && typeof src.limit === "object") {
    const limit = pick(src.limit, LIMIT_ALLOW)
    if (typeof limit.context === "number" && typeof limit.output === "number") out.limit = limit
    else delete out.limit
  }

  if (src?.interleaved !== undefined) {
    const interleaved = toConfigInterleaved(src.interleaved)
    if (interleaved === undefined) delete out.interleaved
    else out.interleaved = interleaved
  }

  if (src?.modalities && typeof src.modalities === "object") {
    const mod: Record<string, any> = {}
    for (const dir of ["input", "output"]) {
      const list = src.modalities[dir]
      if (Array.isArray(list)) mod[dir] = list.filter((x: unknown) => typeof x === "string" && MODALITY_ALLOW.has(x))
    }
    out.modalities = mod
  }

  return out
}

function log(...parts: unknown[]): void {
  try {
    mkdirSync(LOG_DIR, { recursive: true })
    try {
      if (statSync(LOG_FILE).size > LOG_MAX_BYTES) writeFileSync(LOG_FILE, "")
    } catch {
      // no existing file to rotate
    }
    appendFileSync(LOG_FILE, `${new Date().toISOString()} pid=${process.pid} ${parts.map(String).join(" ")}\n`)
  } catch {
    // logging must never break startup
  }
}

export default async function providerMirror() {
  return {
    config: async (config: any): Promise<void> => {
      try {
        const providers = config?.provider
        if (!providers || typeof providers !== "object") return

        const cloneIds = Object.keys(providers).filter((id) => parseCloneId(id) !== undefined)
        // Alias candidates are the rest: a plain provider id that the registry
        // knows, carrying models the registry does not.
        const aliasIds = Object.keys(providers).filter((id) => parseCloneId(id) === undefined)
        if (cloneIds.length === 0 && aliasIds.length === 0) return

        let registry: any
        try {
          registry = JSON.parse(readFileSync(REGISTRY_PATH, "utf8"))
        } catch (err) {
          // Cache missing on a first-ever launch, or mid-write. Config pins stand.
          log("registry unreadable, providers left as declared:", (err as Error).message)
          return
        }

        for (const providerId of aliasIds) {
          const source = registry?.[providerId]
          if (!isModelMap(source?.models)) continue // not a registry provider; nothing to alias from
          const provider = providers[providerId]
          if (!isModelMap(provider?.models)) continue

          const applied: string[] = []
          const unresolved: string[] = []

          for (const modelId of declaredModelIds(provider)) {
            // Upstream publishes this id: the clone/native path already resolves
            // it. Aliasing would be a no-op at best and a hijack at worst.
            if (Object.hasOwn(source.models, modelId)) continue

            const own = provider.models[modelId] ?? {}
            const aliasId = own.family
            if (typeof aliasId !== "string" || aliasId === modelId) continue

            const src = Object.hasOwn(source.models, aliasId) ? source.models[aliasId] : undefined
            if (!src || typeof src !== "object" || Array.isArray(src)) {
              // `family` names nothing upstream. It is still a legitimate family
              // label, so say so and leave the declared entry untouched.
              unresolved.push(`${modelId}<-${aliasId}`)
              continue
            }

            provider.models[modelId] = {
              ...own, // hand-written fallback fields
              // `id` is pinned to the config key, never to the alias: it is the
              // string that goes on the wire. This is the entire point.
              ...toConfigModel({ ...src, id: modelId }),
              // A configured name is a local display label, not stale model
              // metadata. Keep it so distinct Azure deployments remain
              // distinguishable in OpenCode's model picker.
              ...(typeof own.name === "string" ? { name: own.name } : {}),
            }
            applied.push(`${modelId}<-${aliasId}`)
          }

          if (applied.length || unresolved.length) {
            log(
              `${providerId}: aliased [${applied.join(", ")}]` +
                (unresolved.length ? ` | unresolved (not in registry): [${unresolved.join(", ")}]` : ""),
            )
          }
        }

        for (const cloneId of cloneIds) {
          const parsed = parseCloneId(cloneId)
          if (!parsed) continue
          const { baseId, index } = parsed

          const source = registry?.[baseId]
          if (!source || typeof source.models !== "object" || source.models === null || Array.isArray(source.models)) {
            log(`skip ${cloneId} - no registry provider "${baseId}"`)
            continue
          }

          const clone = providers[cloneId]
          if (!clone || typeof clone.models !== "object" || clone.models === null || Array.isArray(clone.models)) {
            log(`skip ${cloneId} - no models map to mirror onto`)
            continue
          }

          const applied: string[] = []
          const missing: string[] = []

          for (const modelId of declaredModelIds(clone)) {
            const src = Object.hasOwn(source.models, modelId) ? source.models[modelId] : undefined
            if (!src || typeof src !== "object" || Array.isArray(src)) {
              // Deployed under a name upstream does not publish. Keep the hand
              // written entry verbatim - it is the only metadata that exists.
              missing.push(modelId)
              continue
            }
            const own = clone.models[modelId] ?? {}
            const derived = deriveCloneModel(src, modelId, index)
            clone.models[modelId] = {
              ...own, // hand-written fallback fields
              ...toConfigModel(derived), // registry wins, but only schema-legal keys
            }
            applied.push(modelId)
          }

          log(
            `${cloneId} <- ${baseId}: mirrored [${applied.join(", ")}]` +
              (missing.length ? ` | left as declared (not in registry): [${missing.join(", ")}]` : ""),
          )
        }
      } catch (err) {
        log("mirror failed, config untouched:", (err as Error).stack ?? String(err))
      }
    },
  }
}
