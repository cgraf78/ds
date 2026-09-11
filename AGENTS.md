# AGENTS.md

## About

`ds` is a Bash 4+ CLI that creates and manages tmux dev sessions
locally or on remote hosts. Profiles, connection methods, and share
backends are pluggable. It is distributed from the git checkout (no
versioned release artifacts); the checked-out commit is the installed
identity.

## Architecture

Single-file CLI (`bin/ds`) plus plugins. Plugin discovery
(`_find_plugin`, `_glob_plugins`) searches
`${XDG_CONFIG_HOME:-$HOME/.config}/ds/` first, then `lib/plugins/`.
Absolute `XDG_CONFIG_HOME` values select that root; other values fall
back to `$HOME/.config`.

- **Profiles** (`profile-<name>.sh`): `_profile_<name>()` sets tmux
  layouts. Bundled: `dev`, `chat`. Built-in: `ds` (plain tmux, default).
  Data rows in `profile*.conf` (`<name> <window> <command...>`)
  synthesize wrappers before the `.sh` source loop; a `.sh` of the
  same name wins.
- **Connect methods** (`connect-<method>.sh`): `_connect_<method>()`.
  `ssh` is built-in. Bundled: `autossh`.
- **Share backends** (`share-<backend>.sh`): `_share_start`,
  `_share_stop`, `_share_info`, `_share_running`,
  `_share_current_session`, `_share_load_config`. Bundled: `upterm`.

Session name is the profile, `profile-instance` (split on the first
`-`), or any arbitrary name (uses the `ds` profile). Default session
is `ds` with the `ds` profile. Profile names must not contain dashes.

Host resolution: `connect*.conf` maps hostname globs to connect
methods; first match wins.

State lives under `${XDG_STATE_HOME:-$HOME/.local/state}/ds/` with
mode `0700`. Only absolute XDG roots are used; `DS_STATE_DIR`
overrides the complete directory.

## Invariants

- `DS_SOURCED=1` exports functions from `bin/ds` without arg parsing
  (tests).
- Tmux session names use an `=` prefix for exact matching
  (`tmux has-session -t "=$session"`).
- `@ds_managed` (session option; `DS_MANAGED` env as legacy fallback)
  marks sessions created by ds.
- Keep tests deterministic: temporary homes, explicit config, and mock
  `tmux`/`upterm`. Do not depend on a live tmux or SSH environment.

## Testing

CI (`DS_SKIP_SHELLCHECK=1` because the shared inventory job lints):

```sh
DS_SKIP_SHELLCHECK=1 bash tests/ds-ci
```

Local (includes ShellCheck from `.github/shellcheck-files.txt`):

```sh
bash tests/ds-ci
```

`tests/ds-ci` runs `tests/install-test` and `tests/ds-test`.
