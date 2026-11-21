import type { BridgeReply, Catalog, Graph, Snapshot } from "./types";
import { CHATGPT_BUNDLE, DISCORD_BUNDLE } from "./model";
export const preview =
  new URLSearchParams(location.search).get("preview") === "1";
const fixtureCatalog: Catalog = {
  ok: true,
  inputs: [{ uid: "preview-mic", name: "Studio microphone" }],
  outputs: [{ uid: "preview-output", name: "Headphones" }],
  defaults: { input_uid: "preview-mic", output_uid: "preview-output" },
  apps: [
    {
      bundle_id: CHATGPT_BUNDLE,
      name: "ChatGPT",
      installed: true,
      running: true,
      audio_available: true,
      pids: [1],
    },
    {
      bundle_id: DISCORD_BUNDLE,
      name: "Discord",
      installed: true,
      running: true,
      audio_available: true,
      pids: [2],
    },
  ],
  settings: {
    dot_bundle: CHATGPT_BUNDLE,
    discord_bundle: DISCORD_BUNDLE,
    names: { discord: "Router · Apps", alexa: "Router · Assistant" },
    phrases: { wake: "Hey Dot", standby: "Dot standby" },
  },
  components: { host: true, voice_detector: true },
  reference: {
    name: "Polestar",
    edition: "WoW Forever",
    status: "migration_pending",
    version: null,
    record_count: null,
    built_at: null,
    verified_at: null,
    site_url: "",
    plugin_id: "preview-reference",
    tools: [],
  },
};
let fixtureStatus: Snapshot | null = null;
export function nativeAvailable() {
  return !!window.webkit?.messageHandlers?.router;
}
export async function bridge(
  command: Record<string, unknown>,
): Promise<BridgeReply> {
  if (preview && !nativeAvailable()) {
    if (command.op === "bootstrap" || command.op === "catalog")
      return structuredClone(fixtureCatalog);
    if (command.op === "open_reference")
      return { ok: true, message: "Preview only. No reference was opened." };
    if (command.op === "diagnostics")
      return { ok: true, diagnostics: {} };
    if (command.op === "open_event_logs")
      return { ok: true, message: "Preview only. No event files are written or opened." };
    if (command.op === "save_graph") {
      fixtureCatalog.settings.graph = structuredClone(command.graph as Graph);
      return { ok: true };
    }
    if (command.op === "start" || command.op === "apply_graph") {
      const graph = command.graph as Graph;
      fixtureCatalog.settings.graph = structuredClone(graph);
      if (command.op === "start" || fixtureStatus)
        fixtureStatus = {
          ok: true,
          mode: "live",
          gate: "closed",
          frames: 0,
          health: { mic: true, discord: true, dot: true, controller: true },
          active_graph: graph,
          graph_revision: 1,
          detector: { enabled: true, healthy: true },
          names: fixtureCatalog.settings.names,
          phrases: fixtureCatalog.settings.phrases,
          meter_levels: {
            mic: { rms: 0.02, peak: 0.08 },
            assistant: { rms: 0, peak: 0 },
            apps: { [DISCORD_BUNDLE]: { rms: 0, peak: 0 } },
            to_apps: { rms: 0.01, peak: 0.04 },
            to_assistant: { rms: 0, peak: 0 },
            listener: { rms: 0.01, peak: 0.04 },
          },
        };
      return fixtureStatus || { ok: true };
    }
    if (command.op === "shutdown") {
      fixtureStatus = null;
      return { ok: true };
    }
    if (command.op === "wake" && fixtureStatus) fixtureStatus.gate = "open";
    if (command.op === "standby" && fixtureStatus)
      fixtureStatus.gate = "closed";
    if (command.op === "configure") {
      fixtureCatalog.settings.names =
        command.names as typeof fixtureCatalog.settings.names;
      fixtureCatalog.settings.phrases =
        command.phrases as typeof fixtureCatalog.settings.phrases;
      if (fixtureStatus) {
        fixtureStatus.names = fixtureCatalog.settings.names;
        fixtureStatus.phrases = fixtureCatalog.settings.phrases;
      }
      return fixtureStatus || { ok: true };
    }
    if (fixtureStatus) return structuredClone(fixtureStatus);
    throw new Error("Preview engine stopped.");
  }
  const handler = window.webkit?.messageHandlers?.router;
  if (!handler)
    throw new Error("Open Dottie Forever on this Mac to connect to live audio.");
  const result = await handler.postMessage(command);
  if (!result?.ok)
    throw new Error(
      result?.error?.message ||
        "The audio controller could not complete that action.",
    );
  return result;
}
