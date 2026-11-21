import type { Graph, Settings, Level } from "./types";
export const SILENT: Level = { rms: 0, peak: 0 };
export const CHATGPT_BUNDLE = "com.openai.codex";
export const DISCORD_BUNDLE = "com.hnc.Discord";
export const MAX_APPS = 1;
export function db(value: number): number {
  return Number.isFinite(value) && value > 0
    ? Math.max(-96, Math.min(0, 20 * Math.log10(value)))
    : -96;
}
export function meterPercent(value: number): number {
  return Math.max(0, Math.min(100, ((db(value) + 60) / 60) * 100));
}
export function formatDb(value: number): string {
  return value > 0 && Number.isFinite(value)
    ? `${db(value).toFixed(1)} dBFS`
    : "Silent";
}
export function profileGraph(graph: Graph): Graph {
  const next = structuredClone(graph);
  next.assistant = { bundle_id: CHATGPT_BUNDLE };
  next.apps = next.apps.some((app) => app.bundle_id === DISCORD_BUNDLE)
    ? [{ bundle_id: DISCORD_BUNDLE }]
    : [];
  next.routes.apps_to_assistant =
    next.apps.length && next.routes.apps_to_assistant.includes(DISCORD_BUNDLE)
      ? [DISCORD_BUNDLE]
      : [];
  if (!next.apps.length) {
    next.routes.mic_to_apps = false;
    next.routes.assistant_to_apps = false;
  }
  const kept = new Set([
    "mic",
    "assistant",
    "reference",
    "output",
    appNode(DISCORD_BUNDLE),
  ]);
  next.positions = Object.fromEntries(
    Object.entries(next.positions).filter(([id]) => kept.has(id)),
  );
  return next;
}
export function migrate(settings: Settings = {}): Graph {
  if (settings.graph?.version === 1) return profileGraph(settings.graph);
  const hasDiscord = settings.discord_bundle === DISCORD_BUNDLE;
  return {
    version: 1,
    mic: settings.mic_uid
      ? { mode: "device", uid: settings.mic_uid }
      : { mode: "default" },
    assistant: { bundle_id: CHATGPT_BUNDLE },
    apps: hasDiscord ? [{ bundle_id: DISCORD_BUNDLE }] : [],
    routes: {
      mic_to_apps: hasDiscord,
      mic_to_assistant: true,
      assistant_to_apps: hasDiscord,
      apps_to_assistant: hasDiscord ? [DISCORD_BUNDLE] : [],
    },
    positions: {},
    output: { mode: "system" },
    voice_detection: settings.voice_detection !== false,
  };
}
export function routingKey(graph: Graph): string {
  // Native dictionaries can arrive in any key order; layout and an irrelevant
  // default-input UID do not change the audio contract.
  return JSON.stringify({
    version: graph.version,
    mic: {
      mode: graph.mic.mode,
      uid: graph.mic.mode === "device" ? graph.mic.uid || "" : "",
    },
    assistant: graph.assistant.bundle_id,
    apps: graph.apps.map((app) => app.bundle_id).sort(),
    routes: {
      mic_to_apps: graph.routes.mic_to_apps,
      mic_to_assistant: graph.routes.mic_to_assistant,
      assistant_to_apps: graph.routes.assistant_to_apps,
      apps_to_assistant: [...graph.routes.apps_to_assistant].sort(),
    },
    output: graph.output.mode,
    voice_detection: graph.voice_detection,
  });
}
export function appNode(id: string): string {
  return `app:${id}`;
}
export function routeForConnection(
  c: {
    source: string | null;
    target: string | null;
    sourceHandle?: string | null;
    targetHandle?: string | null;
  },
  graph: Graph,
): string | null {
  if (
    c.source === "mic" &&
    c.sourceHandle === "out" &&
    c.target === appNode(DISCORD_BUNDLE) &&
    graph.apps.some((a) => a.bundle_id === DISCORD_BUNDLE) &&
    c.targetHandle === "in"
  )
    return "mic_to_apps";
  if (
    c.source === "mic" &&
    c.sourceHandle === "out" &&
    c.target === "assistant" &&
    c.targetHandle === "in"
  )
    return "mic_to_assistant";
  if (
    c.source === "assistant" &&
    c.sourceHandle === "out" &&
    c.target === appNode(DISCORD_BUNDLE) &&
    graph.apps.some((a) => a.bundle_id === DISCORD_BUNDLE) &&
    c.targetHandle === "in"
  )
    return "assistant_to_apps";
  if (
    c.target === "assistant" &&
    c.targetHandle === "in" &&
    c.source === appNode(DISCORD_BUNDLE) &&
    c.sourceHandle === "out" &&
    graph.apps.some((a) => appNode(a.bundle_id) === c.source)
  )
    return `app:${c.source!.slice(4)}`;
  return null;
}
export function setRoute(graph: Graph, route: string, enabled: boolean): Graph {
  const next = structuredClone(graph);
  if (route.startsWith("app:")) {
    const id = route.slice(4);
    if (!next.apps.some((a) => a.bundle_id === id)) return graph;
    next.routes.apps_to_assistant = enabled
      ? Array.from(new Set([...next.routes.apps_to_assistant, id]))
      : next.routes.apps_to_assistant.filter((a) => a !== id);
  } else if (
    ["mic_to_apps", "mic_to_assistant", "assistant_to_apps"].includes(route)
  )
    next.routes[
      route as "mic_to_apps" | "mic_to_assistant" | "assistant_to_apps"
    ] = enabled;
  return next;
}
export function addApp(graph: Graph, bundle_id: string): Graph {
  if (
    bundle_id !== DISCORD_BUNDLE ||
    bundle_id === graph.assistant.bundle_id ||
    graph.apps.some((a) => a.bundle_id === bundle_id) ||
    graph.apps.length >= MAX_APPS
  )
    return graph;
  return {
    ...graph,
    apps: [...graph.apps, { bundle_id }],
    routes: { ...graph.routes, mic_to_apps: true, assistant_to_apps: true },
  };
}
export function removeApp(graph: Graph, id: string): Graph {
  const next = structuredClone(graph);
  next.apps = next.apps.filter((a) => a.bundle_id !== id);
  next.routes.apps_to_assistant = next.routes.apps_to_assistant.filter(
    (a) => a !== id,
  );
  delete next.positions[appNode(id)];
  if (id === DISCORD_BUNDLE) {
    next.routes.mic_to_apps = false;
    next.routes.assistant_to_apps = false;
  }
  return next;
}
export function validateGraph(graph: Graph): string[] {
  const errors: string[] = [];
  if (graph.mic.mode === "device" && !graph.mic.uid)
    errors.push("Choose a microphone or follow the system default.");
  if (graph.assistant.bundle_id !== CHATGPT_BUNDLE)
    errors.push("Dottie Forever uses ChatGPT as its assistant.");
  if (graph.apps.some((app) => app.bundle_id !== DISCORD_BUNDLE))
    errors.push(
      "Only optional Discord voice can be connected. Game audio stays in headphones.",
    );
  if (
    !graph.apps.length &&
    (graph.routes.mic_to_apps || graph.routes.assistant_to_apps)
  )
    errors.push("Add Discord before connecting its input.");
  if (graph.apps.length > MAX_APPS) errors.push(`Add up to ${MAX_APPS} apps.`);
  if (graph.apps.some((a) => a.bundle_id === graph.assistant.bundle_id))
    errors.push("The assistant cannot feed its own listener.");
  if (new Set(graph.apps.map((a) => a.bundle_id)).size !== graph.apps.length)
    errors.push("Each app can appear once.");
  if (
    graph.routes.apps_to_assistant.some(
      (id) => !graph.apps.some((a) => a.bundle_id === id),
    )
  )
    errors.push("A connected app is missing.");
  return errors;
}
