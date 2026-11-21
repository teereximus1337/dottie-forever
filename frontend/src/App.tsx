import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  ReactFlow,
  ReactFlowProvider,
  Background,
  Controls,
  ControlButton,
  BackgroundVariant,
  SelectionMode,
  type Connection,
  type NodeChangeset,
  useReactFlow,
} from "@xyflow/react";
import {
  AudioLines,
  Plus,
  RefreshCw,
  Settings2,
  Play,
  Square,
  X,
  ChevronRight,
  AlertCircle,
  Info,
  Mic,
  Sparkles,
  Headphones,
  Trash2,
  RotateCcw,
  LoaderCircle,
  MessageSquare,
  FolderOpen,
} from "lucide-react";
import {
  RouterNode,
  SignalEdge,
  Meter,
  type CanvasNode,
  type Signal,
  type RouterNodeData,
} from "./CanvasParts";
import { bridge, nativeAvailable, preview } from "./bridge";
import {
  migrate,
  routingKey,
  setRoute,
  routeForConnection,
  addApp,
  removeApp,
  appNode,
  validateGraph,
  SILENT,
  CHATGPT_BUNDLE,
  DISCORD_BUNDLE,
  profileGraph,
} from "./model";
import type { Graph, Catalog, Snapshot, Level, AppInfo, EventDiagnostics } from "./types";
const nodeTypes = { router: RouterNode };
const edgeTypes = { signal: SignalEdge };
const EMPTY: Graph = migrate();
const nameFor = (
  catalog: Catalog | null,
  id: string,
  fallback = "Choose an app",
) =>
  id === CHATGPT_BUNDLE
    ? "ChatGPT"
    : id === DISCORD_BUNDLE
      ? "Discord"
      : catalog?.apps.find((a) => a.bundle_id === id)?.name || id || fallback;
