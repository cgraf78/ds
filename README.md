# ds — Dev Session Launcher

![CI](https://github.com/cgraf78/ds/actions/workflows/ci.yml/badge.svg)
![Release](https://img.shields.io/github/v/release/cgraf78/ds)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Bash](https://img.shields.io/badge/bash-4%2B-blue)

`ds` creates tmux dev sessions locally or on remote hosts. Profiles, connection methods, and share backends are all pluggable.

## Install

```bash
curl -sL https://raw.githubusercontent.com/cgraf78/ds/main/install.sh | bash
```

Or from source:

```bash
git clone https://github.com/cgraf78/ds.git
cd ds && bash install.sh
```

## Usage

```bash
ds                              # default session "ds" (plain tmux)
ds dev                          # session "dev" with dev profile
ds dev-work                     # session "dev-work" with dev profile
ds chat                         # session "chat" with chat profile

ds dev @myhost                  # dev session on remote host
ds @myhost                      # default session on remote host

ds -l                           # list active ds sessions
ds -l @myhost                   # list sessions on remote host

ds -k dev                       # kill session "dev"
ds -k                           # kill current session (inside tmux)
ds --killall                    # kill all ds sessions

ds --share                      # share current session via upterm
ds --share dev                  # share session "dev"
ds --unshare                    # stop sharing
ds --share-via upterm           # create/attach and share in one step

ds init bash                    # print shell integration snippet
```

## Session Naming

Sessions are named after their profile, with an optional dash-separated instance tag:

| Command | Session | Profile |
|---------|---------|---------|
| `ds` | `ds` | ds (default) |
| `ds ds` | `ds` | ds (default) |
| `ds dev` | `dev` | dev |
| `ds dev-work` | `dev-work` | dev |
| `ds chat` | `chat` | chat |

The profile is resolved from the session name: split on the first `-`, and if the left side matches a known profile, that profile is used. Profile names must not contain dashes.

## Profiles

Profiles define the tmux window/pane layout. Bundled profiles live in `lib/plugins/`. User profiles go in `~/.config/ds/profile-<name>.sh` (user config takes priority).

Each profile defines a `_profile_<name>()` function:

```bash
# ~/.config/ds/profile-myprofile.sh
_profile_myprofile() {
    local session="$1"
    # set up tmux windows/panes here
}
```

### Bundled profiles

**dev** — chatbot pane (top) + bash (bottom) + separate bash window.

| Variable | Default | Description |
|---|---|---|
| `DS_DEV_CHATBOT` | *(empty)* | Command for the top pane (e.g., `claude`) |
| `DS_DEV_DIR` | `~` | Working directory for all panes |

**chat** — single window running a chatbot.

| Variable | Default | Description |
|---|---|---|
| `DS_CHAT_CHATBOT` | *(empty)* | Command for the window |
| `DS_CHAT_DIR` | `~` | Working directory |

## Host Resolution

All `~/.config/ds/connect*.conf` files are read (additive). Format: two columns — hostname (glob patterns supported) and connect method. First match wins.

```text
# ~/.config/ds/connect.conf
myserver      autossh
dev*          ssh
localbox      -
```

See `examples/connect.conf` for a template.

## Connect Methods

`ssh` is built-in. Other methods are plugins in `~/.config/ds/connect-<method>.sh` (or bundled in `lib/plugins/`), defining `_connect_<method>()`.

| Method | Description |
|---|---|
| `-` | Local-only, no remote connections |
| `ssh` | Standard SSH (built-in) |
| `autossh` | Auto-reconnecting SSH |
| `et` | Eternal Terminal (persistent connection) |

## Sharing

Share backends live in `lib/plugins/share-<backend>.sh` or `~/.config/ds/share-<backend>.sh`. Config goes in `~/.config/ds/share-<backend>.conf`.

Only one session can be shared at a time. `ds -l` marks shared sessions with `[shared]`.

### Upterm backend

Config file: `~/.config/ds/share-upterm.conf` (env vars `DS_UPTERM_*` override):

| Config key | Env var | Description |
|---|---|---|
| `server` | `DS_UPTERM_HOST` | Server `host:port` (default: `uptermd.upterm.dev:22`) |
| `known-hosts` | `DS_UPTERM_KNOWN_HOSTS` | Known hosts file for verification |
| `private-key` | `DS_UPTERM_PRIVATE_KEY` | SSH private key (auto-detected if unset) |
| `github-user` | `DS_UPTERM_GITHUB_USER` | Restrict access to a GitHub user |
| `authorized-keys` | `DS_UPTERM_AUTHORIZED_KEYS` | Restrict access via authorized_keys |
| `push` | `DS_UPTERM_PUSH` | `user@host` — push share info via SCP |

See `examples/share-upterm.conf` for a template.

## Shell Integration

Add to `~/.bashrc`:

```bash
eval "$(ds init bash)"
```

This provides tab completion and ET connect support.

### Auto-attach on SSH login

Set `DS_SSH_AUTO_ATTACH` **before** the `eval` line to auto-create/attach a tmux session on SSH login:

```bash
DS_SSH_AUTO_ATTACH=ds         # attach to default "ds" session
# DS_SSH_AUTO_ATTACH=dev      # attach to "dev" session instead
eval "$(ds init bash)"
```

Skip auto-attach for a single login with `NO_TMUX=1`.

## State

Runtime state lives under `~/.local/state/ds/` (mode `0700`).

## License

MIT — see [LICENSE](LICENSE).
