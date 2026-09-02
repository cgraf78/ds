# ds — Dev Session Launcher

![Tests](https://github.com/cgraf78/ds/actions/workflows/test.yml/badge.svg)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
![Bash](https://img.shields.io/badge/bash-4%2B-blue)

`ds` creates tmux dev sessions locally or on remote hosts. Profiles, connection methods, and share backends are all pluggable.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cgraf78/ds/main/install.sh | bash
```

This keeps a shallow, updateable checkout under
`${XDG_DATA_HOME:-$HOME/.local/share}/cgraf78/checkouts/ds` and publishes links to
its `ds` command and manual page. It does not use a release asset or copy a
second runtime tree. Git and Bash 4+ (available as `bash` on `PATH`) are
required.

To choose and manage the checkout yourself instead:

```bash
git clone https://github.com/cgraf78/ds.git
cd ds
bash install.sh
```

Keep that checkout in place: the installer publishes version-coupled links to
`bin/ds` and the `ds(1)` manual page, while bundled plugins remain owned by the
checkout under `lib/plugins`. Updating the checkout therefore updates the
command and its plugins together without a second installed library tree.
Rerunning the curl command safely fast-forwards its clean managed checkout
before republishing the same links.

The default prefix is `~/.local`. Set `PREFIX` to move both public links, or
set `BIN_DIR` and `MAN_DIR` to choose their destinations independently. The
installer retargets existing symlinks but refuses to replace real files or
directories.

## Usage

```bash
ds                              # default session "ds" (plain tmux)
ds dev                          # session "dev" with dev profile
ds dev-work                     # session "dev-work" with dev profile
ds chat                         # session "chat" with chat profile

ds dev @myhost                  # dev session on remote host
ds @myhost                      # default session on remote host
ds @myhost -L 3011:3011         # forward local port 3011 → remote 3011 (ssh -L shorthand)
ds @myhost -R 3333:2222         # reverse-forward remote port 3333 → local 2222 (ssh -R shorthand)

ds -l                           # list active ds sessions
ds -l @myhost                   # list sessions on remote host

ds -k dev                       # kill session "dev"
ds -k                           # kill current session (inside tmux)
ds --killall                    # kill all ds sessions

ds --share                      # share current session via upterm
ds --share dev                  # share session "dev"
ds --unshare                    # stop sharing
ds --share-via upterm           # create/attach and share in one step

ds init bash                    # print Bash shell integration snippet
ds init zsh                     # print Zsh shell integration snippet
```

## Tmux Resurrect Integration

`ds` can preserve its session identity inside a tmux-resurrect snapshot. This
keeps restored sessions visible to `ds -l`, `ds --killall`, and shell
completion, and restores the selected login shell for future windows.

Configure tmux-resurrect to call the integration around its normal save and
restore flow:

```tmux
set -g @resurrect-hook-post-save-layout 'ds resurrect save'
set -g @resurrect-hook-pre-restore-all 'ds resurrect begin'
set -g @resurrect-hook-post-restore-all 'ds resurrect restore'
```

The save hook appends versioned `ds` metadata to the exact resurrect snapshot
path supplied by the plugin and restricts that file to mode `0600`. The restore
hook ignores unknown versions and sessions that were not restored. The begin
hook distinguishes a restore that is rebuilding a large environment from one
that continuum suppressed. When tmux-continuum starts a new server, `ds` waits
for these hooks before creating another session or applying a new profile,
preventing the delayed restore from merging with freshly built multi-pane
layouts. Warm attaches retain the normal single-query path.

These hooks do not change tmux-resurrect's process policy. Choose any process
allowlist separately in tmux configuration.

When the tmux-tools default-server coordinator disables continuum's native
restore to keep additional tmux sockets isolated, it publishes
`@tmux-tools-resurrect-auto-restore` as `on`. `ds` then uses the same startup
wait and halt-file behavior for that coordinator. This tmux option is the
entire integration boundary: `ds` never invokes tmux-tools and does not require
its executable to be installed. Keeping the signal provider-owned lets other
consumers coordinate with the same restore lifecycle without adding a reverse
dependency from DS back to the coordinator.

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

User configuration lives in `$XDG_CONFIG_HOME/ds` when `XDG_CONFIG_HOME` is an
absolute path, falling back to `~/.config/ds` otherwise. Profiles define the
tmux window/pane layout. Bundled profiles live in `lib/plugins/`. User profiles
go in the configuration directory as `profile-<name>.sh` and take priority.

Each profile defines a `_profile_<name>()` function:

```bash
# ${XDG_CONFIG_HOME:-$HOME/.config}/ds/profile-myprofile.sh
_profile_myprofile() {
    local session="$1"
    # set up tmux windows/panes here
}
```

### Single-command profiles (data)

A profile that only renames window 1 and runs one command does not need its own
`.sh` file. Declare such profiles as `profile*.conf` files in the configuration
directory instead:

```text
# name     window   command
argus      argus    argus
claude     claude   claude
notes      notes    nvim ~/notes
```

Each row is `<name> <window> <command...>`; the command is the rest of the line
and may contain spaces (omit it for a rename-only profile). Rows become regular
profiles, so they resolve, list, and accept instances (`argus-foo`) like any
other. A `profile-<name>.sh` of the same name always overrides a row, so use a
`.sh` file when a profile needs a real multi-window/pane layout. See
[`examples/profile.conf`](examples/profile.conf). A complete function-based
layout is available as
[`examples/profile-workspace.sh`](examples/profile-workspace.sh); copy it to
the configuration directory and run
`DS_WORKSPACE_DIR=/path/to/project ds workspace`.

### Bundled profiles

**dev** — chatbot pane (top) + login shell (bottom) + separate login shell
window.

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

All `connect*.conf` files in the configuration directory are read (additive).
Format: two columns — hostname (glob patterns supported) and connect method.
First match wins.

```text
# ${XDG_CONFIG_HOME:-$HOME/.config}/ds/connect.conf
myserver      autossh
dev*          ssh
localbox      -
```

See `examples/connect.conf` for a template.

## Connect Methods

`ssh` is built-in. Other methods are `connect-<method>.sh` plugins in the
configuration directory (or bundled in `lib/plugins/`), defining
`_connect_<method>()`.

| Method | Description |
|---|---|
| `-` | Local-only, no remote connections |
| `ssh` | Standard SSH (built-in) |
| `autossh` | Auto-reconnecting SSH |
| `et` | Eternal Terminal (persistent connection) |

## Sharing

Share backends live in `lib/plugins/share-<backend>.sh` or as
`share-<backend>.sh` in the configuration directory. Config goes in the
configuration directory as `share-<backend>.conf`.

Only one session can be shared at a time. `ds -l` marks shared sessions with `[shared]`.

### Upterm backend

Config file: `share-upterm.conf` in the configuration directory (env vars
`DS_UPTERM_*` override):

| Config key | Env var | Description |
|---|---|---|
| `server` | `DS_UPTERM_HOST` | Server `host[:port]` or `[IPv6][:port]` (default: `uptermd.upterm.dev:22`) |
| `known-hosts` | `DS_UPTERM_KNOWN_HOSTS` | Known hosts file for verification |
| `private-key` | `DS_UPTERM_PRIVATE_KEY` | SSH private key (auto-detected if unset) |
| `github-user` | `DS_UPTERM_GITHUB_USER` | Restrict access to a GitHub user |
| `authorized-keys` | `DS_UPTERM_AUTHORIZED_KEYS` | Restrict access via authorized_keys |
| `push` | `DS_UPTERM_PUSH` | `user@host` — push share info via SCP |
| `proxy-session` | `DS_UPTERM_PROXY_SESSION` | (deprecated, ignored) |
| `share-ttl` | `DS_UPTERM_SHARE_TTL` | seconds before share auto-expires (default: `3600`, set to `0` to disable) |

See `examples/share-upterm.conf` for a template.

When `known-hosts` is configured, DS reserves a unique private mode-`0600`
snapshot for the start, opens the configured source, and copies only through
that open descriptor. DS validates through a private regular-file hard link so
each validation pass gets an independent offset, while leaving a descriptor for
the same inode untouched for Upterm. This matters on systems where reopening
`/dev/fd/N` shares `N`'s current offset. Replacing the published snapshot path
after setup cannot substitute different trust bytes. Concurrent starts cannot
reuse or remove another start's snapshot, and failed or stopped starts retain
ownership metadata until cleanup succeeds.

Every Upterm start, including starts without `known-hosts`, holds one random
lifecycle token from preflight through shutdown. The PID, session, admin, log,
launch-gate, control, and trust state are bound to that token. A persistent
token-named supervisor holds a private control channel to the monitor that
directly parents Upterm. If the supervisor exits or is killed, channel closure
causes that monitor to stop and reap its own child. `ds --unshare` does not
signal a PID or process group recovered from a state file. Shutdown publishes a
`stopping` phase first, and another start remains blocked until the exact prior
token's cleanup has completed. Mismatched, malformed, or unverifiable state is
retained with an error rather than being adopted or deleted.

Portable Bash has no macOS-and-Linux equivalent of a parent-death signal. If
the direct-parent monitor itself is killed abruptly, DS therefore cannot prove
that the now-unowned Upterm process exited. It retains the complete lifecycle
and trust state, refuses another share, and does not report a clean stop. The
state should be removed only after the process has been verified terminated;
rebooting is the conservative recovery when that cannot be established.

The configured source must be a readable, non-symlink regular file on a
filesystem controlled by the user. DS checks the pathname before and after
opening it and rejects detectable unsafe-type changes. Bash cannot request an
atomic `O_NOFOLLOW` open, so the source path and its containing filesystem
remain trusted until the private copy completes; a same-authority writer that
can replace and restore the path or modify the opened inode within that interval
is outside this shell-only boundary. DS validates private hard links to the
copied inode, then hands Upterm an untouched descriptor for that inode through
`/dev/fd`.

DS intentionally accepts a conservative subset of Upterm's `known_hosts`
parser: blank lines; comments beginning with `#` after optional spaces or tabs;
plain case-sensitive host patterns with `*`, `?`, and `!`; OpenSSH hashed hosts;
numeric bracketed ports; the exact `@cert-authority` and `@revoked` markers; and
key records whose declared type matches a key that the installed `ssh-keygen`
can parse. Parseable records outside that subset are rejected with their line
number rather than silently interpreted differently. Keep unrelated records in
a separate file if another SSH consumer requires a broader grammar.

Supported trust consists of a directly pinned raw `ssh-ed25519` key. RSA pins
are rejected because `ssh-keyscan` cannot distinguish the RSA-SHA2 algorithms
Upterm accepts from legacy `ssh-rsa`/SHA-1. DS probes the certificate algorithms
first, then raw ED25519, and verifies the key Upterm would select. A server
advertising a host certificate is rejected because a shell-only preflight
cannot prove Upterm's CA, principal, validity, revocation, and signature checks
before launch. For the same reason, `@cert-authority` trust and direct
certificate pins are unsupported; configure the server to present a raw
ED25519 host key instead.

An `@revoked` record rejects only its exact key and, like Upterm, applies that
revocation across the file regardless of its host pattern. Missing, malformed,
unreachable, unsupported, revoked, ambiguous, or mismatched trust fails closed;
DS never rewrites the trust file from unauthenticated scan output. Review and
update changed trust out of band.

Server names must use printable ASCII URI host syntax. Use an IDNA/punycode name
instead of raw non-ASCII text. Malformed authorities are rejected before trust
checks, state creation, or Upterm launch.

#### Proxy session

When sharing, connecting clients get a plain login shell on the host. From
there they can interact with your tmux sessions non-destructively via `tmux
capture-pane` (read) and `tmux send-keys` (write) without mirroring into or
resizing your active session.

#### Share TTL

Shares expire automatically after `share-ttl` seconds (default: 1 hour). Each
watcher is bound to the lifecycle token it was created for, so an old timer
cannot stop a replacement share. Reset and shutdown use a private cooperative
request/acknowledgement rather than signaling a PID recovered from state.
Malformed or unverifiable watcher state is retained with an error. Running `ds
--share` on an already-shared session resets the timer. Set `share-ttl = 0` to
disable auto-expiry.

## Shell Integration

Add to `~/.bashrc`:

```bash
eval "$(ds init bash)"
```

This provides tab completion and ET connect support.

For Zsh, add this after `compinit` in `~/.zshrc`:

```zsh
eval "$(ds init zsh)"
```

This provides Zsh completion plus the same SSH auto-attach behavior.

### Auto-attach on SSH login

Set `DS_SSH_AUTO_ATTACH` **before** the `eval` line to auto-create/attach a tmux session on SSH login:

```bash
DS_SSH_AUTO_ATTACH=ds         # attach to default "ds" session
# DS_SSH_AUTO_ATTACH=dev      # attach to "dev" session instead
eval "$(ds init bash)"
```

Skip auto-attach for a single login with `NO_TMUX=1`.

## State

Runtime state lives under `$XDG_STATE_HOME/ds/` when `XDG_STATE_HOME` is an
absolute path, falling back to `~/.local/state/ds/`. Set `DS_STATE_DIR` to
override the complete state directory. State directories use mode `0700`, and
handoff files use mode `0600`.

## License

MIT — see [LICENSE](LICENSE).
