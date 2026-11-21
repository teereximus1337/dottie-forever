export type Point = { x: number; y: number };
export type Graph = {
  version: 1;
  mic: { mode: "default" | "device"; uid?: string };
  assistant: { bundle_id: string };
  apps: { bundle_id: string }[];
  routes: {
    mic_to_apps: boolean;
    mic_to_assistant: boolean;
    assistant_to_apps: boolean;
    apps_to_assistant: string[];
  };
  positions: Record<string, Point>;
  output: { mode: "system" };
  voice_detection: boolean;
};
export type Level = { rms: number; peak: number };
export type EventLogStatus = {
  active: boolean;
  queued: number;
  written: number;
  dropped: number;
  errors: number;
  detector_events_dropped?: number;
};
export type EventDiagnostics = {
  controller?: EventLogStatus;
  host?: EventLogStatus;
};
export type AppInfo = {
  bundle_id: string;
  name: string;
  installed?: boolean;
  running?: boolean;
  audio_available?: boolean;
  pids?: number[];
};
export type Device = { uid: string; name: string };
export type Settings = {
  graph?: Graph;
  voice_detection?: boolean;
  mic_uid?: string;
  discord_bundle?: string;
  dot_bundle?: string;
  names?: { discord: string; alexa: string };
  phrases?: { wake: string; standby: string };
};
export type ReferenceInfo = {
  name: string;
  edition: string;
  status?: "migration_pending" | "verified_snapshot";
  version: string | null;
  record_count: number | null;
  built_at: string | null;
  verified_at: string | null;
  site_url: string;
  plugin_id: string;
  tools: string[];
};
export type Catalog = {
  ok: true;
  inputs: Device[];
  outputs: Device[];
  defaults: {
    input_uid?: string;
    output_uid?: string;
    input_name?: string;
    output_name?: string;
  };
  apps: AppInfo[];
  settings: Settings;
  components?: { host: boolean; voice_detector: boolean };
  endpoints?: Device[];
  reference?: ReferenceInfo;
};
export type Snapshot = {
  ok: true;
  mode: "live" | "synthetic";
  gate: "open" | "closed";
  health?: Record<string, boolean>;
  resolved_input?: Device;
  frames?: number;
  names?: { discord: string; alexa: string };
  phrases?: { wake: string; standby: string };
  active_graph?: Graph;
  graph_revision?: string | number;
  active_graph_revision?: string;
  recovery_message?: string;
  detector?: { enabled: boolean; healthy: boolean; error?: string };
  meters?: Record<string, number>;
  meter_levels?: {
    mic: Level;
    assistant: Level;
    apps: Record<string, Level>;
    to_apps: Level;
    to_assistant: Level;
    listener: Level;
  };
  errors?: Record<string, number>;
  diagnostics?: EventDiagnostics;
};
export type BridgeReply = {
  ok: boolean;
  error?: { message?: string };
  message?: string;
  device_name_warning?: string;
  phrase_activation?: "active" | "saved_detection_off" | "saved_routing_off" | "saved_test_mode" | "saved_listener_not_ready";
} & Partial<Omit<Catalog & Snapshot, "ok">>;
declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        router?: {
          postMessage: (
            command: Record<string, unknown>,
          ) => Promise<BridgeReply>;
        };
      };
    };
  }
}
