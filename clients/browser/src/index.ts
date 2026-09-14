/**
 * sentrifig-browser -- runtime on/off switch for the Sentry browser SDK.
 *
 * Mirrors the Ruby gem's data plane deliberately: a single event processor that
 * returns null when disabled, reading an in-memory snapshot that is refreshed
 * from the backend at most once per TTL, and failing OPEN whenever anything
 * goes wrong. The switch must never be the reason an error goes unreported.
 */

/** The shape we actually touch on a Sentry event. Structural on purpose: this
 *  package has no @sentry/* dependency, not even a peer one, so it never has to
 *  track Sentry's major versions.
 *
 *  Deliberately no index signature: one would stop Sentry's own `Event` being
 *  assignable to this, and the whole point is that `eventProcessor` can be
 *  handed straight to `addEventProcessor`. */
export interface SentryEventLike {
  breadcrumbs?: Array<{ data?: Record<string, unknown> } | null | undefined>;
}

export type StateSource = 'default' | 'server' | 'session' | 'fallback';

export interface SentrifigState {
  enabled: boolean;
  environment?: string;
  scope?: string;
  /** Milliseconds this snapshot is trusted for. */
  ttl: number;
  source: StateSource;
}

export interface SentrifigOptions {
  /** Absolute or root-relative URL of the gem's state endpoint. */
  url: string;
  /** Returns the app's auth token, if it has one yet. Called per request. */
  getToken?: () => string | null | undefined;
  credentials?: RequestCredentials;
  /** What to assume before the first successful response. Default true. */
  defaultEnabled?: boolean;
  /** Fallback TTL in ms when the server does not send poll_interval. Default 60_000. */
  ttl?: number;
  /** How long to wait after a 401/403 before asking again. Default 60_000. */
  unauthenticatedTtl?: number;
  /** Ceiling for the failure backoff. Default 300_000. */
  maxBackoff?: number;
  /** Seed the first snapshot from sessionStorage. Default true. */
  persist?: boolean;
  /** Ignore a persisted seed older than this. Default 300_000 (5 minutes). */
  seedMaxAge?: number;
  /** Strip this package's own fetch breadcrumbs from outgoing events. Default true. */
  filterOwnBreadcrumbs?: boolean;
  onStateChange?: (state: SentrifigState) => void;
  logger?: Pick<Console, 'log' | 'warn'>;
  fetchImpl?: typeof fetch;
  /** Monotonic clock in ms. Injected by tests. */
  now?: () => number;
}

export interface Sentrifig {
  /** Register this with Sentry.getGlobalScope().addEventProcessor(...).
   *  Generic so it satisfies Sentry's EventProcessor, which must return the
   *  same event type it was given. */
  readonly eventProcessor: <T extends SentryEventLike>(event: T, hint?: unknown) => T | null;
  enabled(): boolean;
  state(): SentrifigState;
  /** Forces a read now. Never rejects. */
  refresh(): Promise<void>;
  /** Back to the default and drop any cached state. Call on logout. */
  reset(): void;
  /** Stop refreshing entirely. */
  stop(): void;
}

const STORAGE_PREFIX = 'sentrifig:';

const DEFAULTS = {
  defaultEnabled: true,
  ttl: 60_000,
  unauthenticatedTtl: 60_000,
  maxBackoff: 300_000,
  persist: true,
  seedMaxAge: 300_000,
  filterOwnBreadcrumbs: true,
  credentials: 'include' as RequestCredentials,
};

