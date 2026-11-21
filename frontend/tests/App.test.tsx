import type {ButtonHTMLAttributes, ReactNode} from 'react';
import {act, fireEvent, render, screen, waitFor} from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import {beforeEach, describe, expect, it, vi} from 'vitest';
import {NodeChangeset} from '@xyflow/system';
import type {CanvasNode, Signal} from '../src/CanvasParts';
import type {BridgeReply, Catalog, Graph, Snapshot} from '../src/types';
import {migrate} from '../src/model';

type FlowProps = {
  nodes: CanvasNode[]; edges: Signal[]; children: ReactNode; nodeDragThreshold?: number;
  onEdgeClick: (event: unknown, edge: Signal) => void;
  onNodesChange: (changes: NodeChangeset<CanvasNode>) => void;
};
const flowCapture = vi.hoisted(() => ({current: null as FlowProps | null}));

// Browser geometry and drag/drop are reviewed against the real React Flow canvas.
// These tests keep the native boundary and application controls real, while exposing
// React Flow's selection callbacks without relying on jsdom layout measurements.
vi.mock('@xyflow/react', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@xyflow/react')>();
  return {
    ...actual,
    useReactFlow: () => ({fitView: vi.fn()}),
    ReactFlowProvider: ({children}: {children: ReactNode}) => <>{children}</>,
    ReactFlow: (props: FlowProps) => {
      flowCapture.current = props;
      const {nodes, edges, children, onEdgeClick, nodeDragThreshold} = props;
      return <div data-testid="canvas" data-drag-threshold={nodeDragThreshold}>
      {nodes.map(node => <button key={node.id} onClick={node.data.onSelect}>Inspect {node.id}</button>)}
      {edges.map(edge => <button key={edge.id} data-deletable={edge.deletable} data-route={edge.data?.route} onClick={() => onEdgeClick(null, edge)}>Inspect connection {edge.id}</button>)}
      {children}
    </div>;
    },
    Background: () => null,
    Controls: ({children}: {children: ReactNode}) => <>{children}</>,
    ControlButton: (props: ButtonHTMLAttributes<HTMLButtonElement>) => <button {...props}/>,
  };
});

import RouterApp from '../src/App';
import {Meter} from '../src/CanvasParts';

const makeCatalog = (): Catalog => ({
  ok: true,
  inputs: [{uid: 'physical-mic', name: 'Studio microphone'}],
  outputs: [{uid: 'headphones', name: 'Headphones'}],
  defaults: {input_uid: 'physical-mic', output_uid: 'headphones'},
  apps: [
    {bundle_id: 'com.openai.codex', name: 'ChatGPT', installed: true, running: true, audio_available: true},
    {bundle_id: 'com.hnc.Discord', name: 'Discord', installed: true, running: true, audio_available: true},
    {bundle_id: 'com.blizzard.worldofwarcraft', name: 'World of Warcraft', installed: true, running: true, audio_available: true},
  ],
  settings: {
    mic_uid: 'physical-mic', dot_bundle: 'com.openai.codex', discord_bundle: 'com.hnc.Discord',
    names: {discord: 'Router · Apps', alexa: 'Router · Assistant'},
    phrases: {wake: 'Hello assistant', standby: 'Assistant standby'},
  },
  components: {host: true, installer: false},
  reference: {
    name: 'Polestar', status: 'verified_snapshot', edition: 'WoW Forever', version: 'fixture-1', record_count: 12345,
    built_at: '2026-11-09', verified_at: '2026-11-18', site_url: 'https://example.invalid/reference',
    plugin_id: 'fixture.polestar', tools: ['search_quests', 'get_quest'],
  },
});

