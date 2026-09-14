# sentrifig

A runtime on/off switch for [Sentry](https://sentry.io) in Rails applications.

`sentrifig` is a small extension around `sentry-ruby` and `sentry-rails`
that does two things for a Rails application:

1. **Owns the Sentry setup.** It calls `Sentry.init` with Selise's defaults,
   driven by the environment variables SELISE deployments already define
   (`SENTRY_DSN`, `SENTRY_ENABLED`, `RUNTIME_ENVIRONMENT`, sampling, tracing,
   PII), plus an Authorization-stripping `before_send`, Sentry Logs off, and a
   path-aware traces sampler. Applications keep no Sentry initializer; they
   register overrides through a block if they need any.
2. **Lets an operator enable or disable Sentry for one environment at
   runtime**, without a deploy, a restart, or an environment-variable change,
   through a tiny mountable web UI (HTTP Basic Auth), rake tasks, and a
   four-method Ruby API, all backed by the same persisted state.

```text
Sentrifig

Environment: production

Sentry Status
┌─────────────────────────────┐
│           ENABLED           │
└─────────────────────────────┘

[ Disable Sentry ]
```

## Contents

1. [Why it exists](#why-it-exists)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Configuration](#configuration)
5. [Sentry defaults](#sentry-defaults)
5. [Database migration](#database-migration)
6. [Mounting the engine](#mounting-the-engine)
7. [Authentication](#authentication)
8. [Enabling and disabling Sentry](#enabling-and-disabling-sentry)
9. [Runtime behaviour: what "disabled" means](#runtime-behaviour-what-disabled-means)
10. [Default behaviour](#default-behaviour)
11. [Multi-process behaviour and caching](#multi-process-behaviour-and-caching)
12. [Failure behaviour](#failure-behaviour)
13. [Security](#security)
14. [Rake tasks](#rake-tasks)
15. [Logging and audit](#logging-and-audit)
16. [Testing](#testing)
17. [Production deployment](#production-deployment)
18. [Troubleshooting](#troubleshooting)
19. [Architecture overview](#architecture-overview)
20. [Known limitations](#known-limitations)

## Why it exists

Sometimes you need Sentry off *right now* for one environment: a noisy incident
is burning through quota, a third-party outage is producing thousands of
identical errors, or a load test is about to run against staging. Normally that
means editing `config.enabled` or an environment variable and redeploying,
because `Sentry.init` runs once at boot.

`sentrifig` puts a runtime gate in front of Sentry's event pipeline and
gives you a button and a rake task to flip it. The gate is consulted for every
event, costs a few hundred nanoseconds, and never queries the database on the
event path more than once per few seconds per process.

## Requirements

- Ruby >= 3.1
- Rails >= 7.1 (railties, activerecord, actionpack)
- `sentry-ruby` and `sentry-rails` >= 5.12 and < 8. Developed and tested
  against 7.0.0 on Rails 8.1.
- An ActiveRecord database. State is stored in one small table in the
  application's own database. No Redis, no extra service.

## Installation

Add the gem after `rails` (and after `sentry-rails` if you list it) in your
`Gemfile`:

```ruby
gem "sentry-ruby"
gem "sentry-rails"
gem "sentrifig"
```

Then:

```bash
bundle install
bin/rails sentrifig:install   # copies the migration and prints next steps
bin/rails db:migrate
```

The installer only copies one migration into `db/migrate`. It does not touch
routes, initializers, or any other application file; it prints what to add.

Then **delete the application's `config/initializers/sentry.rb`**: the gem
calls `Sentry.init` itself with the [Sentry defaults](#sentry-defaults) below.
If you would rather keep your own `Sentry.init`, set
`config.initialize_sentry = false` (the runtime switch works either way). An
application that leaves both in place gets a warning and the gem skips its
init.

## Configuration

No initializer is required. Set `SENTRIFIG_USERNAME` and
`SENTRIFIG_PASSWORD` in the environment and everything else has a default.
Create `config/initializers/sentrifig.rb` only to change something:

```ruby
# config/initializers/sentrifig.rb  (optional)
Sentrifig.configure do |config|
  # config.username = ENV.fetch("SENTRIFIG_USERNAME")   # default
  # config.password = ENV.fetch("SENTRIFIG_PASSWORD")   # default
  # config.enabled_by_default = true     # state when no row exists yet
  # config.cache_ttl = 5                 # seconds a process trusts its cached state
  # config.environment = <Sentry's env>  # key under which the state is stored
  # config.logger = Rails.logger
  # config.initialize_sentry = true      # false keeps your own Sentry.init

  # Application-specific Sentry settings, applied on top of the defaults:
  config.sentry do |sentry|
    sentry.excluded_exceptions += ["MyApp::ExpectedError"]
  end
end
```

| Option | Default | Purpose |
| --- | --- | --- |
| `username`, `password` | `ENV["SENTRIFIG_USERNAME"]`, `ENV["SENTRIFIG_PASSWORD"]` | HTTP Basic Auth credentials for the UI. If either is blank, **every** engine request is refused with 401 and an error is logged. The application itself keeps working. |
| `enabled_by_default` | `true` | Value of `Sentrifig.enabled?` when the database holds no row for the environment. See [Default behaviour](#default-behaviour). |
| `cache_ttl` | `5` | Seconds each process trusts its in-memory copy of the state before re-reading the database. Bounds cross-process propagation delay. `0` re-reads on every event (fine for tests, not for production). |
| `environment` | the environment Sentry reports (`Sentry.configuration.environment`, so `RUNTIME_ENVIRONMENT` with the defaults), `Rails.env` before Sentry is initialised | Row key and the name shown in the UI. Staging and production are told apart even when both run with `Rails.env == "production"`. |
| `logger` | `Rails.logger` | Where `[sentrifig]` lines go. |
| `initialize_sentry` | `true` | Whether the gem calls `Sentry.init` with the [Sentry defaults](#sentry-defaults). |
| `sentry { \|sentry\| ... }` | none | Registers a block run against the `Sentry::Configuration` after the defaults. May be called several times; blocks run in order. |

`configure` validates types (`cache_ttl` must be a non-negative number,
`enabled_by_default` a boolean, `environment` non-blank) and raises
`Sentrifig::ConfigurationError` otherwise. Missing credentials are
deliberately *not* a boot error.

## Sentry defaults

The engine runs `Sentry.init` in an initializer ordered after every
`config/initializers` file (`after: :load_config_initializers`), so blocks
registered with `config.sentry` are known by then, and before
`after_initialize`, where sentry-rails wires its Rails integrations. The
defaults it applies:

| Setting | Value |
| --- | --- |
| `dsn` | `SENTRY_DSN`, but only when `SENTRY_ENABLED` is true; otherwise `nil` (SDK never sends) |
| `environment` | `RUNTIME_ENVIRONMENT`, else Sentry's own detection (`RAILS_ENV`) |
| `enabled_environments` | `production`, `staging` |
| `release` | `APP_RELEASE_TAG`, else Sentry's own detection |
| `debug` | `SENTRY_DEBUG_ENABLE` (default false) |
| `send_default_pii` | `SENTRY_PII_ENABLE` (default false) |
| `sample_rate` | `SENTRY_SAMPLE_RATE` (default 1.0) |
| `traces_sample_rate`, `traces_sampler` | only when `SENTRY_TRACING_ENABLE` is true: `SENTRY_TRACING_SAMPLE_RATE` (default 1.0) and the default sampler below |
| `before_send` | `Sentrifig::SentrySetup::STRIP_AUTHORIZATION`: removes the `Authorization` header (any casing) from the request and from HTTP breadcrumb data |
| `rails.structured_logging.enabled` | `false` (Sentry Logs off; sentry-rails 7 turns it on by default) |
| `excluded_exceptions` | `+ ActionController::RoutingError, ActiveRecord::RecordNotFound` |
| `inspect_exception_causes_for_exclusion` | `false` |
| `include_local_variables` | `true` |
| `max_breadcrumbs`, `context_lines` | `50`, `5` |
| `breadcrumbs_logger` | `active_support_logger`, `sentry_logger`, `http_logger` |
| `enabled_patches` | `+ http, puma`, plus `graphql` / `faraday` when those libraries are loaded |
| `enable_backpressure_handling` | `true` |
| `propagate_traces`, `trace_propagation_targets`, `trace_ignore_status_codes` | `false`, `[]`, `[]` |

Boolean variables accept `true`, `1`, `yes`, `on` (case-insensitive); anything
else, including the string `"false"`, is false. This matters: a hand-written
`config.send_default_pii = ENV.fetch("SENTRY_PII_ENABLE", false)` treats
`"false"` as truthy and silently sends PII.

The default traces sampler continues a caller's sampling decision, samples
inbound `http.server` transactions at `SENTRY_TRACING_SAMPLE_RATE` weighted by
path family (`/healthier` 0.2, `/oauth` and `/api` 0.3, `/graphql` 0.4, other
0.5), samples the paths listed in `SENTRY_HEALTH_CHECK_ENDPOINTS`
(comma-separated prefixes) at 10%, and drops non-HTTP transactions.

Anything can be overridden per application:

```ruby
Sentrifig.configure do |config|
  config.sentry do |sentry|
    sentry.traces_sampler = nil
    sentry.traces_sample_rate = 0.05
    sentry.enabled_environments += ["uat"]
  end
end
```

## Database migration

`bin/rails sentrifig:install` copies this migration into your app:

```ruby
create_table :sentrifig_settings do |t|
  t.string  :environment, null: false
  t.boolean :enabled,     null: false, default: true
  t.string  :changed_by
  t.timestamps
end
add_index :sentrifig_settings, :environment, unique: true
```

One row per environment, enforced by the unique index. The migration is
additive only (no destructive operations) and uses the Rails 7.1 migration API
so it runs unchanged on any supported Rails version. The equivalent Rails
built-in, `bin/rails sentrifig:install:migrations`, also works.

Why one table keyed by environment rather than a table per environment or an
external store: every Rails environment already has its own database, so in
practice each database holds one row. The `environment` column exists so a
shared database (a developer's laptop running both `development` and `test`
against one server, or a shared staging cluster) still keeps the states apart,
and so the row is self-describing when you look at it. It is the simplest
schema that is correct in every layout.

## Mounting the engine

```ruby
# config/routes.rb
Rails.application.routes.draw do
  mount Sentrifig::Engine => "/sentrifig"
end
```

Visit `https://your-app.example.com/sentrifig`, authenticate, and you will
see the dashboard. Any mount path works.

The engine is namespace-isolated: its controllers inherit from
`ActionController::Base` directly, so your application's `before_action`s,
Devise filters, or layouts do not apply to it. It renders plain HTML and CSS;
there is no JavaScript.

## Authentication

Every engine route (dashboard, enable, disable) runs one `before_action` that
demands HTTP Basic Auth and compares both the username and the password with
`ActiveSupport::SecurityUtils.secure_compare` over SHA-256 digests of both sides
(constant time, independent of credential length, both comparisons always
evaluated). Failures return `401` with a `WWW-Authenticate` header and
no page content.

Supply credentials from the environment or from Rails credentials:

```ruby
Sentrifig.configure do |config|
  config.username = Rails.application.credentials.dig(:sentrifig, :username)
  config.password = Rails.application.credentials.dig(:sentrifig, :password)
end
```

Guidelines:

- Serve the UI over HTTPS only. Basic Auth sends credentials with every request.
- Use a long, random password (32+ characters). It is compared, never stored.
- Rotate by changing the environment variable and restarting; the password is
  never written to the database or to logs.
- If you already have a reverse proxy or VPN in front of admin tooling, you can
  add IP allow-listing there as a second layer. Basic Auth remains mandatory.

## Enabling and disabling Sentry

Three interfaces, one source of truth. All of them write the same row and
update the in-process cache immediately.

**Web UI**: click *Disable Sentry* / *Enable Sentry*. Both are `POST` forms
with a CSRF token. The operator's Basic Auth username is recorded as
`changed_by`.

**Rake tasks**:

```bash
$ bin/rails sentrifig:status
Environment: production
Sentry: ENABLED
Note: no stored setting yet, showing default

$ bin/rails sentrifig:disable
Environment: production
Sentry: DISABLED

$ bin/rails sentrifig:enable
Environment: production
Sentry: ENABLED
```

**Ruby API**:

```ruby
Sentrifig.enabled?              # => true    (hot path, in-memory)
Sentrifig.disable!(by: "alice") # persists, applies now, logs, returns false
Sentrifig.enable!(by: "alice")  # => true
Sentrifig.status                # => Status(enabled:, environment:, source:, changed_by:, changed_at:, cache_ttl:)
Sentrifig.status.label          # => "ENABLED" / "DISABLED"
Sentrifig.current_environment   # => "production"
Sentrifig.refresh!              # re-read the database now instead of waiting for cache_ttl
```

`enable!`/`disable!` raise `Sentrifig::PersistenceError` (with `#cause`) if
the row cannot be written; the previous state stays in effect.

## Runtime behaviour: what "disabled" means

`sentrifig` registers **one global event processor** with sentry-ruby
(`Sentry.add_global_event_processor`). Global processors run inside
`Sentry::Scope#apply_to_event` for every event the SDK is about to send, before
the application's own `before_send` callbacks. When Sentry is disabled the
processor returns `nil`, which makes the SDK discard the event and count it as
a lost event with reason `event_processor`.

While **disabled**, the following are discarded before `before_send` and before
the transport, so nothing leaves the process:

- Error and message events: `Sentry.capture_exception`, `Sentry.capture_message`,
  `Sentry.capture_event`
- Exceptions captured by sentry-rails: unhandled controller exceptions
  (`Sentry::Rails::CaptureExceptions`), `Rails.error.report` via the error
  subscriber, ActiveJob failures, ActionCable errors, runner errors
- Transactions and their spans (performance monitoring)
- Cron check-ins

While disabled, the following **keep working** unchanged:

- Breadcrumbs, tags, user, extras, contexts, and scopes are still recorded in
  memory. The first event after re-enabling carries them, so you lose no
  context.
- Tracing instrumentation still runs (transactions are created and sampled,
  spans are timed); only the resulting event is dropped. Re-enabling is
  therefore instantaneous with no warm-up.
- Your `before_send`, `before_send_transaction`, and `before_breadcrumb`
  callbacks are untouched. They simply are not reached for dropped events.
- `Sentry.capture_exception` still marks the exception as captured, exactly as
  it does when your own `before_send` returns `nil`.

Not gated (see [Known limitations](#known-limitations)): Sentry Logs and
Metrics, and release-health sessions.

Because the hook lives on `Sentry::Scope` rather than on a configuration
object, it is independent of when `Sentry.init` runs, survives re-initialisation,
and never modifies your Sentry configuration.

## Default behaviour

**Installing the gem never turns Sentry off.**

```text
Sentry configured, gem installed, no row in sentrifig_settings
    -> Sentrifig.enabled? == true (enabled_by_default)
    -> Sentry behaves exactly as before
```

No row is written until someone clicks a button, runs a task, or calls the API.
The dashboard shows "No setting stored yet. Showing the default." in that state.
Set `config.enabled_by_default = false` only if you consciously want new
environments to start silent.

## Multi-process behaviour and caching

A real deployment is several Puma workers, Sidekiq processes, and containers.
The design separates a **control plane** (UI, rake tasks, database) from a
**data plane** (the gate on the Sentry event path):

```text
Control plane                          Data plane (every process)

 UI / rake / API                        Sentry.capture_exception
       │                                          │
       ▼                                          ▼
 sentrifig_settings  ◀── re-read ──  in-memory snapshot  ── enabled? ──▶ Sentry
   (one row / env)          ≤ 1 per          (Runtime)                        pipeline
                            cache_ttl
                            per process
```

Each process holds one immutable snapshot `{enabled, source, changed_by,
changed_at}` and a monotonic "next refresh" timestamp. `Sentrifig.enabled?`
reads the snapshot and compares the clock; that is the whole hot path. When
the snapshot is older than `cache_ttl`, the *first* caller to notice performs a
single-row database read and installs a new snapshot; any concurrent callers
keep using the previous snapshot instead of waiting on a lock (`Mutex#try_lock`).

**Consistency model**

> A change takes effect immediately in the process that made it and in every
> other process within `cache_ttl` seconds (default 5), counted from that
> process's next Sentry event.

Concretely, for a change made at time T with the default TTL:

- The process that handled the click or task drops/sends events correctly from
  T onward.
- Every other process re-reads the row the first time it processes an event
  after its own snapshot expires, which is at most T + 5 s. A process that
  never processes an event never reads the database.
- The database is the only shared component. No Redis, no `Rails.cache`, no
  pub/sub, no polling thread.

Why not `Rails.cache`? In development and test it is per-process or a null
store, and in production it is often per-process too (memory store), so it
does not solve propagation by itself, and where it *is* shared (Solid Cache,
Redis, Memcached) it adds a second network dependency for a value the database
already provides in one indexed read every few seconds. A TTL-refreshed
in-memory snapshot gives bounded propagation with the fewest moving parts.
Stronger consistency (pub/sub invalidation) would require a message bus, which
this gem deliberately does not mandate.

**Tuning**: lower `cache_ttl` for faster propagation at the cost of one
database read per process per `cache_ttl` while events flow. 5 seconds is a
sensible production default; 1 second is fine for small fleets. Do not use `0`
in production.

## Failure behaviour

The control plane may fail; the application must not. Every database error is
caught inside the runtime.

| Situation | Data plane (`enabled?`) | Control plane | Logged |
| --- | --- | --- | --- |
| No row for the environment | `enabled_by_default` (true) | UI shows "no setting stored yet" | nothing |
| Migration not run (`Could not find table`) | last known state, else default (enabled) | UI renders; enable/disable show an alert and change nothing; rake tasks fail with `PersistenceError` | one warning, then silence until recovery |
| Database unreachable | last known state, else default; retried after `cache_ttl` | same as above | one warning per outage, one info line on recovery |
| Database slow | one thread pays the read at most once per `cache_ttl`; everyone else uses the cached value | UI/rake block on the query as usual | nothing |
| Concurrent writers | last write wins on one row; racing inserts are retried against the unique index | | |
| Sentry not initialised / DSN missing | gate is registered but never consulted; Sentry's own checks run first | UI still works | nothing |
| Gate raises unexpectedly | event is passed through (fail open) | | once |

Fail-open is intentional: a broken switch should never lose error reports.
The dashboard reports a degraded read ("The database is currently unreachable.
Showing the last known state.") without exposing the error text.

## Security

The UI can silence an application's error monitoring, so it is treated as an
operational admin tool.

- **Authentication**: HTTP Basic Auth on every route, constant-time comparison
  of SHA-256 digests (no length leak), no access at all when credentials are
  unconfigured.
- **State changes are `POST` only**. `GET /sentrifig/disable` is not a route
  (404). `PATCH`/`PUT`/`DELETE` are not routes either.
- **CSRF**: `protect_from_forgery with: :exception`. Forms carry the Rails
  authenticity token; a `POST` without it is rejected with 422 and changes
  nothing. This uses the host application's session middleware (cookie store by
  default).
- **No secrets in the UI**: the page shows the environment, the state, who
  changed it and when. It never shows the DSN, credentials, environment
  variables, or Sentry configuration. Error messages from the database are
  logged, not rendered.
- **`Cache-Control: no-store`** on every engine response; `noindex, nofollow`.
- **Passwords are never stored**. Only the Basic Auth *username* of the operator
  is written to `changed_by` for audit purposes.
- **Audit trail**: each change is logged (see below) and the row records
  `changed_by` and `updated_at`.
- **Isolation**: engine controllers inherit from `ActionController::Base`, so a
  misconfigured application-level filter cannot accidentally open the UI.

Serve the UI over TLS. Consider putting it behind the same network controls as
your other admin endpoints.

## Rake tasks

| Task | Effect |
| --- | --- |
| `bin/rails sentrifig:install` | Copy the migration into `db/migrate` (idempotent) and print next steps. |
| `bin/rails sentrifig:status` | Print environment, state, and who changed it. Reads the database. |
| `bin/rails sentrifig:enable` | Turn Sentry on for `Rails.env`; records `changed_by = "rake"`. |
| `bin/rails sentrifig:disable` | Turn Sentry off for `Rails.env`; records `changed_by = "rake"`. |
| `bin/rails sentrifig:test_event` | Capture a test message and report what happened: accepted by the SDK (exit 0), dropped by the switch (exit 2), or the SDK itself cannot send from this process, with the reason (exit 1). |

`status` also prints whether the SDK is able to send at all (`SDK: ready to
send` or `SDK: not sending (DSN not set or not valid)`), and the dashboard shows
the same. The switch and the SDK's own gating are independent: with
`SENTRY_ENABLED=false` nothing is sent whatever the switch says.

To verify a deployment end to end, toggle it in the UI and run the task in a
pod of that environment:

```bash
bin/rails sentrifig:test_event   # ENABLED  -> "Event <id> accepted ...", visible in Sentry
bin/rails sentrifig:disable
bin/rails sentrifig:test_event   # DISABLED -> "Event dropped by sentrifig", exit 2
```

The tasks call the same `Sentrifig.enable!`/`disable!`/`status` used by the
UI. Run them with the target `RAILS_ENV` and database configuration, for
example inside a production console container.

## Logging and audit

Only transitions are logged, never the hot path:

```text
[sentrifig] Sentry disabled environment=production by=alice
[sentrifig] Sentry enabled environment=production by=rake
[sentrifig] Sentry enabled (picked up from database) environment=production by=rake
[sentrifig] could not read state (ActiveRecord::ConnectionNotEstablished: ...); keeping Sentry enabled for environment=production, retrying in 5s
[sentrifig] database reachable again; Sentry enabled environment=production
[sentrifig] could not persist Sentry disabled for environment=production: ...
[sentrifig] refusing request to /sentrifig: username/password are not configured (see Sentrifig.configure)
```

The first two lines come from the process that made the change; the third
appears in every other process when it notices. Outages are logged once per
outage, not once per retry.

## Testing

Run the gem's own suite (99 tests: configuration, Sentry defaults, persistence,
runtime cache, concurrency, Sentry integration, Rails exception capture,
authentication, CSRF, routing, rake tasks, test helper, boot wiring):

```bash
bundle install
bundle exec rake test
```

The suite boots the Rails app in `test/dummy` against SQLite and uses Sentry's
own `Sentry::DummyTransport`, so nothing is sent anywhere.

### In your application's tests

Use `Sentrifig::TestHelper`. It wraps Sentry's own `Sentry::TestHelper`
(dummy DSN, `Sentry::DummyTransport`, nothing leaves the process) and adds two
things the switch needs: the in-process cache is reset around each test, and
the gate is re-installed after setup, because `teardown_sentry_test` clears
**all** global event processors and would otherwise remove the switch for
every later test.

RSpec:

```ruby
# spec/support/sentrifig.rb (or rails_helper.rb)
require "sentrifig/rspec"

# spec/requests/sentry_switch_spec.rb
RSpec.describe "Sentry switch", :sentrifig do
  it "drops events while disabled" do
    Sentrifig.disable!
    Sentry.capture_exception(StandardError.new("hidden"))
    expect(sentry_error_events).to be_empty
  end

  it "admits the dashboard with credentials" do
    with_sentrifig_credentials("ops", "pw") do
      get "/sentrifig", headers: sentrifig_basic_auth("ops", "pw")
    end
    expect(response).to have_http_status(:ok)
  end
end
```

Minitest:

```ruby
class SentrySwitchTest < ActiveSupport::TestCase
  include Sentrifig::TestHelper
  setup    { setup_sentrifig_test }
  teardown { teardown_sentrifig_test }
end
```

Helpers: `sentry_events` and `last_sentry_event` (from Sentry),
`sentry_error_events` (errors and messages only, no transactions),
`with_sentrifig_credentials(user, pass) { }`,
`sentrifig_basic_auth(user, pass)`.

### Try it locally with the demo application

`test/dummy` is a minimal Rails app that mounts the engine and exposes a few
demo routes. It records Sentry events in-process (DummyTransport) unless you
set `SENTRY_DSN`.

```bash
cd test/dummy
bin/rails sentrifig:install && bin/rails db:migrate
SENTRIFIG_USERNAME=ops SENTRIFIG_PASSWORD=pw bundle exec puma -p 3000 config.ru
```

Then, in another terminal:

```bash
curl -s localhost:3000/capture                 # => captured event <id>
open http://localhost:3000/sentrifig       # log in as ops / pw, click "Disable Sentry"
curl -s localhost:3000/capture                 # => dropped by sentrifig
bin/rails sentrifig:status                 # second process sees DISABLED
bin/rails sentrifig:enable                 # flip it back from the CLI
sleep 5; curl -s localhost:3000/capture        # server picked it up: captured event <id>
grep sentrifig log/development.log
```

No restart, no redeploy, no environment change.

## Production deployment

1. Ship the migration with a normal deploy and run `db:migrate`. It is additive
   and safe to run while old code is still serving traffic (old code does not
   know the table exists).
2. Set `SENTRIFIG_USERNAME` and `SENTRIFIG_PASSWORD` (or the
   credentials keys you chose) in every environment where the UI is mounted.
3. Mount the engine and confirm `/sentrifig` returns 401 without
   credentials and the dashboard with them.
4. Leave `cache_ttl` at 5 unless you have a reason to change it.
5. Rolling deploys are safe: new processes read the current row at their first
   event; processes without a row default to enabled.
6. If you run Sidekiq or other non-web processes, nothing extra is needed. They
   share the database and pick up changes within `cache_ttl` as well.

## Troubleshooting

**Every request to `/sentrifig` returns 401, even with the right password.**
Credentials are not configured (both `username` and `password` must be
non-blank strings). Look for
`[sentrifig] refusing request ... username/password are not configured` in
the log.

**The dashboard says "The database is currently unreachable".**
The row could not be read. Most often the migration has not been run
(`Could not find table 'sentrifig_settings'` in the log). Run
`bin/rails sentrifig:install && bin/rails db:migrate`. Sentry keeps its
last known (or default, enabled) state meanwhile.

**I disabled Sentry but another process still sent an event.**
Expected for up to `cache_ttl` seconds after the change. Check timestamps; if
it persists, confirm the processes share the same database and `Rails.env`.

**`POST /sentrifig/disable` returns 422.**
CSRF token missing or stale. Use the button on the dashboard (or send the
`authenticity_token` from the page with the session cookie). This also happens
in API-only applications (`config.api_only = true`) that have no cookie/session
middleware; add `ActionDispatch::Cookies` and `ActionDispatch::Session::CookieStore`
for the engine to work there.

**I use multiple databases.**
`Sentrifig::Setting` inherits from `ActiveRecord::Base` and therefore uses
the primary (writing) connection. Install the migration in the primary database.

**Sentry structured logs / metrics still arrive while disabled.**
See [Known limitations](#known-limitations).

**The dashboard says the SDK is "Not sending from this deployment".**
Sentry's own gating, independent of the switch: `SENTRY_ENABLED` is not
`true`, `SENTRY_DSN` is missing, or `RUNTIME_ENVIRONMENT` is not one of the
enabled environments (`production`, `staging` by default). Fix the deployment
variables; the switch cannot override them.

**"Sentry was already initialised by the application; skipping the default Sentry.init".**
The app still has its own `Sentry.init`. Delete it to get the defaults, or set
`config.initialize_sentry = false` to keep it and silence the warning.

**My tests lost the switch after the first example.**
Use `Sentrifig::TestHelper` / `require "sentrifig/rspec"` instead of
`Sentry::TestHelper` directly; see [Testing](#testing).

## Architecture overview

Full design notes, alternatives considered, and measurements are in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). In short:

```text
lib/sentrifig.rb            public API (enabled?, enable!, disable!, status, ...)
lib/sentrifig/configuration.rb   options + validation
lib/sentrifig/runtime.rb    in-memory snapshot, TTL refresh, degradation, logging
lib/sentrifig/store.rb      ActiveRecord persistence (single-row upsert, retry on race)
lib/sentrifig/gate.rb       the Sentry global event processor
lib/sentrifig/sentry_setup.rb    Selise's default Sentry.init (env-driven) + before_send + sampler
lib/sentrifig/test_helper.rb     test support (Minitest/RSpec); lib/sentrifig/rspec.rb wires RSpec
lib/sentrifig/engine.rb     Rails engine, installs the gate after boot
lib/tasks/sentrifig.rake    install / status / enable / disable
app/                            controllers, model, views of the mounted UI
db/migrate/                     the single migration
```

- **Sentry setup**: `Sentrifig::SentrySetup` applies the env-driven
  defaults inside `Sentry.init`, then the application's `config.sentry` blocks.
- **Interception**: one `Sentry.add_global_event_processor` block returning
  `nil` when disabled. No monkey-patching, no change to `Sentry.configuration`.
- **State**: one row per environment in the app's database; no row = enabled.
- **Cache**: per-process immutable snapshot refreshed at most once per
  `cache_ttl` by a single non-blocking reader. Measured hot path: about 400 ns
  per `enabled?` call, about 500 ns per gate invocation, zero allocations on the
  cached path.
- **Propagation**: immediate locally, within `cache_ttl` elsewhere.
- **Failure**: fail open to the last known or default state, log once, retry
  after `cache_ttl`.

## Known limitations

- **Sentry Logs and Metrics are not gated.** These opt-in features
  (`config.enable_logs`, `Sentry.logger`, `Sentry.metrics`) use separate
  telemetry buffers that do not run event processors, and their
  `before_send_log`/`before_send_metric` hooks are captured when the client is
  built, so they cannot be intercepted after `Sentry.init`. If you use them and
  want the switch to cover them, gate them yourself at init time:

  ```ruby
  Sentry.init do |config|
    config.before_send_log    = ->(log)    { Sentrifig.enabled? ? log : nil }
    config.before_send_metric = ->(metric) { Sentrifig.enabled? ? metric : nil }
  end
  ```

- **Release-health sessions** (`auto_session_tracking`) are aggregated and
  flushed by a separate flusher and are not affected by the switch.
- **Instrumentation cost is unchanged while disabled.** Sentry still builds
  events, breadcrumbs, and spans; only sending is suppressed. This is what
  makes re-enabling instantaneous, but it means "disabled" is not "uninstalled".
- **Propagation is eventually consistent** (bounded by `cache_ttl`), not
  instantaneous across processes.
- **The switch is per environment, not per process or per host.** All processes
  of one environment share one state.
- **`Sentry.init` timing.** With `initialize_sentry` (the default) Sentry is
  initialised after the application's `config/initializers` rather than inside
  them. Code in an initializer that calls `Sentry.*` at load time will find the
  SDK not yet initialised; move it into `config.sentry { }` or
  `config.after_initialize`.
- Verified against sentry-ruby/sentry-rails 7.0.0 on Rails 8.1 and Ruby 4.0. The
  hook used exists since sentry-ruby 5.x, but other versions were not exercised
  by the test suite.

## License

MIT. See `LICENSE.txt`.