export function createSentrifig(options: SentrifigOptions): Sentrifig {
  const o = { ...DEFAULTS, ...options };
  const log = o.logger ?? console;
  const doFetch = o.fetchImpl ?? (typeof fetch === 'function' ? fetch.bind(globalThis) : undefined);

  // Monotonic for the TTL, mirroring the gem's CLOCK_MONOTONIC. Wall clock is
  // used only for the persisted seed's age, where it is the only measure that
  // survives a reload.
  const mono =
    o.now ?? (() => (typeof performance !== 'undefined' ? performance.now() : Date.now()));

  const storageKey = STORAGE_PREFIX + o.url;

  let state: SentrifigState =
    readSeed() ?? { enabled: o.defaultEnabled, ttl: o.ttl, source: 'default' };
  let nextRefreshAt = 0;
  let inFlight: Promise<void> | null = null;
  let consecutiveFailures = 0;
  let failureLogged = false;
  let gateErrorLogged = false;
  let stopped = false;

  // --- hot path -------------------------------------------------------------

  function enabled(): boolean {
    if (!stopped && mono() >= nextRefreshAt) void refresh();
    return state.enabled;
  }

  const eventProcessor = <T extends SentryEventLike>(event: T): T | null => {
    try {
      if (!enabled()) return null;

      if (o.filterOwnBreadcrumbs && event.breadcrumbs && event.breadcrumbs.length > 0) {
        const kept = event.breadcrumbs.filter((b) => b?.data?.['url'] !== o.url);
        // notifyEventProcessors hands us a shallow clone, so the breadcrumbs
        // array is shared with the caller. Copy rather than mutate.
        if (kept.length !== event.breadcrumbs.length) return { ...event, breadcrumbs: kept };
      }

      return event;
    } catch (err) {
      // Fail open: never let the switch itself lose an event.
      if (!gateErrorLogged) {
        gateErrorLogged = true;
        log.warn('[sentrifig] gate error, passing event through:', err);
      }
      return event;
    }
  };

  // --- control plane --------------------------------------------------------

  function refresh(): Promise<void> {
    if (inFlight) return inFlight;
    if (!doFetch) {
      defer(state.ttl);
      return Promise.resolve();
    }
    // Reserve the window BEFORE awaiting, so an error storm collapses into one
    // request and a hung fetch cannot spawn a second before its TTL is up.
    defer(state.ttl);
    // Not Promise#finally: that is ES2018, and this package targets ES2017 to
    // match the apps that consume it.
    const clear = () => {
      inFlight = null;
    };
    const pending = load().then(clear, clear);
    inFlight = pending;
    return pending;
  }

  async function load(): Promise<void> {
    try {
      const headers: Record<string, string> = { Accept: 'application/json' };
      const token = o.getToken?.();
      if (token) headers['Authorization'] = `Bearer ${token}`;

      const res = await doFetch!(o.url, {
        method: 'GET',
        headers,
        credentials: o.credentials,
        cache: 'no-store',
        redirect: 'follow',
      });

      // Not logged in yet. Entirely normal on a login screen, so this is not an
      // error: no log line, no backoff escalation, just ask again later.
      if (res.status === 401 || res.status === 403) {
        consecutiveFailures = 0;
        failureLogged = false;
        defer(o.unauthenticatedTtl);
        return;
      }

      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      // An SPA served by `try_files ... /index.html` answers 200 text/html for
      // an unrouted path. Treat that as unreachable, not as a parse crash.
      const contentType = res.headers.get('content-type') ?? '';
      if (!/\bapplication\/json\b/i.test(contentType)) {
        throw new Error(`unexpected content-type "${contentType}"`);
      }

      const body: unknown = await res.json();
      if (!body || typeof body !== 'object' || typeof (body as Record<string, unknown>)['enabled'] !== 'boolean') {
        throw new Error('malformed payload');
      }

      apply(body as Record<string, unknown>);
    } catch (err) {
      onFailure(err);
    }
  }

  function apply(body: Record<string, unknown>): void {
    const pollInterval = body['poll_interval'];
    const ttl = typeof pollInterval === 'number' && pollInterval > 0 ? pollInterval * 1000 : o.ttl;

    const next: SentrifigState = {
      enabled: body['enabled'] as boolean,
      environment: typeof body['environment'] === 'string' ? body['environment'] : undefined,
      scope: typeof body['scope'] === 'string' ? body['scope'] : undefined,
      ttl,
      source: 'server',
    };

    if (failureLogged) {
      log.log(`[sentrifig] endpoint reachable again; Sentry ${word(next.enabled)}`);
    } else if (state.source !== 'default' && state.enabled !== next.enabled) {
      log.log(`[sentrifig] Sentry ${word(next.enabled)} (picked up from server)`);
    }

    consecutiveFailures = 0;
    failureLogged = false;

    const changed = state.enabled !== next.enabled || state.source !== next.source;
    state = next;
    writeSeed(next);
    defer(ttl);

    if (changed) {
      try {
        o.onStateChange?.(next);
      } catch {
        // A host callback must never break the gate.
      }
    }
  }

  function onFailure(err: unknown): void {
    consecutiveFailures += 1;

    if (!failureLogged) {
      failureLogged = true;
      log.warn(
        `[sentrifig] could not read state (${String(err)}); keeping Sentry ` +
          `${word(state.enabled)} (${state.source}), retrying with backoff`,
      );
    }

    // The last known value stays in effect, marked so a host can tell it is stale.
    if (state.source === 'server' || state.source === 'session') {
      state = { ...state, source: 'fallback' };
    }

    defer(Math.min(state.ttl * Math.pow(2, consecutiveFailures - 1), o.maxBackoff));
  }

  function defer(ms: number): void {
    nextRefreshAt = mono() + ms;
  }

  function reset(): void {
    state = { enabled: o.defaultEnabled, ttl: o.ttl, source: 'default' };
    consecutiveFailures = 0;
    failureLogged = false;
    nextRefreshAt = 0;
    clearSeed();
  }

  function stop(): void {
    stopped = true;
  }

  // --- sessionStorage seed --------------------------------------------------
  //
  // Without it, every reload of a disabled environment starts enabled and ships
  // a burst of boot-time errors -- exactly the noise the operator turned the
  // switch off to stop. seedMaxAge bounds the opposite risk, a stale `false`
  // outliving a re-enable. sessionStorage, not localStorage: per tab, gone when
  // the tab closes, and it cannot outlive a user on a shared workstation.

  function readSeed(): SentrifigState | null {
    if (!o.persist) return null;
    try {
      const raw = sessionStorage.getItem(storageKey);
      if (!raw) return null;

      const parsed = JSON.parse(raw);
      if (typeof parsed?.storedAt !== 'number' || typeof parsed?.state?.enabled !== 'boolean') {
        return null;
      }
      if (Date.now() - parsed.storedAt > o.seedMaxAge) return null;

      return { ...parsed.state, source: 'session' };
    } catch {
      return null;
    }
  }

  function writeSeed(s: SentrifigState): void {
    if (!o.persist) return;
    try {
      sessionStorage.setItem(storageKey, JSON.stringify({ storedAt: Date.now(), state: s }));
    } catch {
      // Private mode, quota, storage disabled entirely.
    }
  }

  function clearSeed(): void {
    if (!o.persist) return;
    try {
      sessionStorage.removeItem(storageKey);
    } catch {
      // As above.
    }
  }

  return { eventProcessor, enabled, state: () => state, refresh, reset, stop };
}

/**
 * Convenience wiring. Duck-typed so this package never imports @sentry/*:
 *
 *   installGate(Sentry, sentrifig);
 *
 * The global scope is the right home -- its processors are applied to ALL
 * events, are read at event time, and survive a re-init. (The isolation-scope
 * `Sentry.addEventProcessor` is NOT equivalent.)
 */
export function installGate(
  sentry: { getGlobalScope(): { addEventProcessor(processor: unknown): unknown } },
  instance: Sentrifig,
): void {
  sentry.getGlobalScope().addEventProcessor(instance.eventProcessor);
}

function word(enabled: boolean): string {
  return enabled ? 'enabled' : 'disabled';
}
