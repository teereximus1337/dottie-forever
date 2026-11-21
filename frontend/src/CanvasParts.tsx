import { memo } from "react";
import {
  Handle,
  Position,
  BaseEdge,
  getBezierPath,
  getSmoothStepPath,
  EdgeLabelRenderer,
  type Node,
  type NodeProps,
  type Edge,
  type EdgeProps,
} from "@xyflow/react";
import {
  Mic,
  AudioLines,
  Sparkles,
  AppWindow,
  Headphones,
  SlidersHorizontal,
  Power,
  ArrowUpRight,
  BookOpen,
} from "lucide-react";
import type { Level } from "./types";
import { db, meterPercent, formatDb, SILENT } from "./model";
export type RouterNodeData = {
  kind: "mic" | "assistant" | "bus" | "app" | "output" | "reference";
  title: string;
  subtitle: string;
  status: string;
  statusDetail?: string;
  state: "idle" | "active" | "gated" | "warning";
  level: Level;
  live: boolean;
  gateOpen?: boolean;
  endpoint?: string;
  onSelect: () => void;
  onGate?: () => void;
  available?: boolean;
  voice?: boolean;
  defaultDevice?: string;
  pending?: boolean;
  measured?: boolean;
  referenceDetail?: string;
  referenceCaption?: string;
  referenceVerified?: string;
  returnLevel?: Level;
  returnMeasured?: boolean;
};
export type CanvasNode = Node<RouterNodeData, "router">;
export const Meter = memo(function Meter({
  level = SILENT,
  live,
  label,
  measured = true,
}: {
  level?: Level;
  live: boolean;
  label: string;
  measured?: boolean;
}) {
  const rms = live ? level.rms : 0;
  return (
    <div className="audio-meter" aria-label={label}>
      <div
        className="meter-track"
        role="meter"
        aria-label={`${label} level`}
        aria-valuemin={-60}
        aria-valuemax={0}
        aria-valuenow={Math.max(-60, db(rms))}
        aria-valuetext={
          !measured ? "Not measured" : live ? formatDb(rms) : "Not running"
        }
      >
        <div
          className="meter-fill"
          style={{ width: `${meterPercent(rms)}%` }}
        />
      </div>
      <span
        className={`meter-number ${level.peak >= 0.98 && live ? "clip" : ""}`}
      >
        {!live
          ? "—"
          : !measured
            ? "Not measured"
            : level.peak >= 0.98
              ? "CLIP"
              : formatDb(rms)}
      </span>
    </div>
  );
});
const icons = {
  mic: Mic,
  assistant: Sparkles,
  bus: AudioLines,
  app: AppWindow,
  output: Headphones,
  reference: BookOpen,
};
export const RouterNode = memo(function RouterNode({
  data,
  selected,
}: NodeProps<CanvasNode>) {
  const Icon = icons[data.kind];
  return (
    <article
      className={`router-node node-${data.kind} is-${data.state} ${selected ? "is-selected" : ""} ${data.pending ? "is-pending" : ""}`}
      aria-label={`${data.title}, ${data.status}`}
    >
      {(data.kind === "assistant" ||
        data.kind === "bus" ||
        data.kind === "app") && (
        <Handle
          type="target"
          position={Position.Left}
          id="in"
          aria-label={`${data.title} audio input`}
          className="port port-in"
        />
      )}
      {data.kind === "assistant" && (
        <Handle
          type="target"
          position={Position.Left}
          id="knowledge"
          style={{ top: "82%" }}
          isConnectable={false}
          className="port port-data"
          aria-label="ChatGPT reference knowledge"
        />
      )}
      {data.kind === "reference" && (
        <Handle
          type="source"
          position={Position.Right}
          id="data"
          isConnectable={false}
          className="port port-data"
          aria-label="Polestar data connection"
        />
      )}
      {data.kind === "output" && (
        <Handle
          type="target"
          position={Position.Left}
          id="playback"
          isConnectable={false}
          className="port port-external"
        />
      )}
      <div className="node-header">
        <div className="node-icon">
          <Icon size={20} strokeWidth={1.8} />
        </div>
        <div className="node-heading">
          <span className="node-role">
            {
              {
                mic: "Audio input",
                assistant: "Your companion",
                bus: "Shared app input",
                app: "Optional party voice",
                reference: "Knowledge source",
                output: "Playback output",
              }[data.kind]
            }
          </span>
          <h2 title={data.title}>{data.title}</h2>
        </div>
        <button
          className="node-menu nodrag"
          aria-label={`Configure ${data.title}`}
          onClick={(e) => {
            e.stopPropagation();
            data.onSelect();
          }}
        >
          <SlidersHorizontal size={15} />
        </button>
      </div>
      <div className="node-body">
        {data.kind === "assistant" ? (
          <>
            <div className={`assistant-state ${data.gateOpen ? "awake" : ""}`}>
              <span className="state-orb" />
              <div>
                <strong>{data.status}</strong>
                <small>
                  {data.statusDetail ||
                    (data.gateOpen
                      ? "Selected audio can reach the assistant."
                      : "Wake listener stays available.")}
                </small>
              </div>
            </div>
            <button
              className={`gate-button nodrag ${data.gateOpen ? "" : "wake"}`}
              disabled={!data.live || data.state === "warning"}
              onClick={(e) => {
                e.stopPropagation();
                data.onGate?.();
              }}
            >
              <Power size={13} />
              {data.gateOpen ? "Standby" : "Wake ChatGPT"}
            </button>
          </>
        ) : (
          <div className="node-caption">
            <span>{data.subtitle}</span>
            {data.kind === "output" ? (
              <ArrowUpRight size={13} />
            ) : (
              <span className={`tiny-dot ${data.state}`} />
            )}
          </div>
        )}
        {data.kind === "reference" && (
          <div className="reference-node-detail">
            <strong>{data.referenceDetail}</strong>
            <span>{data.referenceCaption}</span>
          </div>
        )}
        {(data.kind === "assistant" || data.kind === "app") && (
          <span className="meter-caption">
            {data.kind === "app" ? "To Discord" : "ChatGPT reply"}
          </span>
        )}
        {data.kind !== "output" && data.kind !== "reference" && (
          <Meter
            live={data.live}
            measured={data.measured}
            level={data.level}
            label={
              data.kind === "app"
                ? "To Discord"
                : data.kind === "assistant"
                  ? "ChatGPT reply"
                  : data.title
            }
          />
        )}
        {data.kind === "app" && data.returnLevel && (
          <>
            <span className="meter-caption return-caption">
              Friends' voices
            </span>
            <Meter
              live={data.live}
              measured={data.returnMeasured}
              level={data.returnLevel}
              label="Discord voices"
            />
          </>
        )}
        {data.kind === "output" && (
          <p className="external-note">
            WoW + voice playback<span>Game audio stays in headphones</span>
          </p>
        )}
      </div>
      <div className="node-footer">
        <span>
          {data.kind === "reference"
            ? data.referenceVerified
            : data.kind === "bus"
              ? "One feed · shared by connected apps"
              : data.kind === "assistant"
                ? data.voice
                  ? "Voice phrases enabled"
                  : "Manual wake / standby"
                : data.kind === "output"
                  ? "Follows macOS output"
                  : data.kind === "app"
                    ? `Input: ${data.endpoint}`
                    : data.defaultDevice
                      ? "Follows macOS input"
                      : "Pinned microphone"}
        </span>
        {data.pending && (
          <span className="pending-dot" title="Unapplied changes" />
        )}
      </div>
      {["mic", "assistant"].includes(data.kind) && (
        <Handle
          type="source"
          position={Position.Right}
          id="out"
          className="port port-out"
          aria-label={`${data.title} audio output`}
        />
      )}
      {data.kind === "bus" && (
        <Handle
          type="source"
          position={Position.Bottom}
          id="shared"
          isConnectable={false}
          className="port port-shared"
        />
      )}
      {data.kind === "app" && (
        <Handle
          type="source"
          position={Position.Left}
          id="out"
          style={{ top: "72%" }}
          className="port port-return"
          aria-label={`${data.title} playback output`}
        />
      )}
    </article>
  );
});
export type SignalData = {
  active: boolean;
  gated?: boolean;
  external?: boolean;
  shared?: boolean;
  pending?: boolean;
  label?: string;
  route?: string;
  level?: number;
  bypass?: boolean;
  returning?: boolean;
  knowledge?: boolean;
};
export type Signal = Edge<SignalData, "signal">;
export const SignalEdge = memo(function SignalEdge(props: EdgeProps<Signal>) {
  const {
    id,
    sourceX,
    sourceY,
    targetX,
    targetY,
    sourcePosition,
    targetPosition,
    data,
    selected,
  } = props;
  let [path, labelX, labelY] = data?.bypass
    ? getSmoothStepPath({
        sourceX,
        sourceY,
        targetX,
        targetY,
        sourcePosition,
        targetPosition,
        borderRadius: 18,
        offset: 30,
        centerY: Math.min(sourceY, targetY) - 130,
      })
    : getBezierPath({
        sourceX,
        sourceY,
        targetX,
        targetY,
        sourcePosition,
        targetPosition,
        curvature: 0.35,
      });
  if (data?.bypass && targetX - sourceX > 160) {
    const left = sourceX + 52,
      right = targetX - 48,
      y = Math.min(sourceY, targetY) - 80;
    path = `M ${sourceX},${sourceY} L ${left - 16},${sourceY} Q ${left},${sourceY} ${left},${sourceY - 16} L ${left},${y + 16} Q ${left},${y} ${left + 16},${y} L ${right - 16},${y} Q ${right},${y} ${right},${y + 16} L ${right},${targetY - 16} Q ${right},${targetY} ${right + 16},${targetY} L ${targetX},${targetY}`;
    labelX = (left + right) / 2;
    labelY = y;
  }
  if (data?.returning && sourceX > targetX + 160) {
    const y = Math.max(sourceY + 90, targetY + 150),
      x = targetX - 36,
      right = sourceX - 36;
    path = `M ${sourceX},${sourceY} L ${right + 14},${sourceY} Q ${right},${sourceY} ${right},${sourceY + 14} L ${right},${y - 14} Q ${right},${y} ${right - 14},${y} L ${x + 14},${y} Q ${x},${y} ${x},${y - 14} L ${x},${targetY + 14} Q ${x},${targetY} ${x + 14},${targetY} L ${targetX},${targetY}`;
    labelX = (x + right) / 2;
    labelY = y;
  }
  const type = data?.knowledge
    ? "knowledge"
    : data?.external
      ? "external"
      : data?.shared
        ? "shared"
        : data?.gated
          ? "gated"
          : "audio";
  const tone = data?.knowledge
    ? "knowledge"
    : data?.external
      ? "playback"
      : data?.returning
        ? "discord"
        : props.source === "mic"
          ? "mic"
          : "assistant";
  const flowing =
    data?.active &&
    !data.gated &&
    !data.external &&
    !data.knowledge &&
    !data.pending;
  const stateClass = `${flowing ? "signal-active" : ""} ${data?.pending ? "pending" : ""} ${selected ? "edge-selected" : ""}`;
  return (
    <>
      <g className={`signal-bundle tone-${tone} edge-${type} ${stateClass}`}>
        <path d={path} className="signal-glow" aria-hidden="true" />
        <BaseEdge
          id={id}
          path={path}
          className="signal-edge"
          interactionWidth={22}
          style={{ strokeWidth: selected || flowing ? 2.3 : 1.8 }}
        />
        {flowing && (
          <path
            d={path}
            className="signal-motion"
            aria-hidden="true"
            style={{
              opacity: Math.max(0.6, meterPercent(data?.level || 0) / 100),
            }}
          />
        )}
      </g>
      {(selected || data?.external || data?.knowledge) && data?.label && (
        <EdgeLabelRenderer>
          <span
            className={`edge-label ${data?.knowledge ? "knowledge-label" : ""} ${selected ? "selected" : ""}`}
            style={{
              transform: `translate(-50%, -50%) translate(${labelX}px,${labelY}px)`,
            }}
          >
            {data.label}
          </span>
        </EdgeLabelRenderer>
      )}
    </>
  );
});
