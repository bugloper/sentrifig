# selise-sentry: architecture and design notes

This document records the investigation that preceded the implementation, the
decisions taken, the alternatives rejected, and the measured characteristics.
The README explains how to use the gem; this explains why it is built the way
it is.

## 1. Goal

Let an operator turn Sentry on or off for one Rails environment at runtime,
with no deploy, restart, or environment-variable change, from a small
authenticated web UI or a rake task, in a way that is safe for production
(thread-safe, multi-process, fails open, negligible hot-path cost).

## 2. Where to intercept Sentry

### 2.1 What the SDK does (sentry-ruby 7.0.0, sentry-rails 7.0.0)

The capture path for every kind of event is:

```text
Sentry.capture_exception / capture_message / Transaction#finish / capture_check_in
  -> Hub#capture_event(event)
       -> Client#capture_event(event, scope, hint)
            -> return unless configuration.sending_allowed?      (DSN valid + enabled env)
            -> sample_rate check (errors only)
            -> scope.apply_to_event(event, hint)
                 -> merges tags/user/extra/contexts/breadcrumbs
                 -> runs Scope.global_event_processors + scope event_processors
                    (returning nil discards; transport.record_lost_event(:event_processor, ...))
            -> background worker (or inline) -> Client#send_event
                 -> before_send / before_send_transaction / before_send_check_in
                 -> transport.send_event
```

sentry-rails feeds the same path: `Sentry::Rails::CaptureExceptions` (Rack
middleware inserted after `ActionDispatch::ShowExceptions`) calls
`Sentry::Rails.capture_exception`; the `ErrorSubscriber` for `Rails.error.report`
does the same; ActiveJob and ActionCable extensions likewise.

Sentry Logs and Metrics do **not** go through `apply_to_event`; they go through
`Scope#apply_to_telemetry` into `LogEventBuffer`/`MetricEventBuffer`, whose
`before_send` hooks are read from the configuration when the `Client` is built.

`Sentry.init` builds a `Configuration`, a `Client`, a `Hub`, and the background
worker once. `Sentry.configuration` returns the live object and its setters
work after init, but anything the client copied at construction (log buffer
hooks, transport) does not follow later changes.

### 2.2 Options considered

| Option | Verdict | Reason |
| --- | --- | --- |
| Flip `Sentry.configuration.enabled_environments` / DSN at runtime | Rejected | Mutates the app's configuration; `sending_allowed?` also gates `event_from_exception`, so it works, but it is shared mutable state with unclear ownership, and `Sentry.close`/re-init loses it. Also affects `csp_report_uri` and session tracking. |
| Wrap `before_send`, `before_send_transaction`, `before_send_check_in` | Rejected | Three hooks to wrap and keep chained; lost if the app assigns `before_send` after we install; lives on the configuration object so it does not survive re-init. Runs in the background worker thread, which would have been a small plus. |
| Replace/wrap the transport | Rejected | Transport is per client, created at init; wrapping it is the closest thing to monkey-patching Sentry internals, and lost events would be attributed to the wrong reason. |
| Rack middleware / Rails-level short-circuit | Rejected | Only covers web requests; misses Sidekiq, ActiveJob, runner, manual captures. |
| **Global event processor** (`Sentry.add_global_event_processor`) | **Chosen** | Public, documented API. Stored on `Sentry::Scope` (class level), so it is independent of `Sentry.init` timing and survives re-init. One hook covers `ErrorEvent`, `TransactionEvent`, `CheckInEvent`. Returning `nil` is the SDK's own discard mechanism and is recorded as a lost event. Does not touch the application's configuration or callbacks. |

The processor runs on the calling thread (request or job thread) rather than
in the background worker. That is acceptable because the hot path is an
in-memory read; the only occasional cost is one indexed single-row query per
process per `cache_ttl`, and the runtime ensures at most one thread pays it
while others continue with the cached value.

### 2.3 Verification

Before writing the gem, a probe script against sentry-ruby 7.0.0 confirmed
with `Sentry::DummyTransport` that a `nil`-returning global processor:

- drops `capture_exception`, `capture_message`, and finished transactions;
- leaves the application's `before_send` unreached for dropped events and
  still called for accepted ones;
- records `{[:event_processor, "error"], [:event_processor, "transaction"], [:event_processor, "span"]}` as lost;
- leaves breadcrumbs, tags, and scope intact so the next accepted event
  carries them.

The test suite repeats these checks through the real Rails middleware.

## 3. State model

### 3.1 Key

State is keyed by **environment**, defaulting to `Rails.env`, overridable via
`config.environment`. Options considered:

- *Global (one flag)*: wrong when development and test share a database
  server, and not self-describing.
- *One table/database per environment*: that is already what separate
  environments give you for free; the gem should not manage databases.
- *Namespaced by environment in one table* (chosen): correct in every layout
  (per-environment databases hold one row; shared databases hold one row per
  environment), trivially indexable, self-describing.

`config.environment` exists for the one realistic mismatch: `Rails.env` is
`production` but the deployment is logically `staging` (usually
`SENTRY_ENVIRONMENT=staging`) *and* both share one database. Without a shared
database the default is always right.

