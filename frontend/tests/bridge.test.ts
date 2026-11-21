import {beforeEach, describe, expect, it, vi} from 'vitest';
import {migrate} from '../src/model';

beforeEach(() => vi.resetModules());

describe('native controller bridge', () => {
  it('refuses live operations when the browser has no native controller', async () => {
    const {bridge, nativeAvailable, preview} = await import('../src/bridge');
    expect(nativeAvailable()).toBe(false);
    expect(preview).toBe(false);
    await expect(bridge({op: 'bootstrap'})).rejects.toThrow(/Open Dottie Forever/);
    await expect(bridge({op: 'start', mode: 'live'})).rejects.toThrow(/connect to live audio/);
  });

  it('passes commands intact and surfaces native validation failures', async () => {
    const postMessage = vi.fn().mockResolvedValueOnce({ok: true, message: 'saved'}).mockResolvedValueOnce({ok: false, error: {message: 'Default microphone is unavailable'}});
    window.webkit = {messageHandlers: {router: {postMessage}}};
    const {bridge} = await import('../src/bridge');
    const command = {op: 'save_graph', graph: migrate()};
    await expect(bridge(command)).resolves.toEqual({ok: true, message: 'saved'});
    expect(postMessage).toHaveBeenNthCalledWith(1, command);
    await expect(bridge({op: 'start'})).rejects.toThrow('Default microphone is unavailable');
  });

  it('only exposes fixture data after an explicit preview request', async () => {
    history.replaceState(null, '', '/?preview=1');
    const {bridge, preview} = await import('../src/bridge');
    expect(preview).toBe(true);
    const catalog = await bridge({op: 'bootstrap'});
    expect(catalog.inputs?.[0].uid).toMatch(/^preview-/);
    await expect(bridge({op: 'status'})).rejects.toThrow(/stopped/);
    expect(await bridge({op: 'diagnostics'})).toEqual({ok: true, diagnostics: {}});
    expect((await bridge({op: 'open_event_logs'})).message).toContain('Preview only');
    const graph = migrate(catalog.settings);
    const started = await bridge({op: 'start', graph});
    expect(started.gate).toBe('closed');
    expect((await bridge({op: 'wake'})).gate).toBe('open');
    expect((await bridge({op: 'standby'})).gate).toBe('closed');
    await bridge({op: 'shutdown'});
    await expect(bridge({op: 'status'})).rejects.toThrow(/stopped/);
  });

  it('uses the native controller even if a preview query is present', async () => {
    history.replaceState(null, '', '/?preview=1');
    const postMessage = vi.fn().mockResolvedValue({ok: true, message: 'actual native reply'});
    window.webkit = {messageHandlers: {router: {postMessage}}};
    const {bridge} = await import('../src/bridge');
    expect(await bridge({op: 'catalog'})).toEqual({ok: true, message: 'actual native reply'});
    expect(postMessage).toHaveBeenCalledWith({op: 'catalog'});
  });
});
