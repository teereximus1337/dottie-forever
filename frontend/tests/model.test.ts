import {describe, expect, it} from 'vitest';
import {
  addApp, appNode, db, formatDb, MAX_APPS, meterPercent, migrate,
  removeApp, routeForConnection, routingKey, setRoute, validateGraph,
} from '../src/model';

const graph = () => migrate({mic_uid: 'physical-mic', dot_bundle: 'com.openai.codex', discord_bundle: 'com.hnc.Discord'});
const connection = (source: string, target: string, sourceHandle = 'out', targetHandle = 'in') => ({source, target, sourceHandle, targetHandle});

describe('measured audio levels', () => {
  it('maps signal amplitude logarithmically, so normal voice is visible without inventing gain', () => {
    expect(db(1)).toBe(0);
    expect(db(0.1)).toBeCloseTo(-20);
    expect(db(0.01)).toBeCloseTo(-40);
    expect(meterPercent(0.001)).toBeCloseTo(0);
    expect(meterPercent(0.01)).toBeCloseTo(100 / 3);
    expect(meterPercent(0.1)).toBeCloseTo(200 / 3);
    expect(meterPercent(1)).toBe(100);
    expect(formatDb(0.1)).toBe('-20.0 dBFS');
  });

  it('bounds silence, invalid values and overload without NaN or overflowing the meter', () => {
    for (const value of [0, -1, NaN, Infinity, -Infinity]) {
      expect(db(value)).toBe(-96);
      expect(meterPercent(value)).toBe(0);
      expect(formatDb(value)).toBe('Silent');
    }
    expect(db(1e-20)).toBe(-96);
    expect(db(2)).toBe(0);
    expect(meterPercent(2)).toBe(100);
  });
});