### 3.2 Schema

```text
selise_sentry_settings
  id
  environment   string  not null, unique index
  enabled       boolean not null, default true
  changed_by    string  (Basic Auth username, "rake", or caller-supplied)
  created_at / updated_at
```

`changed_by` + `updated_at` are the lightweight audit trail requested; nothing
else is stored. No secrets, no DSN, no password.

Uniqueness is enforced by the index, not by an ActiveRecord validation. A
validation-level uniqueness check races under concurrent writers (both
threads pass validation, one insert fails with `RecordInvalid`); the
`ConcurrentUpdatesTest` found exactly that during development. The store
relies on `RecordNotUnique` from the index and retries against the winner's
row (up to 3 attempts).

### 3.3 Default

No row means `enabled_by_default` (true). Nothing is written on read. This
guarantees installing the gem cannot silently disable Sentry.

## 4. Caching and propagation

### 4.1 Runtime snapshot

`SeliseSentry::Runtime` holds:

```ruby
@snapshot        # frozen Struct(enabled, source, changed_by, changed_at) or nil
@next_refresh_at # monotonic seconds
@lock            # Mutex, used with try_lock on the hot path
@failing         # bool, for once-per-outage logging
```

`enabled?`:

```ruby
snapshot = @snapshot
snapshot = refresh_if_idle || snapshot if snapshot.nil? || clock >= @next_refresh_at
(snapshot || default).enabled
```

`refresh_if_idle` uses `try_lock`; if another thread is already refreshing,
the caller returns the current snapshot (or the default when nothing has been
loaded yet) without blocking. A stale-by-milliseconds value is preferable to
queuing request threads behind a database read.

Snapshots are immutable and replaced atomically (single reference assignment
under the GVL); readers never see a half-updated state.

### 4.2 Consistency model

> Immediate in the process that made the change; every other process within
> `cache_ttl` seconds (default 5) of its next Sentry event.

Reads happen only when an event is being processed, so idle processes never
query. Worst case propagation is exactly `cache_ttl` after the write.

### 4.3 Alternatives

- **Rails.cache as the shared layer**: not shared in dev/test (memory/null
  store), often not shared in prod (memory store); where it is shared it is a
  second dependency to read a value the database already serves in one
  indexed query. Would only be worth it with explicit invalidation, which
  needs pub/sub.
- **Redis pub/sub or Solid Cable / Action Cable broadcast** for instant
  invalidation: gives stronger consistency but mandates infrastructure the
  task explicitly forbids requiring. Could be added later as an optional
  invalidation hint without changing the data model.
- **Background polling thread**: would move the read off request threads but
  adds a thread per process, fork-safety concerns (Puma/Sidekiq/Spring), and
  still polls at some interval. The on-demand TTL read achieves the same bound
  with no thread.
- **Database read per event**: rejected outright (hot path).

## 5. Concurrency

- Readers: lock-free apart from `try_lock`; never block on the refresh.
- Writers: `find_or_initialize_by` + `save!` inside
  `connection_pool.with_connection`; `RecordNotUnique` retried. Last write
  wins on the row, which is the desired semantics for a kill switch.
- After `update!` the writing process installs the new snapshot under the lock
  so its own next event observes the change without a database round trip.
- `with_connection` prevents leaking pool connections from threads outside the
  Rails executor (Sidekiq threads, ad-hoc threads) when the gate triggers a
  refresh there.

## 6. Failure behaviour

| Failure | Behaviour |
| --- | --- |
| Table missing / DB down on read | keep last snapshot (or default), set `@failing`, log **once**, defer next attempt by `cache_ttl` |
| DB back | next refresh succeeds, log once, resume |
| DB down on write | `PersistenceError` raised to the caller (UI shows a generic alert, rake exits non-zero), snapshot unchanged, logged |
| Logger itself raises | swallowed; logging must never affect the data plane |
| Anything else inside the gate | event passed through (fail open), logged once |

Fail-open is the rule: the switch must never be the reason an error report is
lost. The only way to lose an event is to have deliberately disabled Sentry.

## 7. Security model

- Basic Auth on every engine route via one `before_action`;
  `ActiveSupport::SecurityUtils.secure_compare` over SHA-256 digests of username
  and password (so a length mismatch cannot short-circuit and leak credential
  length) with non-short-circuit `&` so timing does not reveal which one failed.
- Unconfigured credentials: refuse everything (401) and log an error. Safer
  than any fallback and does not affect the application.
- Mutations are `POST` only, `protect_from_forgery with: :exception`; forms
  are `button_to`, which embeds the authenticity token.
- Engine controllers inherit `ActionController::Base`, not the host's
  `ApplicationController`, so host filters cannot weaken or break the UI.
- `Cache-Control: no-store`, `noindex`.
- The view renders environment, state, `changed_by`, `changed_at`, TTL, and
  the gem version. Database error messages are logged, never rendered.
- Audit: log line per change with environment and operator; `changed_by` and
  `updated_at` on the row.

## 8. Performance

Measured on the development machine (Ruby 4.0.6, arm64), 1,000,000 iterations
with a warm cache:

