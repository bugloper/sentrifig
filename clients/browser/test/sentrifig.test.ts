import { describe, expect, it, vi, beforeEach } from 'vitest';
import { createSentrifig, installGate, type SentryEventLike } from '../src/index';

// Sentry events carry far more than we touch; the gate is generic over them.
type TestEvent = SentryEventLike & { message?: string };

const event = (message: string): TestEvent => ({ message });

const json = (body: unknown, init: { status?: number; contentType?: string } = {}) =>
  new Response(typeof body === 'string' ? body : JSON.stringify(body), {
    status: init.status ?? 200,
    headers: { 'content-type': init.contentType ?? 'application/json' },
  });

const ok = (overrides: Record<string, unknown> = {}) =>
  json({ enabled: true, scope: 'frontend', environment: 'staging', source: 'database', poll_interval: 60, ...overrides });

const silentLogger = { log: vi.fn(), warn: vi.fn() };

function make(fetchImpl: unknown, extra: Record<string, unknown> = {}) {
  let clock = 0;
  const instance = createSentrifig({
    url: '/sentrifig/state',
    fetchImpl: fetchImpl as typeof fetch,
    now: () => clock,
    persist: false,
    logger: silentLogger,
    ...extra,
  });
  return { instance, advance: (ms: number) => (clock += ms) };
}

beforeEach(() => {
  silentLogger.log.mockClear();
  silentLogger.warn.mockClear();
  sessionStorage.clear();
});

describe('gating', () => {
  it('passes events through before the first response', () => {
    const { instance } = make(vi.fn().mockReturnValue(new Promise(() => {})));
    const e = event('boom');
    expect(instance.eventProcessor(e)).toBe(e);
    expect(instance.state().source).toBe('default');
  });

  it('returns null once the server says disabled', async () => {
    const { instance } = make(vi.fn().mockResolvedValue(ok({ enabled: false })));
    await instance.refresh();
    expect(instance.eventProcessor(event('boom'))).toBeNull();
    expect(instance.state()).toMatchObject({ enabled: false, source: 'server', scope: 'frontend' });
  });

  it('passes the event object through untouched when enabled', async () => {
    const { instance } = make(vi.fn().mockResolvedValue(ok()));
    await instance.refresh();
    const e = event('fine');
    expect(instance.eventProcessor(e)).toBe(e);
  });

  it('fails open if the gate itself throws', () => {
    const { instance } = make(vi.fn().mockResolvedValue(ok()));
    const exploding = {
      get breadcrumbs(): never {
        throw new Error('exploding event');
      },
    };
    expect(instance.eventProcessor(exploding as never)).toBe(exploding);
    expect(silentLogger.warn).toHaveBeenCalledWith(
      '[sentrifig] gate error, passing event through:',
      expect.any(Error),
    );
  });

  it('strips its own poll breadcrumbs without mutating the caller array', async () => {
    const { instance } = make(vi.fn().mockResolvedValue(ok()));
    await instance.refresh();

    const breadcrumbs = [{ data: { url: '/sentrifig/state' } }, { data: { url: '/graphql' } }];
    const withCrumbs = { breadcrumbs };
    const result = instance.eventProcessor(withCrumbs)!;

    expect(result.breadcrumbs).toHaveLength(1);
    expect(breadcrumbs).toHaveLength(2);
  });
});

