# Architecture

```text
  local herdr ─┐                                         ┌── omaherd-attach ── hyprctl / herdr agent focus
               ├── omaherd-status.py ── JSON ── Service.qml ─┤                  (ssh for a remote host)
  ssh host ────┤   (concurrent, one           (Process poll,  └── omaherd-notify ── omarchy-notification-send
  ssh host ────┘    ssh master per host)       state clocks,                       (-r replace, dismiss to withdraw)
                                               notification diff)
                                                    │
                                                    ▼
                                                 Model.js  (pure functions, node --test)
                                                    │
                                        ┌───────────┴───────────┐
                                        ▼                       ▼
                                    Panel.qml               BarWidget.qml
                              (hero + herd meter,        (sheep, urgent count,
                               sections, hosts,           herd dots, IPC handler,
                               keyboard cursor)           settings, panel loader)
```

## Collection — `omaherd-status.py`

Standard-library Python, run as a short-lived process by the shell's timer. It
prints one JSON document on stdout and exits.

All child stdout/stderr is drained concurrently through `run_capped()` in
`omaherd_io.py`. Status commands allow 1 MiB stdout and 64 KiB stderr, then the
whole child process group is killed on overflow. Socket snapshots have their
own 1 MiB frame ceiling. Normalization keeps at most 512 agents, 128 sessions
per target, bounded strings, and a final JSON envelope no larger than 512 KiB.
Target records omit their duplicate internal agent arrays before serialization.

Per target (local plus each monitored host, gathered concurrently with a
`ThreadPoolExecutor`, at most 8 hosts and 4 workers):

1. `herdr session list --json` for the named sessions and which are running.
   On a remote host the same shell trip appends the machine's `hostname`
   behind a marker; it rides on every agent record so a focus can match the
   window title HerdR writes (`<hostname>: <workspace>`).
2. A `session.snapshot` per running session — locally over the session's Unix
   socket reported by the listing (`socket_snapshot()`, newline-delimited JSON,
   one request per connection, ~2 ms), falling back to
   `herdr --session <name> api snapshot` when the socket is missing or slow.
3. `normalize_snapshot()` flattens the snapshot into per-agent records — key,
   host, session, pane id, terminal id, workspace/tab ids, labels and numbers,
   agent name, status, cwd and its label, title.

Remote targets wrap the same commands in `ssh`. `ssh_options()` supplies
`BatchMode=yes`, `ConnectTimeout=<sshTimeoutSec>`, and — when
`$XDG_RUNTIME_DIR/omaherd/` can be created `0700` — `ControlMaster=auto`,
`ControlPath=<dir>/ssh-%C`, `ControlPersist=60`, so the two queries per session
every few seconds ride one shared connection per host. `target_command()`
builds a single `/bin/sh -lc` script with a widened `PATH` (mise shims, nix
profiles, Homebrew) because HerdR is rarely on a noninteractive SSH `PATH`.

`discover_hosts()` offers machines you could monitor but do not yet:
`discover_ssh_hosts()` parses `~/.ssh/config` (following `Include`, skipping
wildcards and `User git` blocks) and `discover_tailscale_hosts()` reads
`tailscale status --json` for online Linux and macOS peers. Both cap at 50.

`aggregate()` sorts agents (local first, then host, then state rank
blocked → done → working → unknown → idle), tallies `counts`, and derives
`statusText` ("7 need attention", "3 working", "No active agents",
"HerdR is stopped", "HerdR is not installed"), `hasErrors` and `lastError`.

`fixture_path()` / `load_fixture()` are the developer drop-in: `OMAHERD_FIXTURE`
or `$XDG_RUNTIME_DIR/omaherd/fixture.json` replaces live collection entirely
(see CONTRIBUTING.md).

## Polling and notifications — `Service.qml`

A `Timer` at `refreshIntervalSec` runs the helper through a Quickshell
`Process`; a refresh requested while one is running sets `_refreshPending`
instead of stacking processes. Between polls, HerdR itself pokes the widget:
`herdr-plugin.toml` at the repo root declares event hooks for
`pane.agent_detected`, `pane.agent_status_changed` and `pane.closed` that run
`omaherd-hook`, which calls the `poke` IPC verb (a plain `refresh(false)`).
`ensureHook()` links the plugin once per shell start when the
`instantUpdates` setting is on and `herdr plugin list` does not show it. Hook
setup also runs inside the bounded Python helper, so the long-lived QML process
never collects raw HerdR output. Status and opt-in peek use `SplitParser` plus
matching character caps instead of `StdioCollector`; their producers already
enforce the tighter byte caps.

`applyStatus()` parses through `Model.parseStatus()` (which fails closed on bad
JSON), then:

- **State clocks.** HerdR only numbers state changes, so `stampStateClocks()`
  stamps each agent with `since` — the first time *this shell process* saw the
  agent in its current state — and carries it across polls while the state
  holds. `now` is the wall clock of the snapshot, so elapsed labels move only
  when the rows do.
