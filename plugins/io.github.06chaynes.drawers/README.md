# Omarchy Drawers

Group bar widgets into a single expandable pill. Click the pill to drop a card
below the bar holding the tucked widgets, live and fully interactive — not
screenshots or shortcuts, the real widget instances.

```
 [ 󰎈 Media ▾ ]        ← the pill on the bar
        │
        └──▶  ┌──────────────────────┐
              │  󰝚   󰊖   󰒓   󰊴   +  │   ← the real widgets, hosted
              └──────────────────────┘
```

## What it does

- **Tucks widgets, keeps them alive.** A tucked widget is moved out of
  `bar.layout.*` and parked inside the drawer's own `widgets` array, with its
  inline settings intact. Its id is mirrored into `plugins[]` so the shell keeps
  its component registered and the drawer can instantiate it.
- **Auto-Drawer.** A two-step wizard reads the bar as it stands, groups the loose
  widgets by their plugin category, and offers a proposal you edit before
  adopting. It only ever *adds* drawers — anything already tucked by hand is
  left alone.
- **One manager for every drawer.** A single window lists every drawer, lets you
  add and remove them, and edits the selected one against a searchable
  catalogue of installed bar widgets. Reachable from the Omarchy menu, so it
  works before you have any drawers at all. Everything is staged — adding,
  removing, renaming, and moving widgets between drawers all edit a local copy,
  and **Save Changes** commits the whole set in one atomic write. Discard throws
  the staged edits away.
- **Tooltips.** The bar only draws tooltips for widgets that live in the bar
  window, so the drawer draws its own — preferring the widget's live text (the
  current track, the current state) over its catalogue name.
- **Satellite alerts.** A tucked widget that raises an alert slides out beside
  the pill for a configurable spell, then folds back. The shell's bar-widget
  base class has no alert concept, so the drawer defines one: a widget opts in
  by exposing a boolean `hasAlert`, `alert`, `urgent`, `attention` or
  `needsAttention` on its root. **No widget shipped today does**, so this stays
  dormant until one adopts the contract.
- **Reversible.** Untick a widget and it returns to the bar with its settings,
  to the section and position it was tucked from. A widget that was never
  tucked through the plugin — one written into a drawer by hand — has no
  recorded origin, so it goes to the section its own manifest declares as
  `defaultSection`, which is where the shell would place it if you enabled it
  fresh.

## Settings

Configured inline in `~/.config/omarchy/shell.json`, or through the manager.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `icon` | string | `󰉋` | Glyph shown on the bar. The manager offers a searchable palette, and the field accepts any glyph typed directly. |
| `label` | string | `""` | Optional text beside the glyph. |
| `showLabel` | bool | `false` | Whether to draw the label. |
| `tooltip` | string | `""` | Overrides the generated pill tooltip. |
| `layout` | `row`\|`grid` | `row` | Single row, or a multi-column card. |
| `columns` | int | `2` | Columns when `layout` is `grid`. |
| `alertMode` | `slideout`\|`badge-only`\|`off` | `slideout` | How an alert is surfaced. |
| `alertDuration` | int | `8` | Seconds a slid-out widget stays out. |
| `widgets` | array | `[]` | The tucked widgets. Managed by the plugin. |

Two further keys are written by the plugin and should not be edited by hand:
`drawerId` (opaque identity, so several drawers stay distinguishable even when
they share a label) and `origins` (where each tucked widget came from, so it can
be put back).

```json
{
  "id": "io.github.06chaynes.drawers",
  "icon": "󰎈",
  "label": "Media",
  "showLabel": true,
  "layout": "row",
  "widgets": [
    { "id": "melonamin.apple-music" },
    { "id": "io.github.calebhat.weather", "unit": "imperial" }
  ]
}
```

`allowMultiple` is `true` — add as many drawers as you like, in any section.

## Auto-Drawer

Open it from **Setup → Drawers → Auto-arrange**, the **Auto-arrange…** button in
the manager, or `omarchy-shell io.github.06chaynes.drawers autoArrange`.

**Step 1 — preferences.** Which bar sections to reorganize, the minimum widgets
a group needs to become a drawer, the maximum number of drawers, and any widgets
to always keep on the bar.

**Step 2 — proposal.** Every proposed drawer, with an editable glyph and name,
its section, and its members. Drop a widget from a group and it stays on the bar;
skip a whole group and it is not created. Below the proposal is everything the
wizard deliberately left alone, with the reason. Nothing is written until
**Adopt**.

Widgets whose manifest cannot be read — custom `command`/`qml` bar modules,
plugins that are disabled — are never moved.