function installController() {
  const catalog = makeCatalog();
  let state: Snapshot | null = null;
  let rejectApply = false;
  const postMessage = vi.fn(async (command: Record<string, unknown>): Promise<BridgeReply> => {
    if (command.op === 'bootstrap' || command.op === 'catalog') return structuredClone(catalog);
    if (command.op === 'save_graph') {
      catalog.settings.graph = structuredClone(command.graph as Graph);
      return {ok: true};
    }
    if (command.op === 'start' || command.op === 'apply_graph') {
      if (command.op === 'apply_graph' && rejectApply) return {ok: false, error: {message: 'Selected app has no audio source. The current route is still running.'}};
      const graph = structuredClone(command.graph as Graph);
      state = {
        ok: true, mode: 'live', gate: 'closed', active_graph: graph, graph_revision: 1,
        names: catalog.settings.names, phrases: catalog.settings.phrases,
        health: {mic: true, dot: true, controller: true},
        detector: {enabled: true, healthy: true},
        meter_levels: {
          mic: {rms: 0.1, peak: 0.2}, assistant: {rms: 0, peak: 0},
          apps: graph.routes.apps_to_assistant.includes('com.hnc.Discord') ? {'com.hnc.Discord': {rms: 0, peak: 0}} : {},
          to_apps: {rms: 0.1, peak: 0.2}, to_assistant: {rms: 0, peak: 0}, listener: {rms: 0.1, peak: 0.2},
        },
      };
      return structuredClone(state);
    }
    if (command.op === 'open_reference') return {ok: true};
    if (command.op === 'open_event_logs') return {ok: true, message: 'Event logs opened in Finder.'};
    if (command.op === 'diagnostics') return {ok: true, diagnostics: {controller: {active: true, queued: 0, written: 1, dropped: 0, errors: 0}}};
    if (command.op === 'shutdown') {state = null; return {ok: true};}
    if (command.op === 'wake' && state) state.gate = 'open';
    if (command.op === 'standby' && state) state.gate = 'closed';
    if (command.op === 'configure' && state) {
      state.names = command.names as Snapshot['names'];
      state.phrases = command.phrases as Snapshot['phrases'];
      state.gate = 'closed';
    }
    return state ? structuredClone(state) : {ok: false, error: {message: 'Audio engine stopped'}};
  });
  window.webkit = {messageHandlers: {router: {postMessage}}};
  return {catalog, postMessage, rejectNextApply: () => {rejectApply = true;}};
}

async function loadApp() {
  render(<RouterApp/>);
  await waitFor(() => expect((screen.getByRole('button', {name: 'Start routing'}) as HTMLButtonElement).disabled).toBe(false));
}

async function startApp() {
  await loadApp();
  await userEvent.click(screen.getByRole('button', {name: 'Start routing'}));
  await screen.findByRole('button', {name: 'Stop routing'});
}

beforeEach(() => {delete window.webkit; flowCapture.current = null;});