- **Notification diff.** `updateNotifications()` compares the previous
  `_agentStates` / `_knownHosts` maps against the new snapshot.
  `Model.notificationCloses()` yields agents that stopped waiting;
  `Model.notificationEvents()` yields agents that newly entered `blocked` or
  `done`. Nothing fires on the first snapshot, so a shell restart does not
  replay a backlog; instead `reconcileNotifications()` sends the helper a
  `--kind reconcile` with the keys still loud, and every stored toast for any
  other agent comes down — the shell restores popups across a restart, the
  service's memory does not. `notifyOn` filters `done` out in "Needs input
  only" mode and everything in "Off"; closes are always sent.

Actions run through `Quickshell.execDetached`: `attachAgent()` wraps the attach
helper in `omarchy-launch-terminal`, `focusAgent()` calls it with `--focus`,
`openHerdr()` opens a session in a terminal.

## Presentation — `Model.js`

Pure JavaScript functions, loaded by both QML files and unit-tested directly
with `node --test`. Nothing here touches the filesystem, a process or Qt.

- Parsing and defaults: `parseStatus`, `defaultStatus`, `defaultCounts`.
- Sectioning and order: `agentSections` (NEEDS YOU / WORKING / QUIET, or per
  host), `flattenSections`, `compareAgents`, `sectionMeta`.
- Text: `agentTask` (the pane title with workspace and agent-name frames peeled
  off), `agentDetail`, `agentMeta`, `stateLabel`, `tallyLabel`, `sinceLabel`,
  `sinceSentence`, `tooltip`, `heroMeta`, `shortHost`, `hostChip`.
- The herd graphics: `herdDots` (one per agent, capped), `herdSegments`
  (stacked meter shares) and `meterWidths` (proportional widths with a floor,
  so one blocked agent among twenty stays visible).
- Hosts: `connectionRows` merges live targets and discovered hosts into the
  chooser rows; `validRemoteTarget` guards the manual field.
- Notifications: `agentStateMap`, `hostMap`, `notificationEvents`,
  `notificationCloses`, `notificationText`.

## Panel — `Panel.qml`

A `KeyboardPanel` built to be glanced at. Pinned header: the herd meter
(`Model.herdSegments` / `Model.meterWidths`), one legend line
(`Model.herdLegend`, which folds idle and unknown into "quiet"), the
group/refresh buttons, and a single error line when a poll failed. Then the
rows, then pinned key hints.

The rows are one flat list from `Model.panelRows(sections, connections, folds)`
rendered by one `Repeater` whose delegate is a `Loader` picking a component by
`row.kind`:

- `agent` — one line (mark, `workspace · agent · host`, elapsed); the task sits
  underneath only for agents that need a person or when the cursor is on the
  row. The first row of a section carries the section heading.
- `quiet` — one fold row standing in for the idle/unknown agents (attention
  mode only). Enter unfolds it.
- `hosts` — one fold row whose summary (`Model.hostsSummary`) names the local
  machine, every monitored host (offline ones in the urgent tone) and how many
  discovered hosts are available. Enter unfolds the chooser: `host` rows and
  the `manual` entry row. It opens itself when there are no agents at all.

Every row has a `key`; the cursor remembers the key and `Model.rowIndex`
finds it again after a poll or a fold rebuilds the list, so the selection
stays on the same agent. Discovered hosts listed in the `ignoredHosts` setting
are filtered out by `Model.visibleConnections` before rows are built.

Keys: `J`/`K`/arrows move, Enter acts on the row (focus an agent, fold/unfold,
monitor or attach to a host, open the manual field), `A` attaches, `X` stops
monitoring a host or hides a discovered one, `G` flips grouping, `R`
refreshes, `O` opens HerdR, Escape closes. One `breath` animation on the root
drives every working mark.

## Bar widget — `BarWidget.qml`

The manifest entry point. Draws the sheep and up to six herd dots for active
(blocked/done/working) agents — larger for blocked/done — grouped by
host (`Model.herdDotGroups`, local first, a gap between machines, no overflow
marker; quiet agents draw nothing); the tooltip adds a per-host breakdown (`Model.hostBreakdown`); loads `Panel.qml`, forwards
Omarchy's bar/settings/popout contracts, and owns the IPC surface:

```
omarchy-shell io.github.salemsayed.omaherd <open|close|show|hide|toggle|refresh|poke|launch|status>
omarchy-shell io.github.salemsayed.omaherd monitor <host>
omarchy-shell io.github.salemsayed.omaherd unmonitor <host>
```

`status` returns JSON with `statusText`, `counts`, `monitoredHosts`, `targets`
and `agents`. The handler is gated on `ipcRegistrationReady` so that moving the
widget between bar sections does not leave two handlers fighting for the same
IPC target — `tests/IpcLifecycle.test.js` pins that.

## Actions — `omaherd-attach`

Two modes.

