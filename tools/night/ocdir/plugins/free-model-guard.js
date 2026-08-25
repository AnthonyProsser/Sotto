import { readFileSync } from "fs"
import { join } from "path"

const FALLBACK = "opencode/x-preview-f-free"

function loadAllowed(directory) {
  const candidates = [
    join(directory, "tools/night/allowlist.txt"),
    join(directory, "allowlist.txt"),
  ]
  for (const path of candidates) {
    try {
      const text = readFileSync(path, "utf8")
      const ids = text
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line && !line.startsWith("#"))
      if (ids.length) return new Set(ids)
    } catch {
      // try the next path
    }
  }
  return new Set([FALLBACK])
}

function asModelId(value) {
  if (!value) return null
  if (typeof value === "string") return value
  if (typeof value === "object") {
    if (typeof value.providerID === "string" && typeof value.id === "string") {
      return `${value.providerID}/${value.id}`
    }
    if (typeof value.providerID === "string" && typeof value.modelID === "string") {
      return `${value.providerID}/${value.modelID}`
    }
    if (typeof value.model === "string") return value.model
  }
  return null
}

function collectModels(node, into, depth = 0) {
  if (node == null || depth > 6) return
  if (Array.isArray(node)) {
    for (const item of node) collectModels(item, into, depth + 1)
    return
  }
  if (typeof node === "object") {
    for (const [key, value] of Object.entries(node)) {
      if (/^(model|modelID|modelId)$/i.test(key)) {
        const id = asModelId(value)
        if (id) into.add(id)
      } else if (value && typeof value === "object") {
        collectModels(value, into, depth + 1)
      }
    }
  }
}

export const FreeModelGuard = async ({ directory }) => {
  const allowed = loadAllowed(directory)
  const reject = (model) => {
    throw new Error(`Refusing non-allowlisted model: ${model}`)
  }
  return {
    event: async ({ event }) => {
      const found = new Set()
      collectModels(event, found)
      for (const model of found) {
        if (!allowed.has(model)) reject(model)
      }
    },
    "experimental.chat.system.transform": async (input, output) => {
      const model = asModelId(input?.model) || asModelId(output?.model)
      if (model && !allowed.has(model)) reject(model)
    },
  }
}