describe('the focused ChatGPT and Discord profile', () => {
  it('accepts exactly the supported source contributions', () => {
    const g = graph();
    expect(routeForConnection(connection('mic', 'app:com.hnc.Discord'), g)).toBe('mic_to_apps');
    expect(routeForConnection(connection('mic', 'assistant'), g)).toBe('mic_to_assistant');
    expect(routeForConnection(connection('assistant', 'app:com.hnc.Discord'), g)).toBe('assistant_to_apps');
    expect(routeForConnection(connection(appNode('com.hnc.Discord'), 'assistant'), g)).toBe('app:com.hnc.Discord');
  });

  it.each([
    ['assistant', 'assistant'],
    ['app:com.hnc.Discord', 'apps-feed'],
    ['app:com.hnc.Discord', 'app:com.hnc.Discord'],
    ['apps-feed', 'assistant'],
    ['mic', 'apps-feed'],
    ['assistant', 'apps-feed'],
    ['mic', 'app:com.blizzard.worldofwarcraft'],
    ['app:com.blizzard.worldofwarcraft', 'assistant'],
    ['reference', 'assistant'],
    ['assistant', 'output'],
    ['output', 'assistant'],
    ['app:unknown', 'assistant'],
  ])('rejects unsupported or self-return wiring: %s → %s', (source, target) => {
    expect(routeForConnection(connection(source, target), graph())).toBeNull();
  });

  it('rejects wrong handles, including the native playback and shared assignments', () => {
    expect(routeForConnection(connection('mic', 'assistant', 'shared'), graph())).toBeNull();
    expect(routeForConnection(connection('mic', 'assistant', 'out', 'playback'), graph())).toBeNull();
    expect(routeForConnection(connection('apps-feed', 'app:com.hnc.Discord', 'shared', 'shared'), graph())).toBeNull();
    expect(routeForConnection(connection('reference', 'assistant', 'data', 'knowledge'), graph())).toBeNull();
    expect(routeForConnection(connection('mic', 'app:com.hnc.Discord'), removeApp(graph(), 'com.hnc.Discord'))).toBeNull();
    const stale = graph();
    stale.apps.push({bundle_id: 'com.blizzard.worldofwarcraft'});
    expect(routeForConnection(connection('app:com.blizzard.worldofwarcraft', 'assistant'), stale)).toBeNull();
  });

  it('edits contributions immutably without creating app self-return or duplicate routes', () => {
    const original = graph();
    const changed = setRoute(original, 'mic_to_apps', false);
    expect(original.routes.mic_to_apps).toBe(true);
    expect(changed.routes.mic_to_apps).toBe(false);
    expect(changed.routes.mic_to_assistant).toBe(true);
    expect(setRoute(original, 'app:com.hnc.Discord', true).routes.apps_to_assistant).toEqual(['com.hnc.Discord']);
    expect(setRoute(original, 'app:missing', true)).toBe(original);
    expect(setRoute(original, 'app:com.hnc.Discord', false).routes.apps_to_assistant).toEqual([]);
  });

  it('allows only one optional Discord, without unrelated or game audio sources', () => {
    const g = graph();
    expect(MAX_APPS).toBe(1);
    expect(addApp(g, 'com.hnc.Discord')).toBe(g);
    expect(addApp(g, 'com.openai.codex')).toBe(g);
    expect(addApp(g, '')).toBe(g);
    expect(g.apps).toHaveLength(MAX_APPS);
    g.positions['app:com.hnc.Discord'] = {x: 100, y: 200};
    const removed = removeApp(g, 'com.hnc.Discord');
    expect(removed.apps.map(a => a.bundle_id)).not.toContain('com.hnc.Discord');
    expect(removed.routes.apps_to_assistant).not.toContain('com.hnc.Discord');
    expect(removed.positions['app:com.hnc.Discord']).toBeUndefined();
    expect(g.apps.map(a => a.bundle_id)).toContain('com.hnc.Discord');
    expect(removed.routes.mic_to_apps).toBe(false);
    expect(removed.routes.assistant_to_apps).toBe(false);
    for (const bundle of ['com.blizzard.worldofwarcraft', 'other.chat', 'com.openai.codex']) expect(addApp(removed, bundle)).toBe(removed);
    const restored = addApp(removed, 'com.hnc.Discord');
    expect(restored.apps).toEqual([{bundle_id: 'com.hnc.Discord'}]);
    expect(restored.routes.mic_to_apps).toBe(true);
    expect(restored.routes.assistant_to_apps).toBe(true);
    expect(restored.routes.apps_to_assistant).toEqual([]);
  });

  it('rejects invalid graph identities before an apply', () => {
    expect(validateGraph(graph())).toEqual([]);
    const g = graph();
    g.apps.push({bundle_id: 'com.openai.codex'}, {bundle_id: 'com.hnc.Discord'});
    g.routes.apps_to_assistant.push('missing');
    expect(validateGraph(g).length).toBeGreaterThan(0);
    expect(validateGraph({...graph(), mic: {mode: 'device'}})).toEqual([expect.stringMatching(/microphone/)]);
    expect(validateGraph({...graph(), assistant: {bundle_id: 'another.ai'}}).length).toBeGreaterThan(0);
    expect(validateGraph({...graph(), apps: [{bundle_id: 'com.blizzard.worldofwarcraft'}]}).length).toBeGreaterThan(0);
    expect(validateGraph({...graph(), apps: [{bundle_id: 'another.chat'}]}).length).toBeGreaterThan(0);
  });
});