describe('fetching and caching', () => {
  it('trusts the snapshot until the server-provided interval elapses', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(ok({ poll_interval: 60 }));
    const { instance, advance } = make(fetchImpl);

    await instance.refresh();
    expect(fetchImpl).toHaveBeenCalledTimes(1);
    expect(instance.state().ttl).toBe(60_000);

    advance(59_999);
    instance.enabled();
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    advance(2);
    instance.enabled();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });

  it('collapses an error storm into a single request', () => {
    const fetchImpl = vi.fn().mockReturnValue(new Promise(() => {}));
    const { instance } = make(fetchImpl);

    for (let i = 0; i < 1000; i += 1) instance.eventProcessor(event(String(i)));

    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('sends the bearer token only when there is one', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(ok());
    let token: string | null = null;
    const { instance } = make(fetchImpl, { getToken: () => token });

    await instance.refresh();
    expect(fetchImpl.mock.calls[0][1].headers).not.toHaveProperty('Authorization');

    token = 'abc123';
    await instance.refresh();
    expect(fetchImpl.mock.calls[1][1].headers['Authorization']).toBe('Bearer abc123');
  });

  it('treats 401 as "not logged in yet": no log, no state change, longer wait', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(json({ error: 'unauthorized' }, { status: 401 }));
    const { instance, advance } = make(fetchImpl, { unauthenticatedTtl: 60_000 });

    await instance.refresh();

    expect(instance.state()).toMatchObject({ enabled: true, source: 'default' });
    expect(silentLogger.warn).not.toHaveBeenCalled();

    advance(59_000);
    instance.enabled();
    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });

  it('keeps the last known value when the endpoint fails, and marks it stale', async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValueOnce(ok({ enabled: false }))
      .mockRejectedValue(new Error('network down'));
    const { instance, advance } = make(fetchImpl);

    await instance.refresh();
    expect(instance.state().enabled).toBe(false);

    advance(120_000);
    await instance.refresh();

    expect(instance.state()).toMatchObject({ enabled: false, source: 'fallback' });
    expect(instance.eventProcessor({})).toBeNull();
  });

  it('logs a failure once per outage and logs the recovery', async () => {
    const fetchImpl = vi
      .fn()
      .mockRejectedValueOnce(new Error('down'))
      .mockRejectedValueOnce(new Error('down'))
      .mockResolvedValue(ok({ enabled: false }));
    const { instance, advance } = make(fetchImpl);

    await instance.refresh();
    advance(600_000);
    await instance.refresh();
    expect(silentLogger.warn).toHaveBeenCalledTimes(1);

    advance(600_000);
    await instance.refresh();
    expect(silentLogger.log).toHaveBeenCalledWith('[sentrifig] endpoint reachable again; Sentry disabled');
  });

  it('backs off exponentially, capped', async () => {
    const fetchImpl = vi.fn().mockRejectedValue(new Error('down'));
    const { instance, advance } = make(fetchImpl, { ttl: 1_000, maxBackoff: 4_000 });

    await instance.refresh(); // failure 1 -> 1s
    advance(999);
    instance.enabled();
    expect(fetchImpl).toHaveBeenCalledTimes(1);

    advance(2);
    await instance.refresh(); // failure 2 -> 2s
    advance(1_999);
    instance.enabled();
    expect(fetchImpl).toHaveBeenCalledTimes(2);

    advance(2);
    await instance.refresh(); // failure 3 -> 4s, capped
    advance(4_001);
    instance.enabled();
    expect(fetchImpl).toHaveBeenCalledTimes(4);
  });

  it('treats an SPA index.html fallback as unreachable rather than crashing', async () => {
    const fetchImpl = vi
      .fn()
      .mockResolvedValue(json('<!DOCTYPE html><html></html>', { contentType: 'text/html; charset=utf-8' }));
    const { instance } = make(fetchImpl);

    await instance.refresh();

    expect(instance.state()).toMatchObject({ enabled: true, source: 'default' });
    expect(silentLogger.warn.mock.calls[0][0]).toContain('unexpected content-type');
  });

  it('treats a malformed payload as unreachable', async () => {
    const { instance } = make(vi.fn().mockResolvedValue(json({ enabled: 'yes' })));
    await instance.refresh();
    expect(instance.state().source).toBe('default');
    expect(silentLogger.warn.mock.calls[0][0]).toContain('malformed payload');
  });

  it('treats a non-2xx as unreachable', async () => {
    const { instance } = make(vi.fn().mockResolvedValue(json({}, { status: 500 })));
    await instance.refresh();
    expect(silentLogger.warn.mock.calls[0][0]).toContain('HTTP 500');
  });

  it('notifies onStateChange only when the state actually changes', async () => {
    const onStateChange = vi.fn();
    const fetchImpl = vi.fn().mockResolvedValue(ok({ enabled: false }));
    const { instance } = make(fetchImpl, { onStateChange });

    await instance.refresh();
    await instance.refresh();

    expect(onStateChange).toHaveBeenCalledTimes(1);
    expect(onStateChange).toHaveBeenCalledWith(expect.objectContaining({ enabled: false }));
  });

  it('stop() halts refreshing', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(ok());
    const { instance, advance } = make(fetchImpl);

    await instance.refresh();
    instance.stop();
    advance(600_000);
    instance.enabled();

    expect(fetchImpl).toHaveBeenCalledTimes(1);
  });
});

