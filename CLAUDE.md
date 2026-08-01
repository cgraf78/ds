# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`ds` is a bash CLI tool that creates and manages tmux dev sessions locally or on remote hosts. Profiles, connection methods, and share backends are all pluggable.

## Commands

```bash
# Run the same tests and typed-inventory lint used by CI
bash tests/ds-ci

# Install locally
bash install.sh    # installs to ~/.local/bin/ds + ~/.local/lib/ds/plugins/
```

## Architecture

Single-file CLI (`bin/ds`) with a plugin system. Everything is pure bash (4+).

**Plugin discovery** (`_find_plugin`, `_glob_plugins`): searches `${XDG_CONFIG_HOME:-$HOME/.config}/ds/` first (user override), then `lib/plugins/` (bundled). Three plugin types:

- **Profiles** (`profile-<name>.sh`): define `_profile_<name>()` to set up tmux window/pane layouts. Bundled: `dev`, `chat`. Built-in: `ds` (plain tmux, used as default). Trivial single-command profiles can instead be declared as data rows (`<name> <window> <command...>`) in `profile*.conf`; `_load_data_profiles` synthesizes `_profile_<name>` wrappers around `_profile_run_command` before the `.sh` source loop, so a `.sh` of the same name overrides a data row.
- **Connect methods** (`connect-<method>.sh`): define `_connect_<method>()` for remote transport. `ssh` is built-in. Bundled: `autossh`.
- **Share backends** (`share-<backend>.sh`): define `_share_start`, `_share_stop`, `_share_info`, `_share_running`, `_share_current_session`, `_share_load_config`. Bundled: `upterm`.

**Session naming**: session name = profile name, `profile-instance` (split on first `-`), or any arbitrary name (uses `ds` profile). Default session is `ds` with `ds` profile.

**Host resolution**: `connect*.conf` files under the resolved config directory
map hostname globs to connect methods. Absolute `XDG_CONFIG_HOME` values select
that root; other values fall back to `$HOME/.config`. First match wins.

**State**: runtime files (PID, share info, admin socket) live under
`${XDG_STATE_HOME:-$HOME/.local/state}/ds/` with mode 0700. Only absolute XDG
roots are used; `DS_STATE_DIR` overrides the complete directory.

**Testing**: `tests/ds-test` sources `bin/ds` with `DS_SOURCED=1` to test internal functions in isolation, using mock `tmux`/`upterm` binaries. Test framework lives in `tests/test-helpers.sh` (assertions: `_assert_eq`, `_assert_contains`, `_assert_not_contains`, etc.).

## Key Patterns

- `DS_SOURCED=1` makes `bin/ds` export functions without executing arg parsing — used by tests.
- Tmux session names use `=` prefix for exact matching (`tmux has-session -t "=$session"`).
- `DS_MANAGED` env var is set on tmux sessions created by ds, distinguishing them from user-created sessions.
- Config files use `key=value` format (share backends) or two-column whitespace-separated format (connect configs).
- `DS_SSH_AUTO_ATTACH` env var opts into auto-create/attach on SSH login. Value is passed directly as the session arg to `ds` (e.g., `DS_SSH_AUTO_ATTACH=ds` runs `ds ds`). `NO_TMUX=1` skips it for one login.

## Versioning

`ds` is distributed from the git repo instead of versioned release artifacts.
Use the checked-out commit as the installed version identity. The preferred
dependency-management path is shdeps' `github:repo` method.
