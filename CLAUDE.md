# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`ds` is a bash CLI tool that creates and manages tmux dev sessions locally or on remote hosts. Profiles, connection methods, and share backends are all pluggable.

## Commands

```bash
# Run tests
bash tests/ds-test

# Lint
shellcheck -x bin/ds
shellcheck -x lib/plugins/*.sh
shellcheck -x -P SCRIPTDIR tests/ds-test tests/test-helpers.sh

# Install locally
bash install.sh    # installs to ~/.local/bin/ds + ~/.local/lib/ds/plugins/
```

## Architecture

Single-file CLI (`bin/ds`) with a plugin system. Everything is pure bash (4+).

**Plugin discovery** (`_find_plugin`, `_glob_plugins`): searches `~/.config/ds/` first (user override), then `lib/plugins/` (bundled). Three plugin types:

- **Profiles** (`profile-<name>.sh`): define `_profile_<name>()` to set up tmux window/pane layouts. Bundled: `dev`, `chat`. Built-in: `ds` (plain tmux, used as default).
- **Connect methods** (`connect-<method>.sh`): define `_connect_<method>()` for remote transport. `ssh` is built-in. Bundled: `autossh`.
- **Share backends** (`share-<backend>.sh`): define `_share_start`, `_share_stop`, `_share_info`, `_share_running`, `_share_current_session`, `_share_load_config`. Bundled: `upterm`.

**Session naming**: session name = profile name or `profile-instance` (split on first `-`). Default session is `ds` with `ds` profile.

**Host resolution**: `~/.config/ds/connect*.conf` files map hostname globs to connect methods. First match wins.

**State**: runtime files (PID, share info, admin socket) live under `~/.local/state/ds/` with mode 0700.

**Testing**: `tests/ds-test` sources `bin/ds` with `DS_SOURCED=1` to test internal functions in isolation, using mock `tmux`/`upterm` binaries. Test framework lives in `tests/test-helpers.sh` (assertions: `_assert_eq`, `_assert_contains`, `_assert_not_contains`, etc.).

## Key Patterns

- `DS_SOURCED=1` makes `bin/ds` export functions without executing arg parsing — used by tests.
- Tmux session names use `=` prefix for exact matching (`tmux has-session -t "=$session"`).
- `DS_MANAGED` env var is set on tmux sessions created by ds, distinguishing them from user-created sessions.
- Config files use `key=value` format (share backends) or two-column whitespace-separated format (connect configs).
- `DS_SSH_AUTO_ATTACH` env var opts into auto-create/attach on SSH login. Value is passed directly as the session arg to `ds` (e.g., `DS_SSH_AUTO_ATTACH=ds` runs `ds ds`). `NO_TMUX=1` skips it for one login.

## Releasing

1. Bump `VERSION` file, commit, push to main.
2. Tag and push: `git tag v<version> && git push origin v<version>`
3. The release workflow (`.github/workflows/release.yml`) runs tests, creates a tarball, and publishes the GitHub release automatically.
4. Optionally edit the release notes via `gh release edit v<version> --notes-file <file>`.