| Operation | Cost |
| --- | --- |
| `SeliseSentry.enabled?` | ~390 ns |
| gate processor call (`PROCESSOR.call(event, hint)`) | ~530 ns |
| Database read | at most 1 per process per `cache_ttl`, single indexed row, only while events flow |
| Hot-path logging | none |

For comparison, Sentry's own `apply_to_event` merges several hashes and dups
the breadcrumb buffer per event; the gate is well below noise.

## 8a. Gem-owned Sentry.init (`SentrySetup`)

Selise applications carried an identical 150-line `config/initializers/sentry.rb`
each. The gem now owns it: `SeliseSentry::SentrySetup.apply_defaults` sets the
env-driven defaults (listed in the README), the Authorization-stripping
`before_send`, Sentry Logs off, and the path-aware traces sampler; blocks
registered through `SeliseSentry.configure { |c| c.sentry { |s| ... } }` run
afterwards.

Ordering is the interesting part. `Sentry.init` must happen after the
application's initializers (so overrides are known) but before
`after_initialize` (where sentry-rails wires controller extensions, tracing
subscribers, the error subscriber, and requires `Sentry.initialized?`). An
engine initializer declared `after: :load_config_initializers` depends on every
initializer of that name, one per railtie including the application, so Rails'
tsort places it after all `config/initializers` and still inside the
initializer phase. `Sentry.initialized?` is checked first so an application
that kept its own `Sentry.init` gets a warning instead of a double init, and
`config.initialize_sentry = false` opts out entirely.

Booleans from the environment are parsed (`true/1/yes/on`), not assigned. The
hand-written initializers did `config.send_default_pii = ENV.fetch("SENTRY_PII_ENABLE", false)`,
which makes the string `"false"` truthy: PII on and SDK debug logging on in
every deployment whose configmap spelled the flag out. Tracing is only enabled
when `SENTRY_TRACING_ENABLE` is true; the old initializers set a
`traces_sampler` unconditionally, which turned tracing on regardless of the
flag.

## 9. Rails integration

- `SeliseSentry::Engine` with `isolate_namespace`, standard `app/`, `config/routes.rb`,
  `db/migrate`, `lib/tasks`. Mounted with `mount SeliseSentry::Engine => "/selise-sentry"`.
- `config.after_initialize { SeliseSentry.install! }` registers the gate after
  the host's initializers (including `Sentry.init`) have run. Because the hook
  is class-level, ordering is not critical; `install!` is idempotent and keyed
  on the processor object identity, not a flag.
- The migration was generated with `rails g migration` (real timestamp) and
  pinned to `ActiveRecord::Migration[7.1]` so hosts on Rails 7.1 through 8.x
  run it unchanged. `rails selise_sentry:install` copies it with
  `ActiveRecord::Migration.copy` (the same mechanism as
  `railties:install:migrations`), re-stamping the timestamp and appending
  `.selise_sentry.rb`, and reports both copied and skipped files so it is safe
  to re-run.
- `Setting < ActiveRecord::Base` uses the primary connection.

## 10. Public API surface

```ruby
SeliseSentry.configure { |c| ...; c.sentry { |sentry| ... } }
SeliseSentry.configuration
SeliseSentry.enabled?
SeliseSentry.enable!(by: nil)
SeliseSentry.disable!(by: nil)
SeliseSentry.status        # Runtime::Status
SeliseSentry.current_environment
SeliseSentry.refresh!
SeliseSentry.install!
SeliseSentry.logger
SeliseSentry::SentrySetup::STRIP_AUTHORIZATION, DEFAULT_TRACES_SAMPLER
SeliseSentry::TestHelper   # require "selise_sentry/test_helper" or "selise_sentry/rspec"
```

Everything else (`Runtime`, `Store`, `Gate`, `Setting`) is implementation and
may change between minor versions.

## 11. Known limitations

See the README's "Known limitations": Sentry Logs/Metrics and release-health
sessions are not gated (their hooks are captured at client construction);
instrumentation overhead is unchanged while disabled; propagation is bounded
by `cache_ttl`, not instantaneous; the switch is per environment; verified
against sentry 7.0.0 / Rails 8.1 / Ruby 4.0 only.

## 12. Test strategy

- Unit: configuration validation; store upsert, isolation, race retry; runtime
  cache with an injected fake clock and fake store (TTL boundaries, single
  reader, outage/recovery logging, back-off, non-blocking readers, thread
  hammering).
- Integration (dummy Rails app, SQLite, `Sentry::DummyTransport`): manual
  captures, transactions, unhandled controller exceptions, `Rails.error.report`,
  UI toggle affecting capture in-process, TTL pickup of an external write,
  store failure fail-open.
- Controller: 401 paths, unconfigured credentials, dashboard content, no secret
  leakage, degraded rendering, POST/GET/other verbs, persistence failure
  alert, CSRF reject/accept with a real token.
- Rake: status/enable/disable share state; installer copies once and skips on
  re-run (temp directory).
- Boot: a subprocess boots the dummy app and asserts the gate is installed
  exactly once with no test-helper involvement.
- Manual smoke test (documented in the README) against Puma with curl and a
  second process running the rake tasks.