describe('native canvas controls', () => {
  it('saves phrases while stopped without claiming recognition is active', async () => {
    const c = installController();
    const original = c.postMessage.getMockImplementation()!;
    c.postMessage.mockImplementation(async cmd => cmd.op === 'configure'
      ? {ok: true, phrases: cmd.phrases as Snapshot['phrases'], phrase_activation: 'saved_routing_off'}
      : original(cmd));
    await loadApp();
    await userEvent.click(screen.getByRole('button', {name: 'Settings'}));
    fireEvent.change(screen.getByLabelText('Wake phrase'), {target: {value: '  Hey   Dottie  '}});
    await userEvent.click(screen.getByRole('button', {name: 'Save names & phrases'}));
    expect(await screen.findByText('Phrases saved. They’ll apply when routing starts.')).toBeTruthy();
    expect(c.postMessage).toHaveBeenCalledWith(expect.objectContaining({op: 'configure', phrases: {wake: 'Hey Dottie', standby: 'Assistant standby'}}));
    expect(screen.queryByText('New voice phrases active.')).toBeNull();
    expect(c.postMessage.mock.calls.some(([cmd]) => cmd.op === 'start')).toBe(false);
  });
  it('waits for a confirmed activation, blocks duplicate saves, and renders rejection inline', async () => {
    const c = installController();
    const original = c.postMessage.getMockImplementation()!;
    let finish: (reply: BridgeReply) => void = () => { throw Error('Save did not begin'); };
    c.postMessage.mockImplementation(async cmd => cmd.op === 'configure'
      ? new Promise<BridgeReply>(resolve => {finish = resolve;})
      : original(cmd));
    await loadApp();
    await userEvent.click(screen.getByRole('button', {name: 'Settings'}));
    fireEvent.change(screen.getByLabelText('Wake phrase'), {target: {value: 'Hey Dottie'}});
    const save = () => screen.getByRole('button', {name: /^Save names/});
    fireEvent.click(save());
    const saving = await screen.findByRole('button', {name: 'Saving…'}) as HTMLButtonElement;
    expect(saving.disabled).toBe(true);
    fireEvent.click(saving);
    expect(screen.queryByText('New voice phrases active.')).toBeNull();
    await act(async () => finish({ok: false, error: {message: 'Previous phrases kept; assistant is on standby.'}}));
    expect((await screen.findByRole('alert')).textContent).toContain('Previous phrases kept');
    expect(c.postMessage.mock.calls.filter(([cmd]) => cmd.op === 'configure')).toHaveLength(1);
    fireEvent.click(save());
    await act(async () => finish({ok: true, mode: 'live', gate: 'closed', phrases: {wake: 'Hey Dottie', standby: 'Assistant standby'}, phrase_activation: 'active'}));
    expect(await screen.findByText('New voice phrases active.')).toBeTruthy();
  });

  it('opens local event logs and reads their status without starting stopped audio', async () => {
    const controller = installController();
    await loadApp();
    await userEvent.click(screen.getByRole('button', {name: 'Settings'}));
    await userEvent.click(screen.getByText('Engine & diagnostics'));
    await screen.findByText('Active');
    expect(screen.getByText('Not connected')).toBeTruthy();
    await userEvent.click(screen.getByRole('button', {name: 'Show event logs'}));
    expect(controller.postMessage).toHaveBeenCalledWith({op: 'open_event_logs'});
    expect(controller.postMessage.mock.calls.some(([command]) => ['start', 'wake', 'heartbeat'].includes(String(command.op)))).toBe(false);
    expect(screen.getByText('Event logs opened in Finder.')).toBeTruthy();
  });

  it('reports incomplete history without turning a logging error into an audio fault', async () => {
    const controller = installController();
    const implementation = controller.postMessage.getMockImplementation()!;
    controller.postMessage.mockImplementation(async command => command.op === 'diagnostics'
      ? {ok: true, diagnostics: {controller: {active: false, queued: 0, written: 1, dropped: 2, errors: 1}}}
      : implementation(command));
    await startApp();
    await userEvent.click(screen.getByRole('button', {name: 'Settings'}));
    await userEvent.click(screen.getByText('Engine & diagnostics'));
    await screen.findByText(/Some events could not be saved/);
    expect(screen.getByRole('button', {name: 'Stop routing'})).toBeTruthy();
    expect(screen.getByText('Routing live')).toBeTruthy();
  });

  it('shows a disconnected browser instead of a pretend live session', () => {
    render(<RouterApp/>);
    expect(screen.getByText('App not connected')).toBeTruthy();
    expect(screen.getByText(/Open Dottie Forever on your Mac/)).toBeTruthy();
    expect((screen.getByRole('button', {name: 'Start routing'}) as HTMLButtonElement).disabled).toBe(true);
    expect(screen.queryByText('Routing live')).toBeNull();
    expect(screen.queryByText(/Preview · simulated/)).toBeNull();
  });

  it('starts the exact migrated graph and stops using the same primary control', async () => {
    const controller = installController();
    await startApp();
    expect(controller.postMessage).toHaveBeenCalledWith({op: 'start', mode: 'live', graph: migrate(controller.catalog.settings)});
    expect(screen.getByText('Routing live')).toBeTruthy();
    expect(screen.getByTestId('canvas').getAttribute('data-drag-threshold')).toBe('0');
    expect(screen.queryByRole('button', {name: 'Inspect apps-feed'})).toBeNull();
    expect(screen.queryByRole('button', {name: 'Inspect app:com.blizzard.worldofwarcraft'})).toBeNull();
    expect(screen.getByRole('button', {name: 'Inspect reference'})).toBeTruthy();
    await userEvent.click(screen.getByRole('button', {name: 'Stop routing'}));
    await screen.findByRole('button', {name: 'Start routing'});
    expect(controller.postMessage).toHaveBeenCalledWith({op: 'shutdown'});
  });

  it('observes the open line before slow source discovery finishes', async () => {
    const controller = installController();
    const implementation = controller.postMessage.getMockImplementation()!;
    await implementation({op: 'start', graph: migrate(controller.catalog.settings)});
    await implementation({op: 'wake'});
    let release!: () => void;
    const pending = new Promise<void>(resolve => {release = resolve;});
    controller.postMessage.mockImplementation(async command => {
      if (command.op === 'bootstrap') await pending;
      return implementation(command);
    });
    render(<RouterApp/>);
    await waitFor(() => expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.gateOpen).toBe(true));
    expect(screen.getByText('Routing live')).toBeTruthy();
    await act(async () => release());
  });

  it('keeps the gate current during a slow source refresh', async () => {
    const controller = installController();
    await startApp();
    const implementation = controller.postMessage.getMockImplementation()!;
    let release!: () => void;
    const pending = new Promise<void>(resolve => {release = resolve;});
    controller.postMessage.mockImplementation(async command => {
      if (command.op === 'catalog') await pending;
      return implementation(command);
    });
    await userEvent.click(screen.getByRole('button', {name: 'Refresh sources'}));
    await implementation({op: 'wake'});
    await waitFor(() => expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.gateOpen).toBe(true));
    expect((screen.getByRole('button', {name: 'Refresh sources'}) as HTMLButtonElement).disabled).toBe(true);
    await act(async () => release());
  });

  it('does not roll back a confirmed wake when an older status reply arrives', async () => {
    const controller = installController();
    await startApp();
    const implementation = controller.postMessage.getMockImplementation()!;
    let release!: () => void;
    let held = false;
    const oldStatus = {...await implementation({op: 'status'}), frames: 100};
    controller.postMessage.mockImplementation(async command => {
      if (command.op === 'status' && !held) {
        held = true;
        return new Promise<BridgeReply>(resolve => {release = () => resolve(oldStatus);});
      }
      const result = await implementation(command);
      // Simulate the native cache lagging behind the confirmed command.
      return command.op === 'status' ? {...oldStatus} : {...result, frames: 200};
    });
    await waitFor(() => expect(held).toBe(true));
    await act(async () => flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.onGate!());
    expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.gateOpen).toBe(true);
    await act(async () => release());
    const polls = controller.postMessage.mock.calls.filter(([command]) => command.op === 'status').length;
    await waitFor(() => expect(controller.postMessage.mock.calls.filter(([command]) => command.op === 'status').length).toBeGreaterThan(polls));
    expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.gateOpen).toBe(true);
  });

  it('refreshes status immediately on foreground without changing routing', async () => {
    const controller = installController();
    await startApp();
    await act(async () => { await Promise.resolve(); });
    controller.postMessage.mockClear();
    await act(async () => {fireEvent.focus(window);});
    expect(controller.postMessage).toHaveBeenCalledWith({op: 'status'});
    expect(controller.postMessage.mock.calls.every(([command]) => command.op === 'status')).toBe(true);
  });

  it('marks an overdue status as unknown without accumulating native reads', async () => {
    const controller = installController();
    await startApp();
    const implementation = controller.postMessage.getMockImplementation()!;
    const fresh = await implementation({op: 'wake'});
    let release!: () => void;
    controller.postMessage.mockImplementation(async command => command.op === 'status'
      ? new Promise<BridgeReply>(resolve => {release = () => resolve(fresh);})
      : implementation(command));
    vi.useFakeTimers();
    try {
      controller.postMessage.mockClear();
      await act(async () => {fireEvent.focus(window);});
      await act(async () => {await vi.advanceTimersByTimeAsync(800);});
      expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.status).toBe('Checking connection');
      expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.gateOpen).toBe(false);
      await act(async () => {await vi.advanceTimersByTimeAsync(1000);});
      expect(controller.postMessage.mock.calls.filter(([command]) => command.op === 'status')).toHaveLength(1);
      await act(async () => release());
      expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.gateOpen).toBe(true);
    } finally {vi.useRealTimers();}
  });

  it('makes exhausted recovery visible on the assistant node instead of Ready to connect', async () => {
    const controller = installController();
    const implementation = controller.postMessage.getMockImplementation()!;
    controller.postMessage.mockImplementation(async command => command.op === 'status'
      ? {ok: false, error: {message: 'Recovery paused after three attempts. Use Start routing to retry.'}}
      : implementation(command));
    await loadApp();
    await waitFor(() => expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.status).toBe('Recovery paused'));
    expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.statusDetail).toContain('Start routing');
    expect(flowCapture.current!.nodes.find(node => node.id === 'assistant')!.data.gateOpen).toBe(false);
    expect(screen.queryByText('Ready to connect')).toBeNull();
  });

  it('stages a route change and sends it only when Apply is clicked', async () => {
    const controller = installController();
    await startApp();
    await userEvent.click(screen.getByRole('button', {name: 'Inspect mic'}));
    await userEvent.click(screen.getByRole('checkbox', {name: 'Discord'}));
    expect(screen.getByText('Routing changes ready')).toBeTruthy();
    expect(controller.postMessage.mock.calls.some(([command]) => command.op === 'apply_graph')).toBe(false);
    await userEvent.click(screen.getByRole('button', {name: 'Apply changes'}));
    await waitFor(() => expect(screen.queryByText('Routing changes ready')).toBeNull());
    const applied = controller.postMessage.mock.calls.find(([command]) => command.op === 'apply_graph')?.[0].graph as Graph;
    expect(applied.routes.mic_to_apps).toBe(false);
    expect(applied.routes.mic_to_assistant).toBe(true);
    expect(applied.routes.assistant_to_apps).toBe(true);
  });

  it.each([false, undefined])('preserves measured geometry through status refreshes and persists settled movement (dragging=%s)', async (dragging) => {
    const controller = installController();
    await startApp();
    act(() => flowCapture.current!.onNodesChange(new NodeChangeset<CanvasNode>([
      {id: 'mic', type: 'dimensions', dimensions: {width: 248, height: 160}},
      {id: 'mic', type: 'position', position: {x: 120, y: 230}, dragging: true},
    ])));
    const moved = () => flowCapture.current!.nodes.find(node => node.id === 'mic')!;
    expect(moved().measured).toEqual({width: 248, height: 160});
    expect(moved().position).toEqual({x: 120, y: 230});
    const polls = controller.postMessage.mock.calls.filter(([command]) => command.op === 'status').length;
    await waitFor(() => expect(controller.postMessage.mock.calls.filter(([command]) => command.op === 'status').length).toBeGreaterThan(polls));
    expect(moved().measured).toEqual({width: 248, height: 160});
    expect(moved().position).toEqual({x: 120, y: 230});
    act(() => flowCapture.current!.onNodesChange(new NodeChangeset<CanvasNode>([
      {id: 'mic', type: 'position', position: {x: 140, y: 250}, dragging},
    ])));
    await waitFor(() => expect(controller.postMessage).toHaveBeenCalledWith(expect.objectContaining({op: 'save_graph', graph: expect.objectContaining({positions: expect.objectContaining({mic: {x: 140, y: 250}})})})));
    expect(moved().measured).toEqual({width: 248, height: 160});
    expect(moved().position).toEqual({x: 140, y: 250});
    expect(screen.queryByText('Routing changes ready')).toBeNull();
    expect(controller.postMessage.mock.calls.some(([command]) => command.op === 'apply_graph')).toBe(false);
  });

  it('keeps current routing and the draft available after native validation rejects an apply', async () => {
    const controller = installController();
    await startApp();
    controller.rejectNextApply();
    await userEvent.click(screen.getByRole('button', {name: 'Inspect mic'}));
    await userEvent.click(screen.getByRole('checkbox', {name: 'Discord'}));
    await userEvent.click(screen.getByRole('button', {name: 'Apply changes'}));
    expect(await screen.findByRole('alert')).toHaveProperty('textContent', expect.stringContaining('current route is still running'));
    expect(screen.getByRole('button', {name: 'Stop routing'})).toBeTruthy();
    expect(screen.getByText('Routing changes ready')).toBeTruthy();
    expect((screen.getByRole('checkbox', {name: 'Discord'}) as HTMLInputElement).checked).toBe(false);
  });

  it('adds only optional Discord without exposing a generic app picker or game audio', async () => {
    const controller = installController();
    controller.catalog.settings.discord_bundle = undefined;
    await loadApp();
    expect(screen.queryByRole('button', {name: 'Inspect app:com.hnc.Discord'})).toBeNull();
    await userEvent.click(screen.getByRole('button', {name: /Add Discord/}));
    expect(screen.getAllByRole('button', {name: 'Inspect app:com.hnc.Discord'})).toHaveLength(1);
    expect(screen.queryByRole('dialog')).toBeNull();
    expect(screen.queryByRole('button', {name: 'Add app'})).toBeNull();
    expect(screen.queryByRole('button', {name: 'Inspect app:com.blizzard.worldofwarcraft'})).toBeNull();
    const add = screen.queryByRole('button', {name: /Add Discord/}) as HTMLButtonElement | null;
    expect(add === null || add.disabled).toBe(true);
    await userEvent.click(screen.getByRole('button', {name: 'Start routing'}));
    await screen.findByRole('button', {name: 'Stop routing'});
    const submitted = controller.postMessage.mock.calls.find(([command]) => command.op === 'start')?.[0].graph as Graph;
    expect(submitted.apps).toEqual([{bundle_id: 'com.hnc.Discord'}]);
    expect(submitted.routes.apps_to_assistant).toEqual([]);
  });

  it('preserves unsaved settings while live status continues polling', async () => {
    const controller = installController();
    await startApp();
    await userEvent.click(screen.getByRole('button', {name: 'Settings'}));
    const input = screen.getByLabelText('For Discord') as HTMLInputElement;
    fireEvent.change(input, {target: {value: 'My conversation input'}});
    const polls = controller.postMessage.mock.calls.filter(([command]) => command.op === 'status').length;
    await waitFor(() => expect(controller.postMessage.mock.calls.filter(([command]) => command.op === 'status').length).toBeGreaterThan(polls + 1));
    expect(input.value).toBe('My conversation input');
    await userEvent.click(screen.getByRole('button', {name: 'Save names & phrases'}));
    await waitFor(() => expect(controller.postMessage).toHaveBeenCalledWith(expect.objectContaining({op: 'configure', names: {discord: 'My conversation input', alexa: 'Router · Assistant'}})));
  });

  it('provides a keyboard alternative for deleting a connection through its inspector', async () => {
    const controller = installController();
    await startApp();
    await userEvent.click(screen.getByRole('button', {name: 'Inspect connection mic_to_assistant'}));
    const remove = screen.getByRole('button', {name: 'Remove connection'});
    remove.focus();
    await userEvent.keyboard('{Enter}');
    expect(screen.queryByRole('button', {name: 'Inspect connection mic_to_assistant'})).toBeNull();
    expect(controller.postMessage.mock.calls.some(([command]) => command.op === 'apply_graph')).toBe(false);
  });

  it('explains an unavailable system default and preserves the explicit default choice', async () => {
    const controller = installController();
    controller.catalog.defaults = {input_uid: '', input_name: 'Router · Apps', output_uid: 'headphones'};
    controller.catalog.settings.mic_uid = undefined;
    await loadApp();
    await userEvent.click(screen.getByRole('button', {name: 'Inspect mic'}));
    expect((screen.getByLabelText('Input source') as HTMLSelectElement).value).toBe('default');
    expect(screen.getByRole('alert').textContent).toContain('Router · Apps');
    expect(screen.getByRole('alert').textContent).toContain('not an available physical microphone');
    expect(screen.getByText('No available microphone')).toBeTruthy();
    expect(controller.postMessage.mock.calls.some(([command]) => command.op === 'start')).toBe(false);
  });

  it('keeps receive-only Discord unmeasured instead of displaying the outgoing mix as its playback', async () => {
    const controller = installController();
    const graph = migrate(controller.catalog.settings);
    graph.routes.apps_to_assistant = [];
    controller.catalog.settings.graph = graph;
    await startApp();
    await userEvent.click(screen.getByRole('button', {name: 'Inspect app:com.hnc.Discord'}));
    expect(screen.getByRole('meter', {name: 'Discord playback level'}).getAttribute('aria-valuetext')).toBe('Not measured');
    expect(screen.getByText('Not measured')).toBeTruthy();
  });

  it('surfaces actionable Discord startup failure without changing the returned routes', async () => {
    const controller = installController();
    const original = controller.postMessage.getMockImplementation()!;
    controller.postMessage.mockImplementation(async cmd => cmd.op === 'start'
      ? {ok: false, error: {message: 'Open com.hnc.Discord to make its connected audio source available.'}}
      : original(cmd));
    await loadApp();
    await userEvent.click(screen.getByRole('button', {name: 'Start routing'}));
    const alert = await screen.findByRole('dialog', {name: /start routing/i});
    expect(alert.textContent).toContain('Join a Discord voice channel and refresh sources');
    expect(alert.textContent).toContain('disconnect Discord');
    expect(controller.postMessage.mock.calls.some(([cmd]) => cmd.op === 'save_graph')).toBe(false);
    expect(document.activeElement?.textContent).toBe('Dismiss');
    fireEvent(alert, new Event('cancel', {cancelable: true}));
    expect(screen.queryByRole('dialog', {name: /start routing/i})).toBeNull();
    const start = screen.getByRole('button', {name: 'Start routing'});
    expect(document.activeElement).toBe(start);
    await userEvent.click(start);
    const retry = await screen.findByRole('dialog', {name: /start routing/i});
    await userEvent.click(Array.from(retry.querySelectorAll('button')).find(button => button.textContent === 'Refresh sources')!);
    await waitFor(() => expect(screen.queryByRole('dialog', {name: /start routing/i})).toBeNull());
    expect(controller.postMessage.mock.calls.filter(([cmd]) => cmd.op === 'start')).toHaveLength(2);
    expect(controller.postMessage).toHaveBeenCalledWith({op: 'catalog'});
  });

  it.each([
    ['Open the selected assistant’s audio session, then refresh sources.', /Start a Dot voice call/],
    ['The selected microphone is unavailable. Reconnect it or choose another input.', /selected microphone is unavailable/],
  ])('shows the startup reason and safe next steps in the modal', async (message, pattern) => {
    const controller = installController();
    const original = controller.postMessage.getMockImplementation()!;
    controller.postMessage.mockImplementation(async cmd => cmd.op === 'start'
      ? {ok: false, error: {message}}
      : original(cmd));
    await loadApp();
    await userEvent.click(screen.getByRole('button', {name: 'Start routing'}));
    expect((await screen.findByRole('dialog', {name: /start routing/i})).textContent).toMatch(pattern);
  });

  it.each(['migration_pending', 'verified_snapshot'] as const)('shows a read-only Polestar credit with no backend claim for %s', async (status) => {
    const controller = installController();
    controller.catalog.reference!.status = status;
    await loadApp();
    const node = flowCapture.current?.nodes.find(node => node.id === 'reference');
    expect(node?.position).toEqual({x: 35, y: 340});
    expect(node?.data.title).toBe('Polestar');
    expect(node?.data.live).toBe(false);
    const edge = flowCapture.current?.edges.find(edge => edge.id === 'quest-data');
    expect(edge?.data).toEqual({active: false, knowledge: true, label: 'WoW Forever reference'});
    expect(edge?.deletable).toBe(false);
    await userEvent.click(screen.getByRole('button', {name: 'Inspect reference'}));
    expect(screen.getByText(/doesn’t check whether a reference is connected/)).toBeTruthy();
    expect(screen.queryByText(/Migration pending|Hosted reference configured|Last checked in ChatGPT/)).toBeNull();
    expect(screen.queryByRole('button', {name: /Open.*reference/i})).toBeNull();
    await userEvent.click(screen.getByRole('button', {name: 'Start routing'}));
    await waitFor(() => expect(controller.postMessage).toHaveBeenCalledWith(expect.objectContaining({op: 'start', graph: expect.objectContaining({routes: migrate(controller.catalog.settings).routes})})));
  });

  it.each(['start', 'apply_graph'] as const)('preserves edits made while %s is pending as a new draft', async (operation) => {
    const controller = installController();
    if (operation === 'start') await loadApp();
    else await startApp();
    await userEvent.click(screen.getByRole('button', {name: 'Inspect mic'}));
    if (operation === 'apply_graph') await userEvent.click(screen.getByRole('checkbox', {name: 'Discord'}));
    const implementation = controller.postMessage.getMockImplementation()!;
    let release!: () => void;
    const pending = new Promise<void>(resolve => {release = resolve;});
    controller.postMessage.mockImplementation(async command => {
      if (command.op === operation) await pending;
      const result = await implementation(command);
      // Older hosts do not echo active_graph; fallback must be the submitted graph,
      // never the graph ref after another control was edited during the request.
      delete result.active_graph;
      return result;
    });
    await userEvent.click(screen.getByRole('button', {name: operation === 'start' ? 'Start routing' : 'Apply changes'}));
    await userEvent.click(screen.getByRole('checkbox', {name: 'ChatGPT input'}));
    const submitted = [...controller.postMessage.mock.calls].reverse().find(([command]) => command.op === operation)?.[0].graph as Graph;
    expect(submitted.routes.mic_to_assistant).toBe(true);
    await act(async () => release());
    await screen.findByRole('button', {name: 'Stop routing'});
    expect(screen.getByText('Routing changes ready')).toBeTruthy();
    expect((screen.getByRole('checkbox', {name: 'ChatGPT input'}) as HTMLInputElement).checked).toBe(false);
  });
});

describe('meter presentation', () => {
  it('exposes measured dBFS to assistive technology and distinguishes overload from silence', () => {
    const {rerender} = render(<Meter live level={{rms: 0.1, peak: 0.2}} label="Microphone"/>);
    const meter = screen.getByRole('meter', {name: 'Microphone level'});
    expect(meter.getAttribute('aria-valuenow')).toBe('-20');
    expect(meter.getAttribute('aria-valuetext')).toBe('-20.0 dBFS');
    rerender(<Meter live level={{rms: 0.3, peak: 1}} label="Microphone"/>);
    expect(screen.getByText('CLIP')).toBeTruthy();
    rerender(<Meter live={false} level={{rms: 0.3, peak: 1}} label="Microphone"/>);
    expect(meter.getAttribute('aria-valuetext')).toBe('Not running');
    expect(screen.queryByText('CLIP')).toBeNull();
  });
});
