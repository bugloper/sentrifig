# Changelog

## 0.2.0 (unreleased)

### Added

- Frontend scope. State is stored per `(environment, scope)` with scopes `backend` and
  `frontend`, so browser Sentry can be switched independently of this application's Ruby SDK.
- `GET <mount>/state` — JSON state for browser clients (`enabled`, `scope`, `environment`,
  `source`, `poll_interval`), authenticated by the host application and never by the operator
  Basic credentials. It deliberately never exposes `changed_by`: that is the operator's Basic
  auth username, and this endpoint is readable by every logged-in application user.
- `config.client_authenticator = ->(request) { ... }` — the host's check for browser requests to
  that endpoint. Unset means every such request is refused with 401 and an error is logged; the
  Basic-auth dashboard is unaffected.
- `config.client_poll_interval` (default 60s), published in the state response. Deliberately not
  `cache_ttl`, which is far too aggressive for a browser.
- `Sentrifig.enabled_for?(scope)`, `Sentrifig.statuses`, and `scope:` keywords on `enable!`,
  `disable!`, `status`, `refresh!` and `runtime`.
- The dashboard shows both switches. `sentrifig:enable` / `sentrifig:disable` take an optional
  scope (`sentrifig:enable[frontend]`, or `SCOPE=frontend`); `sentrifig:status` prints both.
- `with_sentrifig_client_authenticator` in the shipped test helper.

### Changed

- `Store#fetch` / `Store#write` take a `scope:` keyword, defaulting to `backend`.
- `Runtime` is instantiated per scope and takes `scope:`. `Runtime::Status` gained a `scope`
  member, and log lines carry `scope=`.
- Dashboard forms post to `<mount>/<scope>/enable|disable`. The unscoped `<mount>/enable` and
  `<mount>/disable` routes still exist and act on the backend switch.
- `Sentrifig.enabled?` is unchanged: still no arguments, still means "backend enabled", still
  what `Gate::PROCESSOR` calls. The backend runtime is held in a dedicated ivar so the scope
  split costs the hot path nothing.

### Upgrading from 0.1.0

The `sentrifig_settings` migration was amended rather than superseded: the gem had not been
released and no deployed database held the table. `scope` is part of the table definition and the
unique index is now on `(environment, scope)`.

`rails sentrifig:install` copies by filename, so it will **not** replace a migration you already
have. In a host that installed 0.1.0:

```
bin/rails db:rollback                                  # or drop sentrifig_settings
rm db/migrate/*_create_sentrifig_settings.sentrifig.rb
# bump the gem to v0.2.0
bin/rails sentrifig:install
bin/rails db:migrate
```

Then set `config.client_authenticator`, or the new `/state` endpoint will refuse every request.

## 0.1.0 (unreleased)

- Initial release: gem-owned Sentry.init with env-driven Selise defaults and per-app overrides,
  runtime Sentry on/off switch, per-environment persisted state,
  in-memory cached gate, mountable Basic-Auth UI, rake tasks (incl. test_event), installer,
  Minitest/RSpec test helper.
