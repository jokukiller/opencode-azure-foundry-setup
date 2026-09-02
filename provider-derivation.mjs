// @bun
// src/shared-derivation.ts
var CLONE_PATTERN = /^(.+)-(\d+)$/;
function parseCloneId(providerId) {
  const match = CLONE_PATTERN.exec(providerId);
  if (match === null)
    return;
  return { baseId: match[1], index: match[2] };
}
function declaredModelIds(providerConfig) {
  if (!isRecord(providerConfig))
    return [];
  const models = providerConfig["models"];
  if (!isRecord(models))
    return [];
  return Object.keys(models);
}
function cloneDisplayName(sourceName, index) {
  return `${sourceName} #${index}`;
}
function cloneProviderDisplayName(sourceName, baseId, index) {
  return cloneDisplayName(typeof sourceName === "string" ? sourceName : baseId, index);
}
function deriveCloneModel(source, modelId, index) {
  const derived = { ...source, id: modelId };
  if (typeof source.name === "string") {
    return { ...derived, name: cloneDisplayName(source.name, index) };
  }
  return derived;
}
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
export {
  parseCloneId,
  deriveCloneModel,
  declaredModelIds,
  cloneProviderDisplayName,
  cloneDisplayName,
  CLONE_PATTERN
};