function usable(app: AppInfo | undefined) {
  return (
    !!app &&
    (app.audio_available === true ||
      (app.audio_available === undefined && !!app.pids?.length))
  );
}
function acceptSnapshot(result: unknown): Snapshot | null {
  const r = result as Snapshot;
  return r?.ok &&
    ["live", "synthetic"].includes(r.mode) &&
    ["open", "closed"].includes(r.gate)
    ? r
    : null;
}
const VIEW_PADDING = { top: 64, right: 70, bottom: 28, left: 70 };
function App() {
  const flow = useReactFlow<CanvasNode, Signal>();
  const startupDialog = useRef<HTMLDialogElement>(null);
  const startupDismiss = useRef<HTMLButtonElement>(null);
  const startButton = useRef<HTMLButtonElement>(null);
  const catalogBusy = useRef(false);
  const nodeMeasurements = useRef<
    Record<string, { width: number; height: number }>
  >({});
  const [catalog, setCatalog] = useState<Catalog | null>(null),
    [graph, setGraph] = useState<Graph>(EMPTY),
    [applied, setApplied] = useState<Graph | null>(null),
    [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [busy, setBusy] = useState<string | null>(null),
    [error, setError] = useState(""),
    [notice, setNotice] = useState(""),
    [phraseToast, setPhraseToast] = useState(""),
    [phraseError, setPhraseError] = useState(""),
    [startupError, setStartupError] = useState(""),
    [connectionIssue, setConnectionIssue] = useState<string | null>(null),
    [selected, setSelected] = useState<string | null>(null),
    [settings, setSettings] = useState(false);
  const [motion, setMotion] = useState(
      () => localStorage.getItem("router.reduceMotion") === "1",
    ),
    [names, setNames] = useState({
      discord: "Router · Apps",
      alexa: "Router · Assistant",
    }),
    [phrases, setPhrases] = useState({
      wake: "Hey Dot",
      standby: "Dot standby",
    });
  const [focusedRoute, setFocusedRoute] = useState<string | null>(null);
  const [eventDiagnostics, setEventDiagnostics] = useState<EventDiagnostics | null>(null);
  const [eventLogError, setEventLogError] = useState("");
  const settingsRef = useRef(settings);
  const graphRef = useRef(graph),
    busyRef = useRef(busy),
    snapshotRef = useRef(snapshot),
    mounted = useRef(true),
    polling = useRef(false),
    statusEpoch = useRef(0),
    audioMutation = useRef(false),
    pollNow = useRef<() => void>(() => {}),
    connectionFailed = useRef(false),
    draftInitialized = useRef(false),
    saveTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    settingsRef.current = settings;
  }, [settings]);
  useEffect(() => {
    graphRef.current = graph;
  }, [graph]);
  useEffect(() => {
    busyRef.current = busy;
  }, [busy]);
  useEffect(() => {
    snapshotRef.current = snapshot;
  }, [snapshot]);
  const live = !!snapshot,
    routingDirty = !!applied && routingKey(graph) !== routingKey(applied),
    draft = live && routingDirty;
  const hasNative = nativeAvailable() || preview;
  useEffect(() => {
    if (!settings || !hasNative) return;
    let active = true, inFlight = false;
    setEventDiagnostics(null);
    setEventLogError("");
    const poll = async () => {
      if (inFlight) return;
      inFlight = true;
      try {
        const response = await bridge({ op: "diagnostics" });
        if (active) {
          setEventDiagnostics(response.diagnostics || null);
          setEventLogError(response.diagnostics ? "" : "Event logging status is unavailable.");
        }
      } catch {
        if (active) {
          setEventDiagnostics(null);
          setEventLogError("Event logging status is unavailable.");
        }
      } finally { inFlight = false; }
    };
    void poll();
    const timer = setInterval(() => void poll(), 2000);
    return () => { active = false; clearInterval(timer); };
  }, [settings, hasNative]);
  const refresh = useCallback(async (initial = false, cached = false) => {
    if (catalogBusy.current) return;
    catalogBusy.current = true;
    try {
      const result = (await bridge({
        op: initial || cached ? "bootstrap" : "catalog",
      })) as Catalog;
      if (!mounted.current) return;
      result.outputs ??= [];
      result.defaults ??= {};
      result.apps ??= [];
      result.inputs ??= [];
      setCatalog(result);
      if (initial && !draftInitialized.current) {
        draftInitialized.current = true;
        const g = migrate(result.settings);
        setGraph(g);
        graphRef.current = g;
        setApplied(g);
        if (result.settings.names) setNames(result.settings.names);
        if (result.settings.phrases) setPhrases(result.settings.phrases);
      }
    } finally {
      catalogBusy.current = false;
    }
  }, []);
  const publishSnapshot = useCallback((next: Snapshot | null) => {
    snapshotRef.current = next;
    setSnapshot(next);
    if (next) {
      setConnectionIssue(null);
      if (next.active_graph) setApplied(next.active_graph);
    }
  }, []);
  useEffect(() => {
    mounted.current = true;
    if (!hasNative) return;
    void refresh(true).catch((e) => setError(e.message));
    const poll = async () => {
      // Status reads use the native cache; device discovery must never hold up
      // the gate indicator. Mutating commands fence older in-flight reads.
      if (polling.current || audioMutation.current) return;
      polling.current = true;
      const epoch = statusEpoch.current;
      const delayed = setTimeout(() => {
        if (mounted.current && epoch === statusEpoch.current) {
          if (snapshotRef.current) connectionFailed.current = true;
          publishSnapshot(null);
          setConnectionIssue("Checking connection");
        }
      }, 750);
      try {
        const result = acceptSnapshot(await bridge({ op: "status" }));
        if (!result) throw new Error("The audio engine returned no current status.");
        if (mounted.current && epoch === statusEpoch.current) {
          const previous = snapshotRef.current;
          // A native cached status sampled before a command must not roll its
          // confirmed gate state back while the next telemetry sample arrives.
          if (
            previous?.graph_revision === result.graph_revision &&
            previous?.frames !== undefined &&
            result.frames !== undefined &&
            result.frames < previous.frames
          ) return;
          publishSnapshot(result);
          if (!settingsRef.current) {
            if (result.names) setNames(result.names);
            if (result.phrases) setPhrases(result.phrases);
          }
          if (connectionFailed.current) {
            setError("");
            connectionFailed.current = false;
            setNotice("Audio connection restored.");
          }
        }
      } catch (e) {
        if (mounted.current && epoch === statusEpoch.current) {
          const message = (e as Error).message;
          if (snapshotRef.current || connectionFailed.current) {
            publishSnapshot(null);
            connectionFailed.current = true;
            setConnectionIssue(
              /Recovery paused/i.test(message)
                ? "Recovery paused"
                : "Connection interrupted",
            );
            setError(message);
          } else {
            setConnectionIssue(
              /Recovery paused/i.test(message)
                ? "Recovery paused"
                : "Routing stopped",
            );
            if (/Recovery|Reconnect|Waiting for/i.test(message)) setError(message);
          }
        }
      } finally {
        clearTimeout(delayed);
        polling.current = false;
      }
    };
    pollNow.current = () => void poll();
    const foreground = () => {
      if (document.visibilityState !== "hidden") void poll();
    };
    window.addEventListener("focus", foreground);
    document.addEventListener("visibilitychange", foreground);
    void poll();
    const timer = setInterval(() => void poll(), 50);
    const catalogTimer = setInterval(() => {
      if (!busyRef.current && draftInitialized.current)
        void refresh(false, true).catch(() => {});
    }, 4000);
    return () => {
      mounted.current = false;
      statusEpoch.current += 1;
      pollNow.current = () => {};
      window.removeEventListener("focus", foreground);
      document.removeEventListener("visibilitychange", foreground);
      clearInterval(timer);
      clearInterval(catalogTimer);
    };
  }, [refresh, hasNative, publishSnapshot]);
  const operate = useCallback(
    async (label: string, task: () => Promise<void>, changesAudio = true) => {
      if (busyRef.current) return;
      setBusy(label);
      busyRef.current = label;
      if (changesAudio) {
        audioMutation.current = true;
        statusEpoch.current += 1;
      }
      setError("");
      setNotice("");
      try {
        await task();
      } catch (e) {
        setError((e as Error).message);
      } finally {
        setBusy(null);
        busyRef.current = null;
        if (changesAudio) {
          statusEpoch.current += 1;
          audioMutation.current = false;
          pollNow.current();
        }
      }
    },
    [],
  );
  const saveDraft = useCallback(
    (next: Graph) => {
      setGraph(next);
      graphRef.current = next;
      setNotice("");
      if (saveTimer.current) clearTimeout(saveTimer.current);
      saveTimer.current = setTimeout(() => {
        if (hasNative)
          void bridge({ op: "save_graph", graph: graphRef.current }).catch(
            (e) => setError(`Draft could not be saved: ${e.message}`),
          );
      }, 400);
    },
    [hasNative],
  );
  useEffect(
    () => () => {
      if (saveTimer.current) clearTimeout(saveTimer.current);
    },
    [],
  );
  const apply = () =>
    operate("Applying changes", async () => {
      const submitted = structuredClone(graphRef.current);
      const errors = validateGraph(submitted);
      if (errors.length) throw Error(errors[0]);
      const result = await bridge({ op: "apply_graph", graph: submitted });
      const s = acceptSnapshot(result);
      publishSnapshot(s);
      setApplied(s?.active_graph || submitted);
      setNotice(
        result.device_name_warning ||
          (s
            ? "Changes applied. Assistant is on standby."
            : "Routing saved. Ready to start."),
      );
      void refresh().catch((e) => setError(e.message));
    });
  const toggleRun = () =>
    operate(live ? "Stopping" : "Starting", async () => {
      if (snapshotRef.current) {
        await bridge({ op: "shutdown" });
        publishSnapshot(null);
        connectionFailed.current = false;
        setConnectionIssue("Routing stopped");
        setNotice("Routing stopped. Sources and connections are editable.");
      } else {
        setStartupError("");
        const submitted = structuredClone(graphRef.current);
        let result;
        let s: Snapshot;
        try {
          const errors = validateGraph(submitted);
          if (errors.length) throw Error(errors[0]);
          result = await bridge({op: "start", mode: "live", graph: submitted});
          const current = acceptSnapshot(result);
          if (!current) throw Error("The audio engine did not confirm startup. Refresh sources, then try again.");
          s = current;
        } catch (failure) {
          const reason = (failure as Error).message;
          const guidance = /Open (?:com\.hnc\.Discord|Discord) to make its connected audio source/i.test(reason)
            ? "Discord is connected to ChatGPT here, but its voice audio isn’t available. Join a Discord voice channel and refresh sources, or disconnect Discord’s return to ChatGPT for solo use."
            : /Open the selected assistant’s audio session/i.test(reason)
              ? "Start a Dot voice call in ChatGPT and let it speak once, then refresh sources and try again."
              : reason || "The audio engine could not start. Check the selected microphone and app sessions, refresh sources, then try again.";
          setStartupError(guidance);
          return;
        }
        publishSnapshot(s);
        setApplied(s.active_graph || submitted);
        setNotice(
          result.device_name_warning ||
            "Routing started. Assistant is on standby.",
        );
        void refresh().catch((e) => setError(e.message));
      }
    });
  const toggleGate = () =>
    operate("Updating assistant", async () => {
      const r = acceptSnapshot(
        await bridge({
          op: snapshotRef.current?.gate === "open" ? "standby" : "wake",
        }),
      );
      if (r) publishSnapshot(r);
    });
  const setSelection = (id: string) => {
    setSelected(id);
    setFocusedRoute(null);
    setSettings(false);
  };
  const appStatus = (id: string) => {
    const a = catalog?.apps.find((a) => a.bundle_id === id);
    return usable(a)
      ? "Audio source available"
      : a?.running
        ? "Waiting for audio"
        : a?.installed
          ? "Open app to connect"
          : "Unavailable";
  };
  const active = snapshot?.gate === "open";
  const manualVoiceGate = catalog?.components?.voice_detector === false;
  const configuredNames = snapshot?.names ||
    catalog?.settings.names || {
      discord: "Router · Apps",
      alexa: "Router · Assistant",
    };
  const endpointNames = {
    discord:
      catalog?.endpoints?.find(
        (device) => device.uid === "ai.agentsofchange.router.device.discord.v1",
      )?.name || configuredNames.discord,
    alexa:
      catalog?.endpoints?.find(
        (device) => device.uid === "ai.agentsofchange.router.device.alexa.v1",
      )?.name || configuredNames.alexa,
  };
  const activePhrases =
    snapshot?.phrases || catalog?.settings.phrases || {
      wake: "Hey Dot",
      standby: "Dot standby",
    };
  useEffect(() => {
    if (!phraseToast) return;
    const timer = setTimeout(() => setPhraseToast(""), 4200);
    return () => clearTimeout(timer);
  }, [phraseToast]);
  const unhealthy =
    live &&
    Object.values(snapshot?.health || {}).some((value) => value === false);
  const sourceHealthy = (key: string) =>
    live && snapshot?.health?.[key] !== false;
  const level = (
    key: "mic" | "assistant" | "to_apps" | "to_assistant" | "listener",
    id?: string,
  ): Level => {
    if (!live) return SILENT;
    if (id) return snapshot?.meter_levels?.apps?.[id] || SILENT;
    const measured = snapshot?.meter_levels?.[key];
    if (measured) return measured;
    const old =
      key === "to_apps"
        ? "discord"
        : key === "to_assistant"
          ? "alexa"
          : key === "listener"
            ? "listener"
            : null;
    return old && snapshot?.meters?.[old] != null
      ? { rms: snapshot.meters[old], peak: snapshot.meters[old] }
      : SILENT;
  };
  const micName =
    graph.mic.mode === "default"
      ? catalog?.inputs.find((d) => d.uid === catalog.defaults?.input_uid)?.name
      : catalog?.inputs.find((d) => d.uid === graph.mic.uid)?.name;
  const outputName =
    catalog?.defaults?.output_name ||
    catalog?.outputs.find((d) => d.uid === catalog.defaults?.output_uid)
      ?.name ||
    "System default";
  const defaultUnavailable =
    graph.mic.mode === "default" && !!catalog && !micName;
  const capturedMic =
    snapshot?.resolved_input?.name || (!routingDirty ? micName : undefined);
  const visibleMic =
    live && !routingDirty && snapshot?.resolved_input?.name
      ? snapshot.resolved_input.name
      : micName;
  const feedDescription =
    [
      graph.routes.mic_to_apps ? "Microphone" : "",
      graph.routes.assistant_to_apps ? "assistant" : "",
    ]
      .filter(Boolean)
      .join(" + ") || "No audio sources connected";
  const hasDiscord = graph.apps.some((app) => app.bundle_id === DISCORD_BUNDLE);
  const chatGPT = catalog?.apps.find((app) => app.bundle_id === CHATGPT_BUNDLE);
  const nodes: CanvasNode[] = useMemo(() => {
    const make = (
      id: string,
      x: number,
      y: number,
      data: RouterNodeData,
    ): CanvasNode => ({
      id,
      type: "router",
      position: graph.positions[id] || { x, y },
      measured: nodeMeasurements.current[id],
      data,
      selected: selected === id,
      dragHandle: ".node-header",
      deletable: id === appNode(DISCORD_BUNDLE),
    });
    const assistantChanged =
      !!applied && applied.assistant.bundle_id !== CHATGPT_BUNDLE;
    const aiLevel = assistantChanged ? SILENT : level("assistant");
    const assistantState = !live
      ? connectionIssue ||
        (!catalog
          ? "Checking connection"
          : !chatGPT?.running
            ? "Open ChatGPT"
            : "Ready to connect")
      : assistantChanged
        ? "Source change pending"
        : !sourceHealthy("dot")
          ? "Source unavailable"
          : active
            ? aiLevel.rms > 0.001
              ? "Reply audio detected"
              : "Input open"
            : "Standby";
    const result: CanvasNode[] = [
      make("mic", 35, 80, {
        kind: "mic",
        title: defaultUnavailable
          ? "Default unavailable"
          : visibleMic || "Choose microphone",
        subtitle:
          graph.mic.mode === "default"
            ? "System default input"
            : "Selected physical input",
        status: live
          ? sourceHealthy("mic")
            ? "Connected"
            : "Unavailable"
          : "Not running",
        state:
          defaultUnavailable || (!sourceHealthy("mic") && live)
            ? "warning"
            : level("mic").rms > 0.001
              ? "active"
              : "idle",
        level: level("mic"),
        live,
        measured:
          !routingDirty ||
          (applied?.mic.mode === graph.mic.mode &&
            applied?.mic.uid === graph.mic.uid),
        onSelect: () => setSelection("mic"),
        defaultDevice:
          graph.mic.mode === "default" ? micName || "Unavailable" : undefined,
        pending: draft,
      }),
      make("reference", 35, 340, {
        kind: "reference",
        title: "Polestar",
        subtitle: "WoW Forever reference",
        status: "Not an audio source",
        state: "idle",
        level: SILENT,
        live: false,
        onSelect: () => setSelection("reference"),
        referenceDetail: "Set up in Dot",
        referenceCaption: "Reference lookups happen in your ChatGPT conversation.",
        referenceVerified: "Separate from audio routing",
      }),
      make("assistant", 400, 170, {
        kind: "assistant",
        title: "ChatGPT",
        subtitle: "Your WoW companion",
        status: assistantState,
        statusDetail: !live
          ? connectionIssue === "Checking connection"
            ? "Waiting for current audio status."
            : connectionIssue === "Recovery paused"
              ? "Start routing to retry the connection."
              : "Routing must be running before ChatGPT can hear you."
          : undefined,
        state:
          (!!connectionIssue && connectionIssue !== "Routing stopped") ||
          (!live && !chatGPT?.running) ||
          (live && !sourceHealthy("dot"))
            ? "warning"
            : active
              ? "active"
              : "gated",
        level: aiLevel,
        live: live && !assistantChanged,
        measured: !assistantChanged,
        gateOpen: active && !assistantChanged,
        onSelect: () => setSelection("assistant"),
        onGate: toggleGate,
        voice: graph.voice_detection,
        pending: draft,
      }),
      make("output", 790, 375, {
        kind: "output",
        title: outputName,
        subtitle: "System default output",
        status: "Native app playback",
        state: "idle",
        level: SILENT,
        live,
        onSelect: () => setSelection("output"),
      }),
    ];
    if (hasDiscord)
      result.push(
        make(appNode(DISCORD_BUNDLE), 790, 75, {
          kind: "app",
          title: "Discord",
          subtitle: feedDescription.replace("assistant", "ChatGPT"),
          status: appStatus(DISCORD_BUNDLE),
          state:
            level("to_apps").rms > 0.001
              ? "active"
              : graph.routes.apps_to_assistant.includes(DISCORD_BUNDLE) &&
                  !usable(
                    catalog?.apps.find((a) => a.bundle_id === DISCORD_BUNDLE),
                  )
                ? "warning"
                : "idle",
          level: level("to_apps"),
          live,
          measured: true,
          endpoint: endpointNames.discord,
          onSelect: () => setSelection(appNode(DISCORD_BUNDLE)),
          pending: draft,
          returnLevel: graph.routes.apps_to_assistant.includes(DISCORD_BUNDLE)
            ? level("mic", DISCORD_BUNDLE)
            : undefined,
          returnMeasured: !!snapshot?.meter_levels?.apps?.[DISCORD_BUNDLE],
        }),
      );
    return result;
  }, [
    graph, catalog, snapshot, selected, endpointNames.discord, draft, busy,
    connectionIssue,
  ]);
  const edges: Signal[] = useMemo(() => {
    const result: Signal[] = [];
    const add = (
      id: string,
      source: string,
      target: string,
      rms: number,
      gated = false,
      bypass = false,
    ) =>
      result.push({
        id,
        source,
        target,
        type: "signal",
        sourceHandle: "out",
        targetHandle: "in",
        data: {
          route: id,
          active: live && !draft && !gated && rms > 0.0001,
          gated,
          pending: draft,
          level: rms,
          label: gated ? "Standby · input closed" : "Audio route",
          bypass,
          returning: id.startsWith("app:"),
        },
        selected: focusedRoute === id,
      });
    if (hasDiscord && graph.routes.mic_to_apps)
      add(
        "mic_to_apps",
        "mic",
        appNode(DISCORD_BUNDLE),
        level("mic").rms,
        false,
        true,
      );
    if (graph.routes.mic_to_assistant)
      add("mic_to_assistant", "mic", "assistant", level("mic").rms, !active);
    if (hasDiscord && graph.routes.assistant_to_apps)
      add(
        "assistant_to_apps",
        "assistant",
        appNode(DISCORD_BUNDLE),
        level("assistant").rms,
      );
    if (hasDiscord && graph.routes.apps_to_assistant.includes(DISCORD_BUNDLE))
      add(
        `app:${DISCORD_BUNDLE}`,
        appNode(DISCORD_BUNDLE),
        "assistant",
        level("mic", DISCORD_BUNDLE).rms,
        !active,
      );
    result.push({
      id: "quest-data",
      source: "reference",
      target: "assistant",
      sourceHandle: "data",
      targetHandle: "knowledge",
      type: "signal",
      deletable: false,
      data: { active: false, knowledge: true, label: "WoW Forever reference" },
    });
    result.push({
      id: "external-playback",
      source: "assistant",
      target: "output",
      sourceHandle: "out",
      targetHandle: "playback",
      type: "signal",
      deletable: false,
      data: {
        active: false,
        external: true,
        label: "Native playback",
      },
    });
    return result;
  }, [graph, snapshot, draft, focusedRoute]);
  const connect = (connection: Connection) => {
    const route = routeForConnection(connection, graph);
    if (route) saveDraft(setRoute(graph, route, true));
    else
      setNotice(
        "Connect microphone, ChatGPT or Discord audio ports. Game audio stays in headphones.",
      );
  };
  const changeNodes = (changes: NodeChangeset<CanvasNode>) => {
    const positions = { ...graphRef.current.positions };
    let changed = false;
    let settled = false;
    for (const change of changes) {
      if (change.type === "dimensions" && change.dimensions) {
        // React Flow 13 resets handle measurements if rebuilt controlled nodes
        // omit them. Keep view geometry across frequent native meter updates.
        nodeMeasurements.current[change.id] = change.dimensions;
      }
      if (change.type === "position" && change.position) {
        positions[change.id] = change.position;
        changed = true;
        settled ||= change.dragging !== true;
      }
    }
    if (changed) {
      const next = { ...graphRef.current, positions };
      if (settled)
        saveDraft(next); // Includes keyboard moves, which have no drag-stop event.
      else {
        setGraph(next);
        graphRef.current = next;
      }
    }
  };
  const deleteEdges = (removed: Signal[]) => {
    let next = graph;
    for (const edge of removed)
      if (edge.data?.route) next = setRoute(next, edge.data.route, false);
    saveDraft(next);
    setFocusedRoute(null);
  };
  const deleteNodes = (removed: CanvasNode[]) => {
    let next = graph;
    for (const node of removed)
      if (node.id.startsWith("app:")) next = removeApp(next, node.id.slice(4));
    saveDraft(next);
    setSelected(null);
  };
  const chosenApp = selected?.startsWith("app:") ? selected.slice(4) : null;
  const closePanel = () => {
    setSettings(false);
    setSelected(null);
    setFocusedRoute(null);
  };
  useEffect(() => {
    const dialog = startupDialog.current;
    if (!dialog) return;
    if (startupError && !live && !dialog.open) {
      dialog.showModal();
      startupDismiss.current?.focus();
    } else if ((!startupError || live) && dialog.open) {
      dialog.close();
      startButton.current?.focus();
    }
  }, [startupError, live]);
  const inspectorOpen = settings || !!selected || !!focusedRoute;
  return (
    <div className={`app-shell ${motion ? "reduce-motion" : ""}`}>
      <header className="toolbar">
        <div className="brand">
          <h1>
            <span className="source-preview-wordmark">Dottie Forever</span>
          </h1>
        </div>
        <span className="toolbar-divider" />
        <div className={`connection-state ${live ? "online" : ""}`}>
          <span />
          {preview
            ? "Preview · simulated"
            : live
              ? "Routing live"
              : hasNative
                ? connectionIssue || "Checking connection"
                : "App not connected"}
        </div>
        <div className="toolbar-actions">
          <button
            className="tool-button add-button"
            disabled={!catalog || !!busy}
            onClick={() => {
              if (hasDiscord) setSelection(appNode(DISCORD_BUNDLE));
              else {
                saveDraft(addApp(graph, DISCORD_BUNDLE));
                setSelection(appNode(DISCORD_BUNDLE));
              }
            }}
          >
            {hasDiscord ? <MessageSquare size={16} /> : <Plus size={16} />}
            {hasDiscord ? "Discord setup" : "Add Discord"}
          </button>
          <button
            className={`icon-button ${busy === "Refreshing" ? "spinning" : ""}`}
            title="Refresh sources"
            aria-label="Refresh sources"
            disabled={!hasNative || !!busy}
            onClick={() =>
              void operate("Refreshing", async () => {
                await refresh();
                setNotice("Sources refreshed.");
              }, false)
            }
          >
            <RefreshCw size={16} />
          </button>
          <button
            className={`icon-button ${settings ? "selected" : ""}`}
            title="Settings"
            aria-label="Settings"
            onClick={() => {
              setSettings(!settings);
              setSelected(null);
              setFocusedRoute(null);
            }}
          >
            <Settings2 size={17} />
          </button>
          <button
            ref={startButton}
            className={`run-button ${live ? "running" : ""}`}
            disabled={!catalog || !!busy}
            onClick={() => void toggleRun()}
          >
            {busy === "Starting" || busy === "Stopping" ? (
              <LoaderCircle className="spin" size={15} />
            ) : live ? (
              <Square size={13} />
            ) : (
              <Play size={14} />
            )}
            <span>
              {busy === "Starting" || busy === "Stopping"
                ? `${busy}…`
                : live
                  ? "Stop routing"
                  : "Start routing"}
            </span>
          </button>
        </div>
      </header>
      <dialog
        ref={startupDialog}
        className="startup-dialog"
        aria-labelledby="startup-dialog-title"
        aria-describedby="startup-dialog-detail"
        onCancel={(event) => {
          event.preventDefault();
          setStartupError("");
        }}
      >
        <div className="startup-dialog-content">
          <Info className="startup-dialog-icon" size={28} aria-hidden="true" />
          <h2 id="startup-dialog-title">Couldn’t start routing</h2>
          <p id="startup-dialog-detail">{startupError}</p>
          <div className="startup-dialog-actions">
            <button ref={startupDismiss} className="tool-button" onClick={() => setStartupError("")}>
              Dismiss
            </button>
            <button
              className="primary-button"
              disabled={!hasNative || !!busy}
              onClick={() => void operate("Refreshing", async () => {
                await refresh();
                setStartupError("");
                setNotice("Sources refreshed. Try Start routing again.");
              }, false)}
            >
              {busy === "Refreshing" ? "Refreshing…" : "Refresh sources"}
            </button>
          </div>
        </div>
      </dialog>
      {preview && (
        <div className="preview-banner">
          <Info size={13} />
          Design preview with explicit sample data. No microphone or system
          audio is connected.
        </div>
      )}
      <main className={`workspace ${inspectorOpen ? "inspecting" : ""}`}>
        <section className="canvas-section" aria-label="Audio routing canvas">
          <div className="canvas-labels" aria-hidden="true">
            <span>
              <Mic size={12} />
              YOU & YOUR WORLD
            </span>
            <span>
              <Sparkles size={12} />
              CHATGPT
            </span>
            <span>
              <AudioLines size={12} />
              FRIENDS & AUDIO
            </span>
          </div>
          <ReactFlow<CanvasNode, Signal>
            key={catalog ? "ready" : "loading"}
            nodes={nodes}
            edges={edges}
            nodeTypes={nodeTypes}
            edgeTypes={edgeTypes}
            onNodesChange={changeNodes}
            onNodeDragStop={() => saveDraft(graphRef.current)}
            onNodesDelete={deleteNodes}
            onEdgesDelete={deleteEdges}
            onConnect={connect}
            isValidConnection={(c) => !!routeForConnection(c, graph)}
            onNodeClick={(_, node) => setSelection(node.id)}
            onEdgeClick={(_, edge) => {
              if (edge.data?.route) {
                setFocusedRoute(edge.data.route);
                setSelected(null);
                setSettings(false);
              }
            }}
            onPaneClick={() => {
              setSelected(null);
              setFocusedRoute(null);
            }}
            fitView
            fitViewOptions={{
              padding: VIEW_PADDING,
              minZoom: 0.35,
              maxZoom: 1,
            }}
            minZoom={0.35}
            maxZoom={1.75}
            selectionMode={SelectionMode.Partial}
            deleteKeyCode={["Backspace", "Delete"]}
            // Start at pointer-down so a drag with one move event retains that movement.
            nodeDragThreshold={0}
            nodesConnectable={!busy}
            forceColorMode="dark"
            proOptions={{ hideAttribution: false }}
            onlyRenderVisibleElements={false}
          >
            <Background
              variant={BackgroundVariant.Dots}
              gap={20}
              size={0.8}
              color="#363640"
            />
            <Controls
              fitViewOptions={{ padding: VIEW_PADDING, maxZoom: 1 }}
              showInteractive={false}
              position="bottom-left"
            >
              <ControlButton
                title="Reset node layout"
                aria-label="Reset node layout"
                onClick={() => {
                  saveDraft({ ...graph, positions: {} });
                  requestAnimationFrame(
                    () =>
                      void flow.fitView({ padding: VIEW_PADDING, maxZoom: 1 }),
                  );
                }}
              >
                <RotateCcw size={14} />
              </ControlButton>
            </Controls>
          </ReactFlow>
          {!catalog && (
            <div className="canvas-empty">
              <AudioLines size={25} />
              <h2>
                {hasNative
                  ? "Connecting to your audio…"
                  : "Your audio canvas is ready"}
              </h2>
              <p>
                {hasNative
                  ? "Loading devices and applications."
                  : "Open Dottie Forever on your Mac to connect ChatGPT and your microphone."}
              </p>
              {error && <p className="error-copy">{error}</p>}
            </div>
          )}
          {draft && (
            <div className="draft-bar">
              <span className="draft-indicator" />
              <div>
                <strong>Routing changes ready</strong>
                <span>Live audio follows the saved route until you apply.</span>
              </div>
              <button
                className="text-button"
                disabled={!!busy}
                onClick={() => {
                  if (applied)
                    saveDraft({
                      ...profileGraph(applied),
                      positions: graph.positions,
                    });
                }}
              >
                Discard
              </button>
              <button
                className="primary-button"
                disabled={!!busy}
                onClick={() => void apply()}
              >
                {busy === "Applying changes" ? "Applying…" : "Apply changes"}
              </button>
            </div>
          )}
        </section>
        {inspectorOpen && (
          <aside
            className="inspector"
            aria-label={settings ? "Settings" : "Selection settings"}
          >
            <div className="panel-heading">
              <div>
                <span className="eyebrow">
                  {settings ? "PREFERENCES" : "INSPECTOR"}
                </span>
                <h2>
                  {settings
                    ? "Settings"
                    : focusedRoute
                      ? "Audio connection"
                      : selected === "mic"
                        ? "Microphone"
                        : selected === "assistant"
                          ? "ChatGPT"
                            : selected === "reference"
                            ? "Polestar"
                            : selected === "output"
                              ? "Playback"
                              : nameFor(catalog, chosenApp || "")}
                </h2>
              </div>
              <button
                className="icon-button"
                aria-label="Close settings"
                onClick={closePanel}
              >
                <X size={17} />
              </button>
            </div>
            <div className="panel-content">
              {settings ? (
                <>
                  <div className="settings-section">
                    <h3>Virtual input names</h3>
                    <p>
                      These are the names you select inside your voice apps.
                    </p>
                    <label>
                      For Discord
                      <input
                        value={names.discord}
                        onChange={(e) =>
                          setNames({ ...names, discord: e.target.value })
                        }
                        maxLength={48}
                      />
                    </label>
                    <label>
                      For ChatGPT
                      <input
                        value={names.alexa}
                        onChange={(e) =>
                          setNames({ ...names, alexa: e.target.value })
                        }
                        maxLength={48}
                      />
                    </label>
                  </div>
                  <div className="settings-section">
                    <h3>Voice phrases</h3>
                    {manualVoiceGate && <p>Use the Wake and Standby buttons in this manual-gate build.</p>}
                    <label>
                      Wake phrase
                      <input
                        value={phrases.wake}
                        disabled={!!busy || manualVoiceGate}
                        onChange={(e) =>
                          setPhrases({ ...phrases, wake: e.target.value })
                        }
                        maxLength={64}
                      />
                    </label>
                    <label>
                      Standby phrase
                      <input
                        value={phrases.standby}
                        disabled={!!busy || manualVoiceGate}
                        onChange={(e) =>
                          setPhrases({ ...phrases, standby: e.target.value })
                        }
                        maxLength={64}
                      />
                    </label>
                    <button
                      className="primary-button wide"
                      disabled={!hasNative || !catalog || !!busy}
                      onClick={() =>
                        void operate("Saving settings", async () => {
                          setPhraseToast("");
                          setPhraseError("");
                          const next = {
                            wake: phrases.wake.trim().replace(/ +/g, " "),
                            standby: phrases.standby.trim().replace(/ +/g, " "),
                          };
                          try {
                            const response = await bridge({
                              op: "configure",
                              names,
                              phrases: next,
                            });
                            const saved = response.phrases;
                            if (!saved || saved.wake !== next.wake || saved.standby !== next.standby)
                              throw new Error("Could not confirm the saved phrases. Check settings before retrying.");
                            const current = acceptSnapshot(response);
                            if (current) publishSnapshot(current);
                            setPhrases(saved);
                            setCatalog(previous => previous && ({
                              ...previous, settings: {...previous.settings, phrases: saved, names: response.names ?? names},
                            }));
                            const messages = {
                              active: "New voice phrases active.",
                              saved_routing_off: "Phrases saved. They’ll apply when routing starts.",
                              saved_detection_off: "Phrases saved. Voice detection is off.",
                              saved_test_mode: "Phrases saved. Test mode is active.",
                              saved_listener_not_ready: "Phrases saved. Listener readiness isn’t confirmed.",
                            };
                            setPhraseToast(manualVoiceGate ? "Input names saved." : response.phrase_activation ? messages[response.phrase_activation] : "Phrases saved. Listener readiness isn’t confirmed.");
                            if (response.device_name_warning) setNotice(response.device_name_warning);
                          } catch (error) {
                            setPhraseError((error as Error).message);
                          }
                        })
                      }
                    >
                      {busy === "Saving settings" ? "Saving…" : manualVoiceGate ? "Save input names" : "Save names & phrases"}
                    </button>
                    {phraseError && <p className="helper phrase-error" role="alert">{phraseError}</p>}
                  </div>
                  <div className="settings-section">
                    <h3>Display</h3>
                    <label className="toggle-row">
                      <span>
                        Reduce motion
                        <small>
                          Keep levels visible without moving connections.
                        </small>
                      </span>
                      <input
                        type="checkbox"
                        checked={motion}
                        onChange={(e) => {
                          setMotion(e.target.checked);
                          localStorage.setItem(
                            "router.reduceMotion",
                            e.target.checked ? "1" : "0",
                          );
                        }}
                      />
                    </label>
                  </div>
                  <details className="advanced">
                    <summary>
                      Engine & diagnostics
                      <ChevronRight size={14} />
                    </summary>
                    <dl>
                      <dt>Engine</dt>
                      <dd>{snapshot?.mode || "Stopped"}</dd>
                      <dt>Sample rate</dt>
                      <dd>48 kHz</dd>
                      <dt>Processed frames</dt>
                      <dd>{snapshot?.frames?.toLocaleString() || "—"}</dd>
                      <dt>Graph revision</dt>
                      <dd>{snapshot?.graph_revision ?? "—"}</dd>
                    </dl>
                    {snapshot?.errors && (
                      <div className="diagnostic-lines">
                        {Object.entries(snapshot.errors).map(([key, value]) => (
                          <span key={key}>
                            {key}
                            <b>{value}</b>
                          </span>
                        ))}
                      </div>
                    )}
                    <div className="settings-section event-history">
                      <h3>Event history</h3>
                      <p>
                        Wake decisions, audio-feed changes and recovery, saved on
                        this Mac. No audio recordings or transcripts.
                      </p>
                      {preview && !nativeAvailable() ? (
                        <p className="helper">Preview only. No event files are written.</p>
                      ) : (
                        <>
                          <dl>
                            <dt>Controller log</dt>
                            <dd>{eventDiagnostics?.controller?.active ? "Active" : eventLogError ? "Unavailable" : eventDiagnostics ? "Unavailable" : hasNative ? "Checking…" : "App not connected"}</dd>
                            <dt>Audio log</dt>
                            <dd>{eventDiagnostics?.host?.active ? "Active" : eventDiagnostics?.host || live ? "Unavailable" : "Not connected"}</dd>
                          </dl>
                          {(eventLogError || Object.values(eventDiagnostics || {}).some(log => log.errors > 0 || log.dropped > 0 || (log.detector_events_dropped || 0) > 0)) && (
                            <p className="helper" role="status">
                              {eventLogError || "Some events could not be saved. This history may have gaps; audio routing is unaffected by logging errors."}
                            </p>
                          )}
                        </>
                      )}
                      <button
                        className="secondary-button wide"
                        disabled={!hasNative || !!busy}
                        onClick={() => void operate("Opening event logs", async () => {
                          const result = await bridge({ op: "open_event_logs" });
                          setNotice(result.message || "Event logs opened in Finder.");
                        }, false)}
                      >
                        <FolderOpen size={15} /> Show event logs
                      </button>
                      <p className="helper">Older events rotate automatically; at most 8 MiB is kept.</p>
                    </div>
                    {hasNative && <p className="helper">To install or remove the virtual inputs, follow the setup instructions in this checkout’s README.</p>}
                  </details>
                </>
              ) : focusedRoute ? (
                <>
                  <div className="inspector-callout">
                    <AudioLines size={17} />
                    <p>
                      This connection feeds the{" "}
                      {focusedRoute === "mic_to_apps" ||
                      focusedRoute === "assistant_to_apps"
                        ? "Discord input"
                        : "ChatGPT input"}
                      . Changes apply together.
                    </p>
                  </div>
                  <label className="toggle-row">
                    <span>Connection enabled</span>
                    <input
                      type="checkbox"
                      checked={
                        focusedRoute.startsWith("app:")
                          ? graph.routes.apps_to_assistant.includes(
                              focusedRoute.slice(4),
                            )
                          : graph.routes[
                              focusedRoute as keyof Omit<
                                Graph["routes"],
                                "apps_to_assistant"
                              >
                            ]
                      }
                      onChange={(e) =>
                        saveDraft(
                          setRoute(graph, focusedRoute, e.target.checked),
                        )
                      }
                    />
                  </label>
                  <button
                    className="danger-button"
                    onClick={() => {
                      saveDraft(setRoute(graph, focusedRoute, false));
                      setFocusedRoute(null);
                    }}
                  >
                    <Trash2 size={14} />
                    Remove connection
                  </button>
                </>
              ) : selected === "mic" ? (
                <>
                  <label>
                    Input source
                    <select
                      value={
                        graph.mic.mode === "default"
                          ? "default"
                          : graph.mic.uid || ""
                      }
                      onChange={(e) =>
                        saveDraft({
                          ...graph,
                          mic:
                            e.target.value === "default"
                              ? { mode: "default" }
                              : { mode: "device", uid: e.target.value },
                        })
                      }
                    >
                      <option value="default">Follow system default</option>
                      <optgroup label="Pin a microphone">
                        {catalog?.inputs.map((input) => (
                          <option value={input.uid} key={input.uid}>
                            {input.name}
                          </option>
                        ))}
                      </optgroup>
                    </select>
                  </label>
                  <div className="device-resolved">
                    <Mic size={17} />
                    <div>
                      <span>Currently using</span>
                      <strong>
                        {capturedMic || micName || "No available microphone"}
                      </strong>
                    </div>
                  </div>
                  {defaultUnavailable && (
                    <p className="error-copy" role="alert">
                      The macOS default
                      {catalog?.defaults.input_name
                        ? ` (${catalog.defaults.input_name})`
                        : ""}{" "}
                      is not an available physical microphone. Choose a physical
                      input in macOS or pin one here.
                    </p>
                  )}
                  <p className="helper">
                    Following the default uses the microphone selected in macOS.
                    Device changes reconnect on standby.
                  </p>
                  <Meter live={live} level={level("mic")} label="Microphone" />
                  <div className="settings-section">
                    <h3>Send microphone to</h3>
                    {hasDiscord && (
                      <RouteToggle
                        label="Discord"
                        checked={graph.routes.mic_to_apps}
                        onChange={(v) =>
                          saveDraft(setRoute(graph, "mic_to_apps", v))
                        }
                      />
                    )}
                    <RouteToggle
                      label="ChatGPT input"
                      checked={graph.routes.mic_to_assistant}
                      onChange={(v) =>
                        saveDraft(setRoute(graph, "mic_to_assistant", v))
                      }
                    />
                    <p className="helper">
                      The local wake listener remains ungated.
                    </p>
                  </div>
                </>
              ) : selected === "assistant" ? (
                <>
                  <div className="device-resolved">
                    <Sparkles size={19} />
                    <div>
                      <span>Voice assistant</span>
                      <strong>ChatGPT</strong>
                    </div>
                  </div>
                  {!chatGPT?.running && (
                    <p className="error-copy">
                      Open ChatGPT and start a voice conversation to make its
                      audio available.
                    </p>
                  )}
                  <p className="helper">
                    Select this microphone in ChatGPT's voice conversation.
                  </p>
                  <div className="endpoint-name">{endpointNames.alexa}</div>
                  <div className="assistant-status-detail">
                    <span
                      className={`tiny-dot ${active ? "active" : "gated"}`}
                    />
                    {!live
                      ? "Routing stopped"
                      : active
                        ? "Input open"
                        : "Input silent · standby"}
                  </div>
                  <p className="helper">
                    An open input confirms the router is sending audio. It
                    cannot confirm the app is listening or thinking.
                  </p>
                  {hasDiscord && (
                    <RouteToggle
                      label="Let Discord hear ChatGPT"
                      checked={graph.routes.assistant_to_apps}
                      onChange={(v) =>
                        saveDraft(setRoute(graph, "assistant_to_apps", v))
                      }
                    />
                  )}
                  {!manualVoiceGate && (
                    <>
                      <RouteToggle
                        label="Use voice phrases"
                        checked={graph.voice_detection}
                        onChange={(v) => saveDraft({ ...graph, voice_detection: v })}
                      />
                      <div className="phrase-preview">
                        <span>Wake <b>{activePhrases.wake}</b></span>
                        <span>Standby <b>{activePhrases.standby}</b></span>
                      </div>
                    </>
                  )}
                </>
              ) : selected === "reference" ? (
                <>
                  <p><strong>WoW Forever reference</strong></p>
                  <p>Set up your reference in the ChatGPT Dot conversation you use for voice. Dottie routes audio and doesn’t check whether a reference is connected.</p>
                  <p className="helper">The dashed line identifies a knowledge source, not an audio connection.</p>
                </>
              ) : selected === "output" ? (
                <>
                  <div className="device-resolved">
                    <Headphones size={19} />
                    <div>
                      <span>System default output</span>
                      <strong>{outputName}</strong>
                    </div>
                  </div>
                  <p>
                    World of Warcraft stays in your headphones. ChatGPT and
                    Discord also play through their normal selected outputs. Use
                    System Default to follow macOS.
                  </p>
                  <div className="inspector-callout">
                    <Info size={16} />
                    <p>
                      This is normal playback, not an extra copy created by the
                      router. Apps with a pinned output may use a different
                      device.
                    </p>
                  </div>
                </>
              ) : chosenApp ? (
                <>
                  <div className="app-availability">
                    <span
                      className={`tiny-dot ${usable(catalog?.apps.find((a) => a.bundle_id === chosenApp)) ? "active" : "warning"}`}
                    />
                    {appStatus(chosenApp)}
                  </div>
                  <label>
                    Use this microphone in {nameFor(catalog, chosenApp)}
                    <div className="endpoint-name">{endpointNames.discord}</div>
                  </label>
                  <p className="helper">
                    Choose this input in Discord. Friends hear your microphone
                    and ChatGPT according to the connections below. Game audio
                    stays out of this mix.
                  </p>
                  <RouteToggle
                    label="Let Discord hear my microphone"
                    checked={graph.routes.mic_to_apps}
                    onChange={(v) =>
                      saveDraft(setRoute(graph, "mic_to_apps", v))
                    }
                  />
                  <RouteToggle
                    label="Let Discord hear ChatGPT"
                    checked={graph.routes.assistant_to_apps}
                    onChange={(v) =>
                      saveDraft(setRoute(graph, "assistant_to_apps", v))
                    }
                  />
                  <RouteToggle
                    label="Let ChatGPT hear Discord voices"
                    checked={graph.routes.apps_to_assistant.includes(chosenApp)}
                    onChange={(v) =>
                      saveDraft(setRoute(graph, `app:${chosenApp}`, v))
                    }
                  />
                  <p className="helper">
                    This route closes on standby. The wake listener stays
                    available; assistant playback never returns to itself.
                  </p>
                  <Meter
                    live={live}
                    measured={!!snapshot?.meter_levels?.apps?.[chosenApp]}
                    level={level("mic", chosenApp)}
                    label={`${nameFor(catalog, chosenApp)} playback`}
                  />
                  <button
                    className="danger-button"
                    onClick={() => {
                      saveDraft(removeApp(graph, chosenApp));
                      setSelected(null);
                    }}
                  >
                    <Trash2 size={14} />
                    Remove Discord
                  </button>
                </>
              ) : null}
              {!settings && routingDirty && (
                <button
                  className="primary-button wide panel-apply"
                  disabled={!!busy}
                  onClick={() => void apply()}
                >
                  {live ? "Apply & reconnect" : "Save routing"}
                </button>
              )}
            </div>
          </aside>
        )}
      </main>
      <footer className="status-strip">
        <div
          className={`status-message ${error ? "has-error" : ""}`}
          role={error ? "alert" : "status"}
        >
          {error ? (
            <AlertCircle size={14} />
          ) : snapshot?.recovery_message ? (
            <RefreshCw size={14} />
          ) : (
            <span className={`tiny-dot ${live ? "active" : ""}`} />
          )}
          <span>
            {error ||
              snapshot?.recovery_message ||
              notice ||
              (live
                ? unhealthy
                  ? "Audio source unavailable · check selected devices and apps"
                  : "Audio engine healthy · routing selected sources"
                : hasNative
                  ? "Arrange your audio, then start routing."
                  : "Local app connection required.")}
          </span>
        </div>
        <div className="status-right">
          <span>{live ? "48 kHz" : "Local audio"}</span>
          <span>
            {snapshot?.detector?.healthy
              ? "Wake listener ready"
              : graph.voice_detection
                ? "Voice phrases enabled"
                : "Manual gate"}
          </span>
        </div>
      </footer>
      {phraseToast && <div className="phrase-toast" role="status">{phraseToast}</div>}
    </div>
  );
}
function RouteToggle({
  label,
  checked,
  onChange,
}: {
  label: string;
  checked: boolean;
  onChange: (v: boolean) => void;
}) {
  return (
    <label className="toggle-row">
      <span>{label}</span>
      <input
        type="checkbox"
        checked={checked}
        onChange={(e) => onChange(e.target.checked)}
      />
    </label>
  );
}
export default function RouterApp() {
  return (
    <ReactFlowProvider>
      <App />
    </ReactFlowProvider>
  );
}