describe('persisted configuration', () => {
  it('migrates legacy microphone and voice settings into the fixed assistant profile', () => {
    const g = migrate({mic_uid: 'exact-device', dot_bundle: 'app.ai', discord_bundle: 'com.hnc.Discord', voice_detection: false});
    expect(g.mic).toEqual({mode: 'device', uid: 'exact-device'});
    expect(g.assistant).toEqual({bundle_id: 'com.openai.codex'});
    expect(g.apps).toEqual([{bundle_id: 'com.hnc.Discord'}]);
    expect(g.routes).toEqual({mic_to_apps: true, mic_to_assistant: true, assistant_to_apps: true, apps_to_assistant: ['com.hnc.Discord']});
    expect(g.voice_detection).toBe(false);
    expect(migrate().mic).toEqual({mode: 'default'});
  });

  it('preserves route choices while stripping unrelated sources from an earlier graph', () => {
    const original = graph();
    original.assistant.bundle_id = 'old.assistant';
    original.apps.push({bundle_id: 'com.blizzard.worldofwarcraft'}, {bundle_id: 'other.chat'});
    original.routes.mic_to_apps = false;
    original.routes.mic_to_assistant = false;
    original.routes.apps_to_assistant.push('com.blizzard.worldofwarcraft', 'other.chat');
    original.voice_detection = false;
    original.positions = {mic: {x: 1, y: 2}, reference: {x: 3, y: 4}, 'apps-feed': {x: 5, y: 6}, 'app:com.blizzard.worldofwarcraft': {x: 7, y: 8}};
    const restored = migrate({graph: original});
    expect(restored.assistant.bundle_id).toBe('com.openai.codex');
    expect(restored.apps).toEqual([{bundle_id: 'com.hnc.Discord'}]);
    expect(restored.routes).toEqual({mic_to_apps: false, mic_to_assistant: false, assistant_to_apps: true, apps_to_assistant: ['com.hnc.Discord']});
    expect(restored.voice_detection).toBe(false);
    expect(restored.mic).toEqual(original.mic);
    expect(restored.positions).toEqual({mic: {x: 1, y: 2}, reference: {x: 3, y: 4}});
    expect(original.apps).toHaveLength(3);
  });

  it('does not keep a hidden conversation feed after migrating a graph without Discord', () => {
    const original = graph();
    original.apps = [{bundle_id: 'other.chat'}];
    original.routes.apps_to_assistant = ['other.chat'];
    const restored = migrate({graph: original});
    expect(restored.apps).toEqual([]);
    expect(restored.routes.mic_to_apps).toBe(false);
    expect(restored.routes.assistant_to_apps).toBe(false);
    expect(restored.routes.apps_to_assistant).toEqual([]);
    expect(restored.routes.mic_to_assistant).toBe(true);
  });

  it('preserves a saved graph without mutating it or treating layout changes as routing changes', () => {
    const original = graph();
    original.positions.mic = {x: 4, y: 8};
    const restored = migrate({graph: original, mic_uid: 'obsolete'});
    expect(restored).toEqual(original);
    restored.positions.mic.x = 300;
    expect(original.positions.mic.x).toBe(4);
    expect(routingKey(restored)).toBe(routingKey(original));
    expect(routingKey(setRoute(restored, 'mic_to_apps', false))).not.toBe(routingKey(original));
  });

  it('compares routing semantics across reordered native JSON and an empty default microphone UID', () => {
    const original = {...graph(), mic: {mode: 'default' as const}};
    const native = {
      output: original.output,
      voice_detection: original.voice_detection,
      positions: {mic: {x: 500, y: 200}},
      routes: {
        apps_to_assistant: [...original.routes.apps_to_assistant],
        assistant_to_apps: original.routes.assistant_to_apps,
        mic_to_assistant: original.routes.mic_to_assistant,
        mic_to_apps: original.routes.mic_to_apps,
      },
      apps: [...original.apps],
      assistant: original.assistant,
      mic: {uid: '', mode: 'default' as const},
      version: 1 as const,
    };
    expect(routingKey(native)).toBe(routingKey(original));
    const pinned = graph();
    const otherMicrophone = {...pinned, mic: {mode: 'device' as const, uid: 'different-physical-mic'}};
    expect(routingKey(otherMicrophone)).not.toBe(routingKey(pinned));
    expect(routingKey(pinned)).not.toBe(routingKey(original));
  });
});
