import assert from "node:assert/strict"
import { once } from "node:events"
import { readFile } from "node:fs/promises"
import { createServer } from "node:http"
import test from "node:test"
import openaiDeploymentMap from "./openai-deployment-map.ts"

const models = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.6-terra"]

test("setup probes canonical deployment names without suffixes", async () => {
  const source = await readFile(new URL("./Setup-AzureOpenCode.ps1", import.meta.url), "utf8")
  const table = source.match(/\$OpenAiModels = \[ordered\]@\{([\s\S]*?)\}/)?.[1]
  assert.ok(table, "OpenAI deployment table must exist")
  const mappings = [...table.matchAll(/"([^"]+)"\s*=\s*"([^"]+)"/g)]
    .map(([, model, deployment]) => [model, deployment])
  assert.deepEqual(Object.fromEntries(mappings), Object.fromEntries(models.map((model) => [model, model])))
})

test("mapper preserves unsuffixed model names on both API paths", async (t) => {
  // Use real HTTP requests so the test covers the installed fetch wrapper.
  const server = createServer(async (request, response) => {
    const chunks = []
    for await (const chunk of request) chunks.push(chunk)
    response.writeHead(200, { "content-type": "application/json" })
    response.end(Buffer.concat(chunks))
  })
  t.after(() => new Promise((resolve, reject) => {
    server.close((error) => error ? reject(error) : resolve())
    server.closeAllConnections()
  }))
  server.listen(0, "127.0.0.1")
  await once(server, "listening")

  const config = { provider: { openai: { options: {} } } }
  const plugin = await openaiDeploymentMap()
  await plugin.config(config)
  const baseURL = `http://127.0.0.1:${server.address().port}/openai/v1`

  for (const path of ["responses", "chat/completions"]) {
    for (const model of [...models, "unmapped-model"]) {
      const payload = path === "responses" ? { input: "hi" } : { messages: [{ role: "user", content: "hi" }] }
      const body = { model, ...payload }
      const response = await config.provider.openai.options.fetch(`${baseURL}/${path}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      })
      assert.equal(response.status, 200)
      assert.deepEqual(await response.json(), body, `${path}: ${model}`)
    }
  }
})
