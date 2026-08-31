const MARK = Symbol.for("openai-deployment-map.fetch")

const DEPLOYMENTS: Record<string, string> = {
  "gpt-5.6-sol": "gpt-5.6-sol-1",
  "gpt-5.6-terra": "gpt-5.6-terra-1",
  "gpt-5.6-luna": "gpt-5.6-luna-1",
}

export default async function openaiDeploymentMap() {
  return {
    config: async (config: any) => {
      const options = config?.provider?.openai?.options
      if (!options || typeof options !== "object") return

      const upstream = typeof options.fetch === "function" ? options.fetch : globalThis.fetch
      if ((upstream as any)[MARK]) return

      const wrapped = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
        const request = input instanceof Request ? new Request(input, init) : new Request(input, init)
        if (!/\/(?:responses|chat\/completions)(?:\?|$)/.test(request.url)) return upstream(request)

        try {
          const body = JSON.parse(await request.clone().text())
          const deployment = DEPLOYMENTS[body?.model]
          if (!deployment) return upstream(request)

          const headers = new Headers(request.headers)
          headers.delete("content-length")
          return upstream(new Request(request, {
            body: JSON.stringify({ ...body, model: deployment }),
            headers,
          }))
        } catch {
          return upstream(request)
        }
      }

      Object.defineProperty(wrapped, MARK, { value: true })
      options.fetch = wrapped
    },
  }
}