describe('sessionStorage seed', () => {
  it('starts from a recent seed instead of the default', async () => {
    const first = createSentrifig({
      url: '/sentrifig/state',
      fetchImpl: vi.fn().mockResolvedValue(ok({ enabled: false })) as never,
      logger: silentLogger,
    });
    await first.refresh();

    const second = createSentrifig({
      url: '/sentrifig/state',
      fetchImpl: vi.fn().mockReturnValue(new Promise(() => {})) as never,
      logger: silentLogger,
    });

    expect(second.state()).toMatchObject({ enabled: false, source: 'session' });
    expect(second.eventProcessor({})).toBeNull();
  });

  it('ignores a seed older than seedMaxAge, so a stale "off" cannot outlive a re-enable', async () => {
    const first = createSentrifig({
      url: '/sentrifig/state',
      fetchImpl: vi.fn().mockResolvedValue(ok({ enabled: false })) as never,
      logger: silentLogger,
    });
    await first.refresh();

    const nowSpy = vi.spyOn(Date, 'now').mockReturnValue(Date.now() + 600_000);
    try {
      const second = createSentrifig({
        url: '/sentrifig/state',
        fetchImpl: vi.fn().mockReturnValue(new Promise(() => {})) as never,
        logger: silentLogger,
      });
      expect(second.state()).toMatchObject({ enabled: true, source: 'default' });
    } finally {
      nowSpy.mockRestore();
    }
  });

  it('survives storage being unavailable', () => {
    const spy = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('SecurityError');
    });
    try {
      expect(() =>
        createSentrifig({ url: '/sentrifig/state', fetchImpl: vi.fn() as never, logger: silentLogger }),
      ).not.toThrow();
    } finally {
      spy.mockRestore();
    }
  });

  it('reset() clears the seed and forces an immediate refetch', async () => {
    const fetchImpl = vi.fn().mockResolvedValue(ok({ enabled: false }));
    const instance = createSentrifig({
      url: '/sentrifig/state',
      fetchImpl: fetchImpl as never,
      logger: silentLogger,
    });

    await instance.refresh();
    expect(sessionStorage.getItem('sentrifig:/sentrifig/state')).not.toBeNull();

    instance.reset();

    expect(instance.state()).toMatchObject({ enabled: true, source: 'default' });
    expect(sessionStorage.getItem('sentrifig:/sentrifig/state')).toBeNull();
    instance.enabled();
    expect(fetchImpl).toHaveBeenCalledTimes(2);
  });
});

describe('installGate', () => {
  it('registers the processor on the global scope', () => {
    const addEventProcessor = vi.fn();
    const { instance } = make(vi.fn().mockResolvedValue(ok()));

    installGate({ getGlobalScope: () => ({ addEventProcessor }) }, instance);

    expect(addEventProcessor).toHaveBeenCalledWith(instance.eventProcessor);
  });
});

describe('the gem contract', () => {
  it('accepts the exact body the Ruby state endpoint renders', async () => {
    const fixture = JSON.parse(
      // Kept in step with test/controllers/state_controller_test.rb.
      '{"enabled":false,"scope":"frontend","environment":"staging","source":"database","poll_interval":60}',
    );
    const { instance } = make(vi.fn().mockResolvedValue(json(fixture)));

    await instance.refresh();

    expect(instance.state()).toEqual({
      enabled: false,
      scope: 'frontend',
      environment: 'staging',
      ttl: 60_000,
      source: 'server',
    });
  });
});
