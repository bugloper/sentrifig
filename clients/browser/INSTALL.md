# Installing `sentrifig-browser` in a frontend

A step-by-step guide to gating a browser Sentry SDK on the
[`sentrifig`](https://github.com/bugloper/sentrifig) runtime switch, so an operator can turn
frontend Sentry off without a rebuild or a redeploy.

Covers Angular and React. The package itself contains no framework code — only the bootstrap hook
differs between them, and that is about five lines of your own app.

---

## 1. Prerequisites — the backend half

**None of this works until a Rails app running `sentrifig` serves the state endpoint.** Check that
first; it is the single most common reason a correct frontend install appears to do nothing.

- [ ] The Rails app runs **sentrifig >= 0.2.0** and has run the migration.
- [ ] `Sentrifig::Engine` is mounted (typically at `/sentrifig`).
- [ ] `config.client_authenticator` is set, **and it understands the credential your frontend
      actually sends** (§4). Unset means every request is refused with 401, so the browser never
      learns the state and (correctly) keeps sending.
- [ ] The endpoint is reachable from the browser's origin — see §5.

Verify with curl before you touch any frontend code:

```bash
curl -i -H "Authorization: Bearer <a valid app token>" https://your-app.example.com/sentrifig/state
```

You want `200` and `content-type: application/json`:

```json
{"enabled":true,"scope":"frontend","environment":"production","source":"database","poll_interval":60}
```

| What you got | What it means |
|---|---|
| `200 application/json` | Ready. |
| `401` | Either the token is wrong, or `client_authenticator` is unset — check the app log for `[sentrifig] refusing request … client_authenticator is not set`. |
| `404` | The engine is not mounted, or the path is not routed to this service. |
| `200 text/html` | Your SPA's `index.html`. The path is being served by the frontend, not proxied to the backend — see §5. |

## 2. Install

```bash
npm install sentrifig-browser     # or: yarn add sentrifig-browser
```

Zero runtime dependencies, and no `@sentry/*` dependency — not even a peer one. It ships ESM, CJS
and types, built for ES2017.

## 3. Wire it up

The package is deliberately lazy: it does not fetch at construction. Call `refresh()` once at
startup so the very first error of a session is gated correctly.

### Angular (NgModule)

```ts
// app.module.ts
import * as Sentry from '@sentry/angular';
import {APP_INITIALIZER, NgModule} from '@angular/core';
import {createSentrifig, installGate, Sentrifig} from 'sentrifig-browser';

import {environment} from '../environments/environment';

let instance: Sentrifig | null = null;

export function startSentrifig(): void {
  if (instance) return;

  try {
    instance = createSentrifig({
      url: `${environment.apiBaseUrl ?? ''}/sentrifig/state`,
      // However YOUR app holds its credentials -- see "Authentication" below.
      getToken: () => myAuthService.accessToken
    });

    installGate(Sentry, instance);
    void instance.refresh();
  } catch (error) {
    // Never let the switch be the reason Sentry stops working.
    console.warn('[sentrifig] could not start; Sentry left untouched:', error);
  }
}

export function sentrifig(): Sentrifig | null {
  return instance;
}

@NgModule({
  providers: [
    {
      provide: APP_INITIALIZER,
      useFactory: () => (): void => {
        Sentry.init({/* … */});
      },
      multi: true
    },
    {
      // Its own initializer, not a line inside the one above: ordering is
      // irrelevant (the global scope exists before any init) and keeping them
      // separate avoids pushing that factory past max-lines-per-function.
      provide: APP_INITIALIZER,
      useFactory: () => (): void => {
        startSentrifig();
      },
      multi: true
    }
  ]
})
export class AppModule {}
```

**Keep the factory returning `void`.** Return a `Promise` and Angular will block bootstrap on the
network — which this explicitly must not do.

In an Nx workspace, put this in a **shared lib**, not in the app, if anything outside the app needs
`sentrifig()` (a login component, say). A lib importing from an app violates
`@nx/enforce-module-boundaries`.

### Angular (standalone)

Same `startSentrifig` as above; only the provider changes.

```ts
// main.ts
import {APP_INITIALIZER} from '@angular/core';
import {bootstrapApplication} from '@angular/platform-browser';

bootstrapApplication(AppComponent, {
  providers: [
    {
      provide: APP_INITIALIZER,
      useFactory: () => (): void => {
        startSentrifig();
      },
      multi: true
    }
  ]
});
```

On **Angular 19+** the terser `provideAppInitializer(() => startSentrifig())` does the same thing.
It does not exist before v19, so the form above is what to use on v18.

### React

```tsx
// main.tsx
import * as Sentry from '@sentry/react';
import {createRoot} from 'react-dom/client';
import {createSentrifig, installGate} from 'sentrifig-browser';

Sentry.init({dsn: import.meta.env.VITE_SENTRY_DSN});

export const sentrifig = createSentrifig({
  url: `${import.meta.env.VITE_API_BASE_URL ?? ''}/sentrifig/state`,
  // However YOUR app holds its credentials -- see "Authentication" below.
  getToken: () => authStore.getState().accessToken
});

installGate(Sentry, sentrifig);
void sentrifig.refresh();

createRoot(document.getElementById('root')!).render(<App />);
```

Nothing is awaited, so first paint is not delayed.

### Any other framework, or none

```ts
installGate(Sentry, instance);
// identical to:
Sentry.getGlobalScope().addEventProcessor(instance.eventProcessor);
```

`installGate` is duck-typed, so it works with `@sentry/browser`, `@sentry/react`,
`@sentry/angular`, `@sentry/vue` and so on without the package depending on any of them.

> **Use the global scope, not `Sentry.addEventProcessor`.** That one writes to the *isolation*
> scope, which is not the same thing and will not gate reliably.

### Two optional hooks worth adding

```ts
// Right after a token lands, so you do not wait out the unauthenticated backoff.
// Without this there is a blind spot immediately after login.
sentrifig()?.refresh();

// On logout, so the next user does not inherit the previous one's state.
sentrifig()?.reset();
```

The first is worth it on its own. The second matters most on shared workstations.

## 4. Authentication — however your app does it

The endpoint requires a logged-in application user. **The package makes no assumption about how
your app authenticates**, and neither does the gem: the Rails side decides via
`config.client_authenticator`, and the browser side just has to send whatever that check expects.

Pick the row that matches your app.

### Cookie-based sessions — nothing to configure

If your API already authenticates with a session cookie, send nothing. `credentials` defaults to
`'include'`, so the cookie rides along:

```ts
createSentrifig({url: '/sentrifig/state'});
```

### A bearer token

`getToken` is sugar for `Authorization: Bearer <token>`. It is called **per request**, so it always
sees the current value — never capture the token once at startup.

```ts
createSentrifig({
  url: '/sentrifig/state',
  getToken: () => myAuthService.accessToken        // in-memory
  // getToken: () => localStorage.getItem('access_token')
  // getToken: () => oidcUserManager.getUser()?.access_token
});
```

Returning `null` before login is fine and expected: the request comes back 401, which the client
treats as "not logged in yet" rather than an error — no log, no backoff escalation, and Sentry keeps
sending.

### Any other scheme — a custom header, or an async token

`headers` gives you full control, and may be async if the token has to be read from an async store
or refreshed first. It is merged over anything `getToken` produced, so it wins on conflict.

```ts
createSentrifig({
  url: '/sentrifig/state',
  headers: () => ({'X-Auth-Token': session.token})
});

createSentrifig({
  url: '/sentrifig/state',
  headers: async () => ({Authorization: `Bearer ${await auth.getAccessToken()}`})
});
```

### Whatever you send, the backend must accept it

This is the half people forget. The gem delegates the decision to the host app, so a Rails app that
authenticates with, say, a session cookie needs its `client_authenticator` written accordingly:

```ruby
# config/initializers/sentrifig.rb
config.client_authenticator = ->(request) { MyAuth.user_from(request).present? }
```

It receives an `ActionDispatch::Request`, so it can read headers, cookies or anything else on the
request. If it only understands session cookies and your SPA only sends a bearer token, you get a
permanent 401 — the switch will never take effect, though Sentry keeps working. Test the two ends
together.

## 5. Make the endpoint reachable

**Same-origin (recommended).** If your SPA and the Rails app are served under one host, use a
root-relative URL (`/sentrifig/state`) and you are done — *provided* your ingress or reverse proxy
routes that path to the backend. A static-file SPA image with a `try_files $uri /index.html`
fallback will otherwise answer `200 text/html`, and the client will treat that as unreachable and
keep Sentry on. That is a routing bug, not a package bug; the console tells you so:

```
[sentrifig] could not read state (Error: unexpected content-type "text/html; charset=utf-8");
keeping Sentry enabled (default), retrying with backoff
```

**Cross-origin** (typically local development against a deployed API). The backend needs CORS with
credentials — an explicit origin, not `*`, and `Authorization` in the allowed headers. The gem ships
no CORS handling of its own; configure it in the host app (for a Rails app, `rack-cors`).

## 6. Verify

1. Load the app logged in. In DevTools → Network, filter for `state`: **exactly one** request,
   `200 application/json`.
2. Flip the **frontend** switch on the sentrifig dashboard.
3. Back in the tab, **without reloading**, wait out `poll_interval` and throw an error from the
   console. Nothing should be sent to Sentry, and the console shows
   `[sentrifig] Sentry disabled (picked up from server)`.
4. Re-enable it. The next error flows again — no reload, no redeploy.

Confirm the backend switch is untouched throughout: `bin/rails sentrifig:status` should still show
the backend as `ENABLED`.

During development, exposing the instance makes this much easier:

```ts
if (!environment.production) {
  (window as never as Record<string, unknown>)['__sentrifig'] = instance;
}
```

Then `__sentrifig.state()` returns `{enabled, environment, scope, ttl, source}`.

## 7. What to expect in production

- **Errors, transactions and session replays all stop together.** One processor covers them,
  because all three pass through Sentry's `prepareEvent`.
- **Breadcrumbs, tags and user context keep accumulating** while disabled, so the first event after
  re-enabling carries full context. Disabling stops *delivery*, not instrumentation — which is why
  re-enabling is instant, and why this is not a performance lever.
- **Sentry's client reports still show the drops**, as `discarded_events` with
  `reason: "event_processor"`. That is your positive confirmation the gate is working rather than
  events being lost silently.
- **Errors before login are still sent.** The SDK starts enabled and applies the real state when it
  arrives, so nothing is lost to a switch the client could not yet read. The cost is that an
  operator who disabled the switch still sees pre-login noise.

## 8. Troubleshooting

| Symptom | Cause |
|---|---|
| Nothing in Network at all | `refresh()` never called, and no event has been raised yet. The instance is lazy by design. |
| `401` on every request | Not logged in yet (normal on a login screen — no log, longer backoff), or the backend's `client_authenticator` is unset. |
| `401` even when clearly logged in | The two ends disagree about the credential: the frontend sends one thing, `client_authenticator` checks for another. Log what the lambda receives. See §4. |
| `200 text/html` | The path is not routed to the backend. See §4. |
| Console: `could not read state … keeping Sentry enabled` | The endpoint is unreachable. Sentry keeps working — this is the fail-open path, by design. |
| Switch flipped but events still sending | Wait out `poll_interval`; the client only re-reads on its next event. Also check you flipped the **frontend** scope, not the backend one. |
| A stale `disabled` after re-enabling | The `sessionStorage` seed, capped at 5 minutes. `reset()`, or open a new tab. |
| Native browser login popup | Something is returning `WWW-Authenticate`. The gem's state endpoint deliberately does not; you are probably hitting the Basic-auth dashboard path instead of `/state`. |

## 9. Uninstalling

Remove the `installGate` call and the dependency. Nothing persists but a per-tab `sessionStorage`
key that expires on its own, and the backend switch is unaffected.