## Control point

Everything configurable lives in one window — the drawer list, the editor, and
Auto-arrange — reachable whether or not you have a drawer yet. It is a `panel`
entry point with `keepLoaded: true`, so the shell mounts it independently of the
bar; a manager that only existed inside a bar widget could not create your first
drawer.

Open it from the Omarchy menu (Super+Space → Setup → Drawers), from the pill
(right-click, or the `+` tile in the dropdown), or directly:

```bash
omarchy-shell io.github.06chaynes.drawers manage        # the manager
omarchy-shell io.github.06chaynes.drawers edit <id>     # preselect one drawer
omarchy-shell io.github.06chaynes.drawers autoArrange   # straight to the wizard
omarchy-shell io.github.06chaynes.drawers close
omarchy-shell io.github.06chaynes.drawers status
```

### Omarchy menu

The menu entries are not installed automatically. Add them with:

```bash
omarchy-shell io.github.06chaynes.drawers installMenu
# or: ~/.config/omarchy/plugins/io.github.06chaynes.drawers/drawer-config.py install-menu
```

That writes a clearly delimited block into
`~/.config/omarchy/extensions/omarchy-menu.jsonc`, giving you **Setup → Drawers →
Manage Drawers / Auto-arrange**. The file is live-watched, so the entries appear
without a restart. Only the block between its own `BEGIN`/`END` markers is ever
touched, so hand-written entries and other tools' managed blocks are left alone.
Remove it with `uninstallMenu`.

### The pills

Each drawer on the bar answers on a second target, because those verbs are about
one dropdown rather than about configuration:

```bash
omarchy-shell io.github.06chaynes.drawers.bar open
omarchy-shell io.github.06chaynes.drawers.bar close
omarchy-shell io.github.06chaynes.drawers.bar toggle
omarchy-shell io.github.06chaynes.drawers.bar status
```

`status` returns one entry per drawer on the bar, reporting for each slot
whether the widget resolved from the registry and whether it is live — the
quickest way to tell a real widget from a placeholder tile:

```json
[{"label":"Media","drawerId":"5572bb7b543a","open":false,"configured":4,
  "slots":[{"id":"melonamin.apple-music","registered":true,"live":true,"width":27,"height":26}]}]
```

Only one drawer instance claims the IPC target — several claiming it would
leave all but one silently inert — and it fans every verb out to its peers, so
`open`, `close` and `toggle` still reach every drawer on every monitor.

## Backend

`drawer-config.py` owns every read and write of `shell.json`:

```bash
./drawer-config.py list-plugins
./drawer-config.py get-state                      # every drawer + the catalogue
./drawer-config.py save-drawer    --payload <json>
./drawer-config.py apply-drawers  --payload <json>   # reconcile the whole set
./drawer-config.py analyze       --prefs <json>
./drawer-config.py apply-auto    --payload <json>
./drawer-config.py install-menu | uninstall-menu
./drawer-config.py sync
```

Every command prints a single JSON object with an `ok` field, and writes go
through a temporary file resolved past symlinks so a dotfiles-managed
`shell.json` is not detached.

## Known limits

- **Panels position against the pill, not the icon.** A tucked widget's own panel
  is re-anchored to the drawer pill, because the widget itself now lives in the
  dropdown window rather than the bar. Panels open under the pill.
- **Bar-level features do not reach into a drawer.** `switchPanelFrom`,
  drag-to-reorder, and the bar's own tooltip surface all key off widgets being
  registered bar slots. A tucked widget is not one.
- **A tucked widget's own panel may fold the drawer.** The drawer dismisses on
  outside clicks via `HyprlandFocusGrab`; a child panel that takes focus can
  clear that grab. The drawer reopens on the next click of the pill.
- The drawer's tooltip is always drawn below the slot, so it is placed for a
  top bar. A bottom, left, or right bar will show it overlapping the dropdown.
- **Widgets with a fixed IPC target collide** if the same widget is somehow live
  twice. The drawer instantiates each tucked widget exactly once, but a second
  monitor means a second bar surface and therefore a second instance — the same
  as any bar widget.
- **A tucked widget's own settings live in `plugins[]`.** Because a tucked
  widget is no longer in `bar.layout.*`, the shell writes any settings it saves
  onto its `plugins[]` entry. Untucking merges that copy back, so nothing is
  lost, but the drawer's stored copy is stale until then.
- The shell does not watch `shell.json`, so changes made here appear after
  `omarchy restart shell`.

## Requirements

Omarchy shell with `BarWidgetRegistry` (`bar.barWidgetRegistry`), Quickshell
0.3+, Python 3.
