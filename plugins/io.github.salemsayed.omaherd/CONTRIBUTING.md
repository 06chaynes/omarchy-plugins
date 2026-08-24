# Contributing

Issues and pull requests are welcome. Changes that touch SSH invocation, host
validation, or what Omaherd reads out of a HerdR snapshot need tests and a note
on their security impact — see [SECURITY.md](SECURITY.md).

## Development install

From a checkout:

```bash
plugin_id=io.github.salemsayed.omaherd
mkdir -p ~/.config/omarchy/plugins
ln -s "$PWD" ~/.config/omarchy/plugins/$plugin_id
omarchy-shell shell rescanPlugins
omarchy plugin enable "$plugin_id" --section right --yes
```

The symlink means you edit the repo and the shell loads it.

**QML and `Model.js` changes need `omarchy-restart-shell`.** Quickshell caches
a plugin's QML components and JS resources for the life of its process, so
`omarchy-shell shell rescanPlugins` and `reloadConfig` both keep rendering the
old panel. Restart, wait a couple of seconds, then look. Python helpers are
re-executed on every poll and need no restart. QML warnings land in the shell
log:

```bash
journalctl --user | grep quickshell
```

## Tests

```bash
./tests/run
omarchy plugin validate .
```

`tests/run` runs, in order:

- `node --test tests/Model.test.js tests/IpcLifecycle.test.js`
- `tests/test_status.py`, `tests/test_attach.py`, `tests/test_notify.py`
- a JSON parse of `manifest.json`
- `qmllint` over every `.qml`, if it is installed (Arch: `qt6-declarative`).
  The plugin imports the shell's `qs.*` modules, which qmllint can only
  resolve through a directory literally named `qs`, so the script borrows
  `$OMARCHY_SHELL_DIR` (default `/usr/share/omarchy/shell`) through a
  temporary symlink. Without qmllint the step prints a skip and the run still
  passes.

`.github/workflows/test.yml` runs the same script on Node 22 and Python 3.12;
the QML lint is skipped there because the shell's modules are not available.

## Driving the panel with a fixture

`omaherd-status.py` will serve a saved status instead of collecting a live
one, which is how you develop against a herd you do not have. Either:

```bash
OMAHERD_FIXTURE=tests/fixtures/many-agents.json ./omaherd-status.py --pretty
```

or, to make the running shell use it:

```bash
mkdir -p "$XDG_RUNTIME_DIR/omaherd"
cp tests/fixtures/many-agents.json "$XDG_RUNTIME_DIR/omaherd/fixture.json"
```

Then press `R` in the panel, or run
`omarchy-shell io.github.salemsayed.omaherd refresh`. Remove the file to go
live again:

```bash
rm "$XDG_RUNTIME_DIR/omaherd/fixture.json"
```

The env var wins over the drop-in file. A fixture is served verbatim except
for `generatedAt`, which is restamped so elapsed labels move.

Three fixtures ship in `tests/fixtures/`:

| Fixture | What it shows |
| --- | --- |
| `many-agents.json` | 24 agents over four hosts (local, `workbox`, a Tailscale name, an unreachable `buildbox`), 7 needing attention. Every section, the full meter, host chips, overflow on the bar dots. |
| `offline-host.json` | Local HerdR running with no agents and a monitored host that is unreachable, so the error and retry copy are visible. |
| `stopped.json` | HerdR installed but stopped, plus one discovered host — the empty state and the host chooser. |

## Screenshots and the README media

`tools/demo/capture.sh all` regenerates every image under `docs/images/` and
`preview.png` from the anonymised fixtures — stills, the GIF, the announcement
card. It drives the running shell over IPC and `wtype`, shoots with `grim`,
and crops each shot to the panel's own accent frame
(`tools/demo/framecrop.py`) so nothing behind the panel is ever published.
Run it with the shell on a 1920-wide primary output and the sheep near the
right end of the bar; `PANEL_X`/`BAR_RIGHT` adjust for other layouts.

For one-off checks by hand:

```bash
omarchy-shell io.github.salemsayed.omaherd open
grim -o HDMI-A-1 shot.png
```

Name the output explicitly — a second monitor may be attached, and a bare
`grim` will capture the wrong one or both. Crop with `magick`. `wtype -k j` /
`wtype -k Return` drives the panel's keyboard cursor for states you cannot
otherwise reach. `preview.png` in the repo root is the README image; refresh
it with a fixture, never with real hostnames or real task titles you would not
publish.

## Design rules

The panel's look is deliberate. Keep new rows inside these:

- **Glanceable first.** No hero, no title: a thin meter and one legend line,
  then rows. Agent rows are one line; the task appears only under agents that
  need a person (or under the cursor). Quiet agents and the host chooser fold
  behind one row each (`Model.panelRows`), and the hosts fold's summary still
  names an offline host in the urgent tone so a problem is never hidden.
- **Order is agents, then the folds, then the host chooser.** The inbox leads
  because that is what the plugin is for. `rows` on the panel root is the
  single source of that order for the layout and the keyboard cursor alike;
  every row has a key the cursor follows across polls.
- **Sections** come from `Model.agentSections(agents, mode)`: NEEDS YOU /
  WORKING / QUIET in attention mode (default, across hosts, with a host chip
  on remote rows) or one per host in host mode. `G` flips it and persists to
  the `groupBy` setting.
- **Only `blocked` and `done` get a color** (urgent, accent). Working and idle
  stay in the text tone so the two states that want a person cannot be drowned
  out. NEEDS YOU is the one heading allowed the urgent tone.
- **One shared breath animation** lives on the panel root (and one on the bar
  widget root), never per row. The status poll rebuilds delegates every few
  seconds, which would restart per-row pulses out of step.
- **Quiet marks fade, they do not darken.** Use `Util.alpha(foreground, …)`,
  not `Qt.darker()`: on a light theme darkening makes a mark *louder*, so an
  idle dot would outweigh a working one. `dim` is still right for secondary
  *text*.
- **The sheep never turns red**, and nothing in the bar is a number or a
  badge. Attention is a larger red or blue dot among the herd dots; the hero
  relies on the meter and the NEEDS YOU heading.
- **Line two of a row is the agent's task** — `Model.agentTask()`, the pane
  title with workspace and agent-name frames peeled off — falling back to the
  tab/cwd detail. Task text is forced `AlignLeft` so Arabic titles do not jump
  to the right edge.
- The hero carries the **herd meter** (`Model.herdSegments` +
  `Model.meterWidths`) with a legend; the bar draws **one dot per agent**
  (`Model.herdDots`, capped at 6).
- Elapsed time comes from `Service.stampStateClocks` (the first time this
  process saw the state) and is rendered by `Model.sinceLabel`.
- Rows call `root.revealItem(this)` on `hasCursorChanged`, so nested repeaters
  never need an `itemAt` lookup.
- **Pane title is fine; pane output is not.** Titles are structured metadata.
  `herdr agent read` must never be pulled into the shell.

## Pull requests

- Put logic in `Model.js` as pure functions and add cases to
  `tests/Model.test.js`; changes to `omaherd-status.py`, `omaherd-attach` or
  `omaherd-notify` need cases in the matching `tests/test_*.py`.
- Run `./tests/run` and `omarchy plugin validate .` before submitting.
- Never put real hostnames, working directories or task titles in fixtures,
  screenshots or commits.
- User-facing text should read like something a person would say. Keep new copy
  in `Model.js` so the tests can see it.
- Update `manifest.json` when you add a setting, and describe what the setting
  drives in `docs/ARCHITECTURE.md`.
