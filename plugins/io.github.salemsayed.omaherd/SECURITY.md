# Security policy

Omaherd watches coding agents across machines you already have SSH access to.
It holds no credentials of its own, but it does reach other computers on a
timer, so anything that widens what it reaches or what it runs is treated as a
security change.

## Reporting a vulnerability

Email **salem.sayed@gmail.com**. Do not open a public issue for an
exploitable bug. Include the plugin version, the Omarchy and HerdR versions,
steps to reproduce, and the impact you observed.

## Threat model

Trusted: the local user account and kernel; Omarchy, Quickshell and the
compositor; OpenSSH and the user's `~/.ssh/config`; HerdR on both ends; the
plugin's installed source.

Out of scope: malware running as the same user; a compromised remote host you
have chosen to monitor; someone reading agent names or task titles off your
screen.

## What Omaherd reads

`omaherd-status.py` calls two read-only HerdR commands per session:

```
herdr session list --json
herdr --session <name> api snapshot
```

From the snapshot it keeps structured metadata only: host, session name,
workspace id/label/number, tab id/label/number, agent identity, state, pane
id, terminal id, working directory and its short label, and the pane **title**
the agent sets for itself. The title is metadata HerdR already publishes, and
the panel shows it as the agent's current task.

Pane **output** is not read in normal operation. Omaherd does not scrape
terminal contents and copies no agent output into the desktop shell. The one
exception is opt-in: with **Peek and reply from the panel** turned on (default
off), pressing `P` runs `herdr agent read <pane> --lines 14 --format text` for
that one pane — locally, or over the same BatchMode SSH for a remote host —
and shows the result under the row until the panel closes or another peek
replaces it. The helper retains at most 64 KiB of peek stdout and 16 KiB of
stderr; crossing either ceiling kills the producer and returns an error, so a
single overlong terminal line cannot grow the desktop shell. Nothing is
written to disk. `I` sends the line you typed with
`herdr pane send-text` followed by `pane send-keys enter`; Omaherd never sends
keystrokes it did not get from you. Local session snapshots are read from the
session's Unix socket (`session.snapshot`, one request per connection) when it
exists, otherwise through the CLI. Nothing collected is sent anywhere off the machine, and the only piece
written to disk is the toast summary kept in `notifications.json` (below) so a
toast can be withdrawn later; everything else lives in the shell process for as
long as a snapshot is current.

## How remote access works

Remote checks are plain OpenSSH, run as you, with no credentials stored by the
plugin. Every remote invocation carries `BatchMode=yes`, so a host that would
prompt for a password or a passphrase fails instead of hanging; use key-based
or `ssh-agent` authentication. `ConnectTimeout` comes from the `sshTimeoutSec`
setting (1-15 s). Users, ports, proxies, jump hosts and host-key verification
stay with OpenSSH and your own `~/.ssh/config`.

Host strings are validated before they can reach `ssh`. Both helpers apply the
same rules:

- `omaherd-status.py`: `REMOTE_HOST_RE = ^[A-Za-z0-9_.@-]+$`, plus a
  `ssh://` form accepted only by `valid_remote_target()` — scheme `ssh`,
  a hostname, no password component, a username matching
  `SSH_USER_RE = ^[A-Za-z0-9._~-]+$`, an empty path, no query or fragment,
  and a port in 1-65535.
- `omaherd-attach`: the identical `HOST_RE`, `SSH_USER_RE` and
  `valid_remote_target()`, plus `SESSION_RE = ^[A-Za-z0-9_.-]+$` for session
  names and `TARGET_RE = ^[A-Za-z0-9_.:-]+$` for pane ids. `validate()` exits
  with "Invalid SSH target" / "Invalid HerdR session name" / "Invalid HerdR
  agent target" rather than executing anything.

Session names that fail `SESSION_RE` are skipped when the snapshot is
normalized, so a strange name on the far end cannot travel into a later
command. `Model.js` mirrors the same host regex in `validRemoteTarget()` so
the manual **Other host…** field rejects bad input before the setting is
saved. Commands are built as argument lists and never through a shell on the
local side; the remote side runs one `/bin/sh -lc` script whose contents are
`shlex.quote`d.

The number of monitored hosts is capped at 8 per poll, queried concurrently
with at most 4 workers.

Every captured child process is read through the same concurrent bounded-pipe
runner. Status/discovery commands retain at most 1 MiB of stdout and 64 KiB of
stderr; compositor and focus helpers use smaller caps. Crossing either limit
kills the child process group immediately rather than discarding an unlimited
tail until timeout. Unix-socket snapshots are rejected above 1 MiB before JSON
parsing. Normalization retains at most 512 agents and 128 sessions per target,
truncates individual metadata strings, and will not emit more than 512 KiB of
JSON to Quickshell. The QML side applies matching character ceilings while it
streams that already-bounded output and does not use an accumulating
`StdioCollector`.

