# sentrifig-browser

Runtime on/off switch for the **Sentry browser SDK**, driven by the
[`sentrifig`](../../README.md) gem's state endpoint.

An operator flips the *frontend* switch on the gem's dashboard; every open browser tab stops
sending Sentry events within its poll interval. No rebuild, no redeploy, no reload.

Zero runtime dependencies, and **no `@sentry/*` dependency — not even a peer one**. The only
coupling is a structural type, so this package never has to track Sentry's major versions.

## Install

```bash
npm install sentrifig-browser
```

**New to this?** [INSTALL.md](INSTALL.md) is the step-by-step guide: backend prerequisites,
Angular and React bootstrap, making the endpoint reachable, and how to verify the switch actually
works end to end.

## Use

```ts
import * as Sentry from '@sentry/browser'; // or @sentry/angular, @sentry/react …
import { createSentrifig, installGate } from 'sentrifig-browser';

Sentry.init({ dsn: '…' });

const sentrifig = createSentrifig({
  url: '/sentrifig/state',
  getToken: () => myAuth.accessToken,   // or omit entirely for cookie auth
});

installGate(Sentry, sentrifig);

// Read the state once now; the instance is otherwise lazy. Never rejects.
void sentrifig.refresh();
```

`installGate` is one line of sugar for:

```ts
Sentry.getGlobalScope().addEventProcessor(sentrifig.eventProcessor);
```

**The global scope is the right home, and `Sentry.addEventProcessor` is not equivalent** — that
one writes to the *isolation* scope. Global-scope processors are applied to **all** events, are
read at event time, and survive a re-`init`, so registering before or after `Sentry.init` is
equally fine. One processor gates errors, transactions **and** session replays: all three pass
through `prepareEvent`, and returning `null` makes Sentry record a dropped event with reason
`event_processor`.

## Behaviour

It mirrors the gem's data plane deliberately.

- **Pull-on-demand, never `setInterval`.** State is refreshed from the hot path, at most once per
  TTL, so the switch is picked up on the next event after the TTL — which is the only moment it
  changes anything. The instance is otherwise **lazy**: left alone it would not ask until the first
  event. Call `refresh()` once after wiring it up (as the example above does not, but a real
  bootstrap should) so the very first error of the session is gated correctly; after that a tab
  that raises no events makes no further requests at all.
- **Fails open, always.** A network error, a non-2xx, a non-JSON content type, or a malformed body
  all keep the last known value (or the default, enabled) and log once per outage. The switch must
  never be the reason an error goes unreported.
- **401/403 is not an error.** Being logged out is the normal state on a login screen: no log, no
  backoff escalation, just a longer wait. Until the state is known the SDK sends, so errors during
  boot and login are always captured.
- **Content-type checked.** An SPA served by `try_files … /index.html` answers `200 text/html` for
  an unrouted path. That is treated as unreachable, not as a parse crash — which is what turns a
  missing ingress rule into a logged non-event instead of a breakage.
- **`sessionStorage` seed, capped at 5 minutes.** Without it, every reload of a disabled
  environment starts enabled and ships a burst of boot-time errors — exactly the noise the switch
  was flipped to stop. The cap bounds the opposite risk, a stale `false` outliving a re-enable.
- **Self-filtering breadcrumbs.** Its own poll would otherwise appear as a breadcrumb on every
  event, forever.

Disabling stops *delivery*, not *instrumentation*: breadcrumbs, tags and spans keep accumulating,
so the first event after re-enabling carries full context.

## Options

| Option | Default | |
|---|---|---|
| `url` | — | Required. The gem's state endpoint, absolute or root-relative. |
| `getToken` | — | Sugar for `Authorization: Bearer <token>`. Called per request; may return `null` before login. |
| `headers` | — | Full control over auth headers, for any other scheme. May be async. Merged over `getToken`. |
| `credentials` | `'include'` | Passed to `fetch`, so cookie-authenticated apps need no token plumbing at all. |
| `defaultEnabled` | `true` | What to assume before the first successful response. |
| `ttl` | `60_000` | Fallback, in ms. The server's `poll_interval` wins. |
| `unauthenticatedTtl` | `60_000` | Wait after a 401/403. |
| `maxBackoff` | `300_000` | Ceiling for the failure backoff. |
| `persist` / `seedMaxAge` | `true` / `300_000` | The `sessionStorage` seed. |
| `filterOwnBreadcrumbs` | `true` | Strip this package's own fetch breadcrumbs. |
| `onStateChange` | — | Called when the state actually changes. |
| `logger`, `fetchImpl`, `now` | — | Injection points, mostly for tests. |

## API

`createSentrifig(options)` returns `{ eventProcessor, enabled(), state(), refresh(), reset(), stop() }`.

- `refresh()` reads now instead of waiting for the TTL. Never rejects. Call it right after login to
  close the post-login blind spot.
- `reset()` returns to the default and clears the seed. Call it on logout so the next user does not
  inherit the previous one's state.
- `state()` returns `{ enabled, environment, scope, ttl, source }` where `source` is
  `'default' | 'server' | 'session' | 'fallback'` — `'fallback'` means the endpoint is unreachable
  and this value is stale.

## Development

```bash
npm install
npm test          # vitest
npm run typecheck
npm run build     # tsup -> dist/index.js (CJS), dist/index.mjs (ESM), dist/index.d.ts
```

Built for ES2017, with top-level `main`/`module`/`types` as well as `exports`, because consumers
on TypeScript's `moduleResolution: "node"` ignore `exports` entirely.

Versioned independently of the gem: the contract is in the gem's CHANGELOG, and a TypeScript fix
should not need a gem release.