`--focus` (Enter, and the notification click) builds
`herdr --session <s> agent focus <pane>` — locally, or over the same
`BatchMode` connection-sharing SSH, so a focus rides the master the monitor
already holds open. It then finds a local window to raise by walking `/proc`
for the process tree and matching it against `hyprctl clients -j`:

- Local: a `herdr` client process for that session. When several clients show
  the same session, the HerdR-managed `<hostname>: <workspace>` title chooses
  the one displaying the target rather than whichever client has the oldest
  process id. If none matches, the pane is focused first and titles are retried.
- Remote: a `herdr --remote <host>` client, also disambiguated by its workspace
  title when several clients show the same host and session; failing that, a
  window whose title ends in HerdR's `<host>: <workspace>` form *and* whose
  process tree contains one of `ssh`, `mosh`, `mosh-client`, `et`, `autossh`.

If an open remote carrier is showing another workspace, the helper focuses the
target first, briefly waits for HerdR to update the carrier title, then repeats
the window lookup before falling back to a new terminal.

If a window is found it is raised through Hyprland's `hl.dsp.focus({ window })`
dispatcher (with the pre-Lua dispatcher as a compatibility fallback) and the
focus command runs. If not, it re-execs itself through
`omarchy-launch-terminal` — the same thing `A` does.

Without `--focus` (the `A` key, middle click) it execs the interactive attach
directly: `herdr --session <s> agent attach <pane>`, or `ssh -t` into the same.

Two more modes exist only when the `peekAndReply` setting is on: `--peek
--lines N` prints `herdr agent read <pane> --lines N --format text` (the
service runs it through a `Process` and shows stdout under the row), capped at
64 KiB stdout and 16 KiB stderr regardless of line length; `--reply
TEXT` runs `pane send-text` then `pane send-keys enter`. Both wrap in the same
BatchMode SSH for a remote host.

All arguments pass `validate()` first (host, session and target regexes).

## Notifications — `omaherd-notify`

One toast per agent key. `--kind blocked|done` raises or replaces;
`--kind close` withdraws; `--kind reconcile --keep <key>…` withdraws every
stored toast whose key is not kept (the first poll after a shell start).

Every invocation takes an `flock` on `notifications.lock` around its
read-modify-write of the store — one poll with seven agents going loud is seven
concurrent helper processes — and first retries any withdrawal still marked
pending. A withdrawal counts as pending when the shell answered nothing
(typically because it was restarting), so a toast the shell later restores is
still taken down by the next event.

Toasts go through `omarchy-notification-send` with the plugin glyph, an urgency
(`critical` for blocked, kept on screen; `normal` and 12 s for done) and
`--exec` carrying the attach helper invocation, so clicking the card does
exactly what Enter does. `-p` prints the notification id, which is stored per
agent key in `$XDG_RUNTIME_DIR/omaherd/notifications.json` alongside the
summary and a timestamp; the next event for the same agent passes it back as
`-r` so the card is replaced in place rather than stacked. Non-pending entries
older than 24 hours are pruned as leftovers from a shell restart.

Withdrawing runs `omarchy-shell notifications dismiss <summary>`, because the
Omarchy shell ignores D-Bus `CloseNotification` for cards already on screen; a
D-Bus close is still issued for any other notification daemon. When
`omarchy-notification-send` is missing, plain `notify-send` is used and the
click action is simply unavailable.

## Settings

Declared in `manifest.json` and read by `Service.qml` / `Panel.qml` through the
plugin settings contract (Omarchy Setup → Plugins → Omaherd).

| Key | Type | Default | Drives |
| --- | --- | --- | --- |
| `groupBy` | enum: Attention, Host | Attention | Which sections `Model.agentSections` builds. `G` writes it. |
| `barHerd` | boolean | true | Whether `BarWidget.qml` draws the per-agent dots beside the sheep. |
| `refreshIntervalSec` | integer 2-60 | 4 | The `Service.qml` poll timer. |
| `remoteHosts` | string | "" | Hosts passed as `--remote-host` to the status helper. **Monitor** / `X` / the IPC `monitor` and `unmonitor` verbs write it. |
| `ignoredHosts` | string | "" | Discovered hosts the chooser never offers. `X` on a discovered host adds it; monitoring a host removes it again. |
| `sshTimeoutSec` | integer 1-15 | 3 | `ConnectTimeout` for background checks, and the focus helper's `--timeout`. |
| `notifyOn` | enum: Needs input and done, Needs input only, Off | Needs input and done | Which state changes raise a toast. Withdrawals are sent regardless. |
| `instantUpdates` | boolean | true | Whether the service links the HerdR hook plugin so local state changes poke the bar immediately. |
| `peekAndReply` | boolean | false | Whether `P` (read the pane's last lines) and `I` (type a reply into the pane) are available. Gated in `Service.qml`, not only in the panel. |

`Service.qml` clamps every numeric setting to the manifest's range and still
honours an older boolean `notifications` setting when `notifyOn` has never been
written.