## What never opens a terminal

Monitoring is status-only. Background polling, host discovery and remote
focus all run noninteractively and never spawn a terminal or a window.
HerdR is never installed, restarted, upgraded or reconfigured by Omaherd, and
its managed remote bridge is not used.

Only two explicit gestures reach for a terminal:

- **Enter** (`omaherd-attach --focus`) runs one `herdr agent focus` over the
  same noninteractive SSH and raises a local window that is already showing
  the session. Only when there is no such window does it fall back to opening
  a terminal.
- **`A`** (or a middle click) attaches in a new terminal: `herdr agent attach`
  locally, `ssh -t` for a remote host.

## The HerdR hook

`herdr-plugin.toml` registers three event hooks that run `omaherd-hook`, a
shell script that atomically replaces `$XDG_RUNTIME_DIR/omaherd/hook.log` with
one short allow-listed event line and runs
`omarchy-shell io.github.salemsayed.omaherd poke`. The log therefore has a
constant upper bound instead of growing per event. It ignores the event
payload, takes no arguments from HerdR, and exits 0 regardless. Linking is the
only change Omaherd makes to HerdR's configuration, happens only while the
**Instant updates** setting is on, and is undone with
`herdr plugin unlink io.github.salemsayed.omaherd`. HerdR runs hooks with the
plugin root as their working directory and records each run in
`herdr plugin log list`.

## Privileges and processes

Everything runs as the ordinary desktop user, with no setuid binaries, no
system services, no sudo, and no polkit. There is no Omaherd daemon: the only
recurring work is the shell's own timer in `Service.qml`, which runs
`python3 omaherd-status.py` every `refreshIntervalSec` seconds (2-60,
default 4) and exits. Helpers are short-lived child processes;
`omaherd-attach` and `omaherd-notify` are started detached and terminate on
their own. Stopping or removing the plugin stops all of it.

Reading a remote host's state does require that host to trust your SSH key
already; Omaherd cannot create access it was not given.

## Files it writes

Omaherd writes only inside `$XDG_RUNTIME_DIR/omaherd/` (falling back to the
user-specific `/tmp/omaherd-<uid>/omaherd` when `XDG_RUNTIME_DIR` is unset).
Each directory level is rejected if it is a symlink or owned by another uid
and the application directory is verified as mode `0700` before use:

- **SSH control sockets** (`ssh-%C`) — the shared connection masters,
  removed by OpenSSH within `ControlPersist=60` of the last use.
- **`notifications.json`** (and its `notifications.lock`) — the notification
  id and summary per agent key, so a toast can be replaced or withdrawn, plus a
  pending flag for withdrawals that have not gone through yet. Non-pending
  entries older than 24 hours are pruned. The store is capped at 256 KiB and
  2,048 entries, read with `O_NOFOLLOW`, and replaced through a securely
  created temporary file. It contains agent keys and toast summaries, no agent
  output. The lock is created with `O_NOFOLLOW` and serialises the helper
  processes a single poll can fan out into.
- **`hook.log`** — only the latest timestamped allow-listed HerdR event; no
  agent data. A mode-`0600` temporary file is created inside the private
  directory and atomically renamed over the old log, so an existing symlink is
  replaced rather than followed and the file never grows with event count.
- **`fixture.json`** — optional, developer-only. When present it replaces live
  collection with a saved status (see CONTRIBUTING.md).

That directory is chosen because it is per-user, private, and cleared at
logout; the `/tmp` fallback is namespaced by uid and receives the same owner,
symlink and mode checks. Settings — including the monitored host list — live in Omarchy's
own `shell.json` through the standard plugin settings contract. Omaherd writes
no other state and no logs.

## Notifications

Toasts go out through `omarchy-notification-send` (or plain `notify-send` when
it is absent). The click action is passed as `--exec` and is always the attach
helper with validated arguments:

```
omaherd-attach --host <host> --session <session> --target <paneId> \
               --workspace <label> --hostname <label> --focus
```

The arguments come from the snapshot and are re-validated by `omaherd-attach`
itself before anything runs, so a click can only focus a pane. The hostname
is used only for matching a compositor window title; it is never executed or
sent back to the remote host. Withdrawing a
toast uses `omarchy-shell notifications dismiss <summary>` — the Omarchy shell
ignores D-Bus `CloseNotification` for cards already on screen — with the D-Bus
close still issued for other notification daemons. Summaries and bodies carry
the agent name, its task title and its host, so they reach whatever your
notification daemon does with a toast; set **Notify when an agent** to **Off**
if you would rather that metadata never left the panel.
