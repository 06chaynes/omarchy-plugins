#!/usr/bin/env python3
"""drawer-config.py - backend helper for the Omarchy Drawers bar widget.

Owns every read and write of ~/.config/omarchy/shell.json that the drawer
manager needs:

  list-plugins   discover installable bar widgets
  get-state      catalogue + the drawer entry being edited
  save-drawer    apply a staged edit (tuck / untuck / rename / relayout)
  sync           reconcile plugins[] with what the drawers actually hold
  analyze        propose drawers for the widgets still loose on the bar
  apply-auto     adopt a proposal, creating drawers and moving widgets in
  apply-drawers  reconcile the whole drawer set against a desired state
  install-menu   add Drawers entries to the Omarchy menu (Super+Space)
  uninstall-menu remove them again

Tucking a widget MOVES it: its layout entry is lifted out of bar.layout.* with
its inline settings intact and parked inside the drawer's `widgets` array,
alongside a note of where it came from. Untucking puts it back. The shell keeps
a tucked widget's component loaded because its id is listed in plugins[]
(PluginRegistry.findEntryLocation), so the drawer can instantiate it from
BarWidgetRegistry.
"""

import argparse
import json
import os
import sys
import uuid

SELF_ID = "io.github.06chaynes.drawers"

HOME = os.path.expanduser("~")
SHELL_JSON_PATH = os.path.join(HOME, ".config/omarchy/shell.json")
PLUGINS_DIR = os.path.join(HOME, ".config/omarchy/plugins")
OMARCHY_PATH = os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")
FIRST_PARTY_DIR = os.path.join(OMARCHY_PATH, "shell/plugins")

SECTIONS = ("left", "center", "right")


# --------------------------------------------------------------- config io

def load_shell_config():
    if not os.path.exists(SHELL_JSON_PATH):
        return {"version": 1, "bar": {"layout": {s: [] for s in SECTIONS}}, "plugins": []}
    with open(SHELL_JSON_PATH, "r", encoding="utf-8") as handle:
        config = json.load(handle)
    if not isinstance(config, dict):
        raise ValueError("shell.json does not contain an object")
    return config


def write_atomic(path, render):
    """Write via a temp file beside the real target, never through a symlink.

    os.replace on a symlinked path would detach a dotfiles-managed file, and a
    half-written temp left behind after a failure is worse than no write.
    """
    target = os.path.realpath(path)
    tmp_path = target + ".drawers.tmp"
    try:
        with open(tmp_path, "w", encoding="utf-8") as handle:
            render(handle)
            handle.flush()
            os.fsync(handle.fileno())
        if os.path.exists(target):
            os.chmod(tmp_path, os.stat(target).st_mode & 0o7777)
        os.replace(tmp_path, target)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def save_shell_config(config):
    config.setdefault("version", 1)

    def render(handle):
        json.dump(config, handle, indent=2, ensure_ascii=False)
        handle.write("\n")

    write_atomic(SHELL_JSON_PATH, render)


def layout_of(config):
    bar = config.setdefault("bar", {})
    layout = bar.setdefault("layout", {})
    for section in SECTIONS:
        if not isinstance(layout.get(section), list):
            layout[section] = []
    return layout


def entry_id(entry):
    if isinstance(entry, str):
        return entry.strip()
    if isinstance(entry, dict):
        return str(entry.get("id", "")).strip()
    return ""


def as_entry(entry):
    """Normalize a layout entry to a dict, preserving inline settings."""
    if isinstance(entry, str):
        return {"id": entry.strip()}
    if isinstance(entry, dict):
        return dict(entry)
    return {}


# ------------------------------------------------------------- discovery

def _read_manifest(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"drawer-config: skipping {path}: {exc}", file=sys.stderr)
        return None
    return manifest if isinstance(manifest, dict) else None


def _manifest_paths():
    """Mirror PluginRegistry.rescan()'s discovery rules."""
    found = []
    # First-party: depth 2-3, manifest.json or <Name>.manifest.json.
    for root, dirs, files in os.walk(FIRST_PARTY_DIR):
        depth = os.path.relpath(root, FIRST_PARTY_DIR).count(os.sep) + 1
        if depth > 3:
            dirs[:] = []
            continue
        for name in sorted(files):
            if name == "manifest.json" or name.endswith(".manifest.json"):
                found.append(os.path.join(root, name))
    # Third-party: exactly <pluginsDir>/<id>/manifest.json.
    if os.path.isdir(PLUGINS_DIR):
        for name in sorted(os.listdir(PLUGINS_DIR)):
            path = os.path.join(PLUGINS_DIR, name, "manifest.json")
            if os.path.isfile(path):
                found.append(path)
    return found


def discover_plugins(config):
    """Every installed bar widget the user could actually put in a drawer."""
    disabled = set()
    if isinstance(config.get("disabledPlugins"), list):
        disabled = {str(x) for x in config["disabledPlugins"]}

    catalogue = {}
    for path in _manifest_paths():
        manifest = _read_manifest(path)
        if not manifest:
            continue
        if manifest.get("schemaVersion") != 1:
            continue
        kinds = manifest.get("kinds")
        if not isinstance(kinds, list) or "bar-widget" not in kinds:
            continue
        entry_points = manifest.get("entryPoints")
        if not isinstance(entry_points, dict) or not entry_points.get("barWidget"):
            continue

        pid = str(manifest.get("id", "")).strip()
        if not pid or pid == SELF_ID or pid in disabled or pid in catalogue:
            continue

        bar_widget = manifest.get("barWidget") or {}
        catalogue[pid] = {
            "id": pid,
            "name": bar_widget.get("displayName") or manifest.get("name") or pid,
            "category": bar_widget.get("category", "Plugin"),
        }

    return sorted(catalogue.values(), key=lambda p: (p["category"].lower(), p["name"].lower()))


# -------------------------------------------------------------- identity

def iter_drawers(config):
    layout = layout_of(config)
    for section in SECTIONS:
        for index, entry in enumerate(layout[section]):
            if entry_id(entry) == SELF_ID:
                yield section, index, entry


def find_drawer(config, drawer_id=""):
    """Resolve which drawer entry an edit targets.

    Every drawer carries a stamped drawerId once get-state has run, so an id is
    the normal path; the single-drawer fallback exists for direct CLI use.
    Returns (section, index, entry, error).
    """
    drawers = list(iter_drawers(config))
    if not drawers:
        return None, None, None, "no drawer found in shell.json"

    if drawer_id:
        hits = [d for d in drawers if str(as_entry(d[2]).get("drawerId", "")) == drawer_id]
        if len(hits) == 1:
            return hits[0][0], hits[0][1], hits[0][2], None
        if len(hits) > 1:
            return None, None, None, f"drawerId {drawer_id!r} is not unique"
        return None, None, None, f"no drawer with drawerId {drawer_id!r}"

    if len(drawers) == 1:
        return drawers[0][0], drawers[0][1], drawers[0][2], None

    return None, None, None, "could not identify which drawer to edit"


# ----------------------------------------------------------- tuck / untuck

def take_from_bar(config, widget_ids):
    """Lift entries out of bar.layout.*, returning {id: (entry, section, index)}."""
    layout = layout_of(config)
    targets = set(widget_ids)
    harvested = {}
    for section in SECTIONS:
        kept = []
        for index, entry in enumerate(layout[section]):
            eid = entry_id(entry)
            if eid in targets and eid not in harvested:
                # The id of whatever survives immediately before this entry is
                # a stabler restore point than an absolute index: by the time
                # the widget comes back the section has lost its siblings and
                # gained a drawer.
                after = entry_id(kept[-1]) if kept else ""
                harvested[eid] = (as_entry(entry), section, index, after)
            else:
                kept.append(entry)
        layout[section] = kept
    return harvested


def default_sections():
    """Where the shell would place each widget if it were enabled fresh.

    Mirrors PluginRegistry.defaultBarWidgetSection. A widget tucked by hand in
    shell.json has no recorded origin, so this is the only sensible answer to
    "where does it go when it comes back".
    """
    sections = {}
    for path in _manifest_paths():
        manifest = _read_manifest(path)
        if not manifest:
            continue
        pid = str(manifest.get("id", "")).strip()
        section = str((manifest.get("barWidget") or {}).get("defaultSection", ""))
        if pid and section in SECTIONS:
            sections[pid] = section
    return sections


def restore_to_bar(config, restores):
    """Put untucked widgets back where they came from, as close as we can.

    Recorded origins are absolute indices from when each widget was tucked, so
    they only line up if the lowest index is reinserted first — otherwise a
    multi-widget untuck lands in reverse order.
    """
    layout = layout_of(config)
    fallbacks = None
    ordered = []
    for entry, origin in restores:
        section = origin.get("section") if isinstance(origin, dict) else None
        if section not in SECTIONS:
            if fallbacks is None:
                fallbacks = default_sections()
            section = fallbacks.get(entry_id(entry), "center")
        index = origin.get("index") if isinstance(origin, dict) else None
        if not isinstance(index, int) or index < 0:
            index = len(layout[section])
        after = str(origin.get("after", "")) if isinstance(origin, dict) else ""
        ordered.append((section, index, entry, after))

    ordered.sort(key=lambda item: (SECTIONS.index(item[0]), item[1]))
    # Consecutive widgets share an anchor, because each recorded the last entry
    # that survived before it. Re-point the anchor at what was just inserted so
    # they chain in their original order instead of stacking up reversed.
    chained = {}
    for section, index, entry, after in ordered:
        key = (section, after)
        anchor = chained.get(key, after)
        target = None
        if anchor:
            for position, existing in enumerate(layout[section]):
                if entry_id(existing) == anchor:
                    target = position + 1
                    break
        if target is None:
            target = min(index, len(layout[section]))
        layout[section].insert(target, entry)
        chained[key] = entry_id(entry)


def tucked_ids(config):
    ids = set()
    for _, _, drawer in iter_drawers(config):
        for widget in as_entry(drawer).get("widgets") or []:
            wid = entry_id(widget)
            if wid:
                ids.add(wid)
    return ids


def plugin_entry_settings(config, wid):
    """Settings the shell parked in plugins[] for a tucked widget.

    A tucked widget is not in bar.layout.*, so when it saves its own settings
    the shell's updateEntryInline writes them onto its plugins[] entry instead.
    That copy is therefore fresher than the one the drawer stored at tuck time,
    and it is also where the `addedBy` marker gets destroyed.
    """
    for item in config.get("plugins") or []:
        if entry_id(item) != wid or not isinstance(item, dict):
            continue
        return {k: v for k, v in item.items() if k not in ("id", "addedBy")}
    return {}


def drop_plugin_entries(config, widget_ids):
    """Remove plugins[] entries for widgets that are no longer tucked."""
    if not widget_ids or not isinstance(config.get("plugins"), list):
        return
    drop = set(widget_ids)
    config["plugins"] = [p for p in config["plugins"] if entry_id(p) not in drop]


def reconcile_center_anchor(config):
    """Drop bar.centerAnchor when the widget it names is no longer on the bar.

    Tucking the anchor widget is a legitimate choice, but leaving the bar
    anchored to something that is not in the layout any more is not — the
    center section would be pinned to a widget that does not exist.
    """
    bar = config["bar"]
    anchor = str(bar.get("centerAnchor") or "").strip()
    if not anchor:
        return
    layout = layout_of(config)
    present = {entry_id(e) for section in SECTIONS for e in layout[section]}
    if anchor not in present:
        bar.pop("centerAnchor", None)


def sync_plugins_array(config):
    """plugins[] must list exactly the tucked third-party widgets.

    A tucked widget is no longer in bar.layout.*, so plugins[] is the only
    thing keeping its component registered. Entries this plugin added for
    widgets that are no longer tucked are pruned, but entries the user (or
    another tool) put there for their own reasons are left alone.
    """
    if not isinstance(config.get("plugins"), list):
        config["plugins"] = []

    tucked = tucked_ids(config)
    layout = layout_of(config)
    in_bar = {entry_id(e) for section in SECTIONS for e in layout[section]}

    kept = []
    seen = set()
    # The panel entry point is what makes the manager reachable with no drawer
    # on the bar, and the shell only loads it while the plugin is enabled —
    # which means referenced somewhere in shell.json.
    if not any(entry_id(p) == SELF_ID for p in config["plugins"]):
        config["plugins"] = [{"id": SELF_ID}] + config["plugins"]

    for item in config["plugins"]:
        pid = entry_id(item)
        if not pid or pid in seen:
            continue
        seen.add(pid)
        # The marker survives only until the widget saves its own settings, so
        # it is a hint, not the record. Untucking prunes explicitly instead.
        if isinstance(item, dict) and item.get("addedBy") == SELF_ID and pid not in tucked:
            continue
        kept.append(item)

    for wid in sorted(tucked):
        if wid in seen or wid in in_bar or wid.startswith("omarchy."):
            continue
        kept.append({"id": wid, "addedBy": SELF_ID})
        seen.add(wid)

    config["plugins"] = kept


# ------------------------------------------------------------------ verbs

SCALAR_KEYS = {
    "icon": str,
    "label": str,
    "showLabel": bool,
    "tooltip": str,
    "layout": str,
    "trigger": str,
    "columns": int,
    "alertMode": str,
    "alertDuration": int,
}


def apply_scalars(drawer, payload):
    for key, cast in SCALAR_KEYS.items():
        if key not in payload:
            continue
        try:
            drawer[key] = cast(payload[key])
        except (TypeError, ValueError):
            return f"invalid value for {key!r}: {payload[key]!r}"
    return None


def apply_widgets(config, drawer, wanted_ids):
    """Move widgets in and out of this drawer, preserving inline settings."""
    previous = {}
    origins = dict(drawer.get("origins") or {})
    for widget in drawer.get("widgets") or []:
        wid = entry_id(widget)
        if wid:
            previous[wid] = as_entry(widget)

    # Widgets held by a DIFFERENT drawer are off limits: adopting one here
    # would mount the same widget twice and orphan the other drawer's copy.
    held_elsewhere = tucked_ids(config) - set(previous)

    wanted = []
    for wid in wanted_ids:
        wid = str(wid).strip()
        if not wid or wid == SELF_ID or wid in wanted or wid in held_elsewhere:
            continue
        wanted.append(wid)

    # Anything added in this edit is lifted off the bar with its settings.
    added = [wid for wid in wanted if wid not in previous]
    harvested = take_from_bar(config, added)
    for wid, (entry, section, index, after) in harvested.items():
        origins[wid] = {"section": section, "index": index, "after": after}

    entries = []
    for wid in wanted:
        # Precedence: what the bar knew (base) < what the drawer already held.
        merged = {}
        if wid in harvested:
            merged.update(harvested[wid][0])
        if wid in previous:
            merged.update(previous[wid])
        merged["id"] = wid
        entries.append(merged)

    # Anything dropped in this edit goes back to the bar where it came from,
    # carrying whatever it saved while it was tucked.
    restores = []
    dropped = []
    for wid, entry in previous.items():
        if wid in wanted:
            continue
        merged = dict(entry)
        merged.update(plugin_entry_settings(config, wid))
        merged["id"] = wid
        restores.append((merged, origins.pop(wid, None)))
        dropped.append(wid)
    if restores:
        restore_to_bar(config, restores)
    # Ownership is tracked by what the drawer held, not by a marker on the
    # plugins[] entry — the shell rewrites those entries wholesale and strips
    # any marker the moment a tucked widget saves its own settings.
    drop_plugin_entries(config, dropped)

    drawer["widgets"] = entries
    if origins:
        drawer["origins"] = {k: v for k, v in origins.items() if k in wanted}
    else:
        drawer.pop("origins", None)
    if not drawer.get("origins"):
        drawer.pop("origins", None)


def cmd_list_plugins(_args):
    print(json.dumps({"ok": True, "plugins": discover_plugins(load_shell_config())}))
    return 0


def describe_drawer(section, entry):
    data = as_entry(entry)
    return {
        "drawerId": str(data.get("drawerId", "")),
        "label": str(data.get("label", "")),
        "icon": str(data.get("icon", DEFAULT_ICON)),
        "layout": str(data.get("layout", "row")),
        "section": section,
        "widgets": [{"id": entry_id(w)} for w in (data.get("widgets") or []) if entry_id(w)],
    }


def stamp_drawer_ids(config):
    """Give every drawer an id, normalizing bare-string entries on the way.

    create-drawer and apply-auto mint ids, but a drawer written by hand — or
    one from before drawerId existed — has none, and the manager addresses
    drawers by id alone. Returns True when the config needs saving.
    """
    layout = layout_of(config)
    stamped = False
    for section, index, entry in list(iter_drawers(config)):
        if not isinstance(entry, dict):
            entry = as_entry(entry)
            layout[section][index] = entry
            stamped = True
        if not entry.get("drawerId"):
            entry["drawerId"] = uuid.uuid4().hex[:12]
            stamped = True
    return stamped


def cmd_get_state(_args):
    """Everything the global manager needs, in one call."""
    config = load_shell_config()
    if stamp_drawer_ids(config):
        save_shell_config(config)

    drawers = [describe_drawer(section, entry) for section, _index, entry in iter_drawers(config)]
    print(json.dumps({
        "ok": True,
        "plugins": discover_plugins(config),
        "drawers": drawers,
        "tucked": sorted(tucked_ids(config)),
    }))
    return 0


def cmd_save_drawer(args):
    try:
        payload = json.loads(args.payload)
    except ValueError as exc:
        print(json.dumps({"ok": False, "error": f"invalid payload: {exc}"}))
        return 2
    if not isinstance(payload, dict):
        print(json.dumps({"ok": False, "error": "payload must be an object"}))
        return 2

    config = load_shell_config()
    section, index, drawer, error = find_drawer(config, str(payload.get("drawerId", "")))
    if error:
        print(json.dumps({"ok": False, "error": error}))
        return 1

    error = apply_scalars(drawer, payload)
    if error:
        print(json.dumps({"ok": False, "error": error}))
        return 2

    if "widgets" in payload:
        widgets = payload["widgets"]
        if not isinstance(widgets, list):
            print(json.dumps({"ok": False, "error": "widgets must be a list"}))
            return 2
        apply_widgets(config, drawer, [entry_id(w) for w in widgets])

    # Stamp a stable identity so the next edit needs no guessing.
    if not drawer.get("drawerId"):
        drawer["drawerId"] = uuid.uuid4().hex[:12]

    reconcile_center_anchor(config)
    sync_plugins_array(config)
    save_shell_config(config)

    print(json.dumps({"ok": True, "drawer": drawer}))
    return 0


# ------------------------------------------------------- auto-arrange

# A drawer needs a glyph the moment it is created, and the manifest schema has
# no icon field to read one from, so each category carries a sensible default.
CATEGORY_ICONS = {
    "ai":           "\U000F06A9",  # robot
    "audio":        "\U000F057E",  # volume-high
    "compositor":   "\U000F0BAF",  # circle-multiple
    "development":  "\U000F0169",  # code-tags
    "files":        "\U000F024B",  # folder
    "fun":          "\U000F02B4",  # gamepad-variant
    "hardware":     "\U000F08BB",  # chip
    "info":         "\U000F02FC",  # information
    "layout":       "\U000F0570",  # view-grid
    "media":        "\U000F0388",  # music-note
    "network":      "\U000F0928",  # wifi
    "productivity": "\U000F0219",  # clipboard-text
    "smart home":   "\U000F02DC",  # home
    "status":       "\U000F02FC",  # information
    "system":       "\U000F0493",  # cog
    "utility":      "\U000F024B",  # folder
}
DEFAULT_ICON = "\U000F024B"


def category_icon(category):
    return CATEGORY_ICONS.get(str(category or "").strip().lower(), DEFAULT_ICON)


def bar_widgets(config, sections):
    """Every widget currently loose on the bar, in layout order."""
    layout = layout_of(config)
    found = []
    for section in sections:
        for index, entry in enumerate(layout.get(section, [])):
            wid = entry_id(entry)
            if not wid or wid == SELF_ID:
                continue
            found.append({"id": wid, "section": section, "index": index})
    return found


def analyze(config, prefs):
    """Group the loose bar widgets into proposed drawers by category.

    Widgets already tucked into a drawer are never touched — an adopted
    proposal only ever adds drawers alongside what the user already curated.
    """
    raw_sections = prefs.get("sections")
    if raw_sections is None:
        raw_sections = list(SECTIONS)
    sections = [s for s in raw_sections if s in SECTIONS]
    deselected = [s for s in SECTIONS if s not in sections]
    min_group = max(2, int(prefs.get("minGroupSize") or 2))
    max_drawers = max(1, int(prefs.get("maxDrawers") or 4))
    pinned = {str(x) for x in (prefs.get("pinned") or [])}

    # Tucking the widget named by bar.centerAnchor would silently un-anchor the
    # bar's center section, so it is never a candidate.
    anchor = str((config.get("bar") or {}).get("centerAnchor") or "").strip()
    if anchor:
        pinned.add(anchor)

    catalogue_list = discover_plugins(config)
    catalogue = {p["id"]: p for p in catalogue_list}
    already_tucked = tucked_ids(config)

    groups = {}
    skipped = []
    seen_ids = set()

    # Sections the user switched off still belong in the rundown — the wizard
    # renders `skipped` as "staying on the bar", and silence there would read
    # as "nothing to say about these".
    for widget in bar_widgets(config, deselected):
        skipped.append({"id": widget["id"], "reason": f"{widget['section']} section not selected"})
        seen_ids.add(widget["id"])

    for widget in bar_widgets(config, sections):
        wid = widget["id"]
        meta = catalogue.get(wid)
        if wid in seen_ids:
            # The same id twice on the bar must not count twice toward a
            # group's minimum size.
            continue
        seen_ids.add(wid)
        if wid in pinned:
            skipped.append({"id": wid, "reason": "pinned"})
            continue
        if wid in already_tucked:
            skipped.append({"id": wid, "reason": "already in a drawer"})
            continue
        if not meta:
            # No manifest we can read: a custom command/qml module, or a widget
            # whose plugin is disabled. Moving it would risk losing it.
            skipped.append({"id": wid, "reason": "no readable plugin manifest"})
            continue
        category = meta.get("category") or "Utility"
        group = groups.setdefault(category, {"category": category, "widgets": []})
        group["widgets"].append({
            "id": wid,
            "name": meta.get("name") or wid,
            "section": widget["section"],
            "index": widget["index"],
        })

    proposal = []
    for group in groups.values():
        count = len(group["widgets"])
        if count < min_group:
            reason = f"only {count} widget{'' if count == 1 else 's'} in {group['category']}"
            for widget in group["widgets"]:
                skipped.append({"id": widget["id"], "reason": reason})
            continue
        first = group["widgets"][0]
        proposal.append({
            "key": group["category"].lower().replace(" ", "-"),
            "label": group["category"],
            "icon": category_icon(group["category"]),
            "section": first["section"],
            "index": first["index"],
            "widgets": [{"id": w["id"], "name": w["name"]} for w in group["widgets"]],
        })

    # Biggest groups win the drawer budget; the rest stay on the bar.
    proposal.sort(key=lambda g: (-len(g["widgets"]), g["label"].lower()))
    for group in proposal[max_drawers:]:
        for widget in group["widgets"]:
            skipped.append({"id": widget["id"], "reason": f"beyond the {max_drawers}-drawer limit"})
    proposal = proposal[:max_drawers]
    proposal.sort(key=lambda g: (SECTIONS.index(g["section"]), g["index"]))

    return {
        "proposal": proposal,
        "skipped": skipped,
        "onBar": bar_widgets(config, list(SECTIONS)),
        "plugins": catalogue_list,
    }


def cmd_analyze(args):
    prefs = {}
    if args.prefs:
        try:
            prefs = json.loads(args.prefs)
        except ValueError as exc:
            print(json.dumps({"ok": False, "error": f"invalid --prefs: {exc}"}))
            return 2
    if not isinstance(prefs, dict):
        print(json.dumps({"ok": False, "error": "--prefs must be an object"}))
        return 2

    result = analyze(load_shell_config(), prefs)
    result["ok"] = True
    print(json.dumps(result))
    return 0


def cmd_apply_auto(args):
    """Create one drawer per accepted group and move its widgets in.

    Existing drawers are never read or rewritten here; each new drawer is
    inserted where the first widget it absorbs used to sit, so the bar keeps
    roughly the shape the user is used to.
    """
    try:
        payload = json.loads(args.payload)
    except ValueError as exc:
        print(json.dumps({"ok": False, "error": f"invalid payload: {exc}"}))
        return 2
    groups = payload.get("drawers") if isinstance(payload, dict) else None
    if not isinstance(groups, list):
        print(json.dumps({"ok": False, "error": "payload.drawers must be a list"}))
        return 2

    config = load_shell_config()
    layout = layout_of(config)
    already_held = tucked_ids(config)
    created = []

    for group in groups:
        if not isinstance(group, dict):
            continue
        widget_ids = []
        for widget in group.get("widgets") or []:
            wid = entry_id(widget)
            if not wid or wid == SELF_ID or wid in widget_ids:
                continue
            if wid in already_held:
                continue  # another drawer owns it; mounting it twice is a bug
            widget_ids.append(wid)
        if not widget_ids:
            continue

        section = group.get("section") if group.get("section") in SECTIONS else "center"
        # Where the drawer lands: where its first member sits right now.
        insert_at = len(layout[section])
        for index, entry in enumerate(layout[section]):
            if entry_id(entry) in widget_ids:
                insert_at = index
                break

        harvested = take_from_bar(config, widget_ids)
        if not harvested:
            continue

        entries = []
        origins = {}
        for wid in widget_ids:
            if wid not in harvested:
                continue
            entry, origin_section, origin_index, origin_after = harvested[wid]
            entries.append(entry)
            origins[wid] = {"section": origin_section, "index": origin_index,
                            "after": origin_after}

        drawer = {
            "id": SELF_ID,
            "drawerId": uuid.uuid4().hex[:12],
            "icon": str(group.get("icon") or DEFAULT_ICON),
            "label": str(group.get("label") or ""),
            "showLabel": bool(group.get("showLabel", True)) and bool(group.get("label")),
            "layout": str(group.get("layout") or "row"),
            "widgets": entries,
            "origins": origins,
        }

        insert_at = min(insert_at, len(layout[section]))
        layout[section].insert(insert_at, drawer)
        already_held.update(origins.keys())
        created.append({"label": drawer["label"], "section": section,
                        "index": insert_at, "widgets": list(origins.keys())})

    if not created:
        print(json.dumps({"ok": False, "error": "nothing to adopt"}))
        return 1

    reconcile_center_anchor(config)
    sync_plugins_array(config)
    save_shell_config(config)
    print(json.dumps({"ok": True, "created": created}))
    return 0


def cmd_apply_drawers(args):
    """Reconcile every drawer against the desired set, in one write.

    Entries carrying a drawerId are updated in place; entries without one are
    created; drawers absent from the payload are removed. Widgets are pooled
    first and dealt out afterwards, so moving one between drawers is
    order-independent and keeps the origin recorded when it was first tucked —
    releasing it to the bar and re-harvesting it would overwrite that.
    """
    try:
        payload = json.loads(args.payload)
    except ValueError as exc:
        print(json.dumps({"ok": False, "error": f"invalid payload: {exc}"}))
        return 2
    wanted = payload.get("drawers") if isinstance(payload, dict) else None
    if not isinstance(wanted, list):
        print(json.dumps({"ok": False, "error": "payload.drawers must be a list"}))
        return 2

    config = load_shell_config()
    stamp_drawer_ids(config)
    layout = layout_of(config)

    # Lift every tucked widget out of every drawer, keeping its entry and the
    # origin it was first tucked from.
    pool = {}
    for _section, _index, entry in iter_drawers(config):
        data = as_entry(entry)
        origins = data.get("origins") or {}
        for widget in data.get("widgets") or []:
            wid = entry_id(widget)
            if not wid or wid in pool:
                continue
            merged = as_entry(widget)
            merged.update(plugin_entry_settings(config, wid))
            merged["id"] = wid
            pool[wid] = (merged, origins.get(wid))
        data["widgets"] = []
        data.pop("origins", None)
        if isinstance(entry, dict):
            entry.clear()
            entry.update(data)

    keep = {str(d.get("drawerId", "")) for d in wanted if isinstance(d, dict) and d.get("drawerId")}
    for section, index, entry in sorted(iter_drawers(config), key=lambda d: -d[1]):
        if str(as_entry(entry).get("drawerId", "")) not in keep:
            layout[section] = [e for i, e in enumerate(layout[section]) if i != index]

    existing = {str(as_entry(e).get("drawerId", "")): e for _s, _i, e in iter_drawers(config)}
    applied = []
    claimed = set()

    for desired in wanted:
        if not isinstance(desired, dict):
            continue
        drawer = existing.get(str(desired.get("drawerId", "")))
        if drawer is None:
            section = desired.get("section") if desired.get("section") in SECTIONS else "center"
            drawer = {"id": SELF_ID, "drawerId": uuid.uuid4().hex[:12], "widgets": []}
            layout[section].append(drawer)

        error = apply_scalars(drawer, desired)
        if error:
            print(json.dumps({"ok": False, "error": error}))
            return 2
        drawer["showLabel"] = bool(drawer.get("label"))

        ids = []
        for widget in desired.get("widgets") or []:
            wid = entry_id(widget)
            if wid and wid != SELF_ID and wid not in ids and wid not in claimed:
                ids.append(wid)
                claimed.add(wid)

        entries = []
        origins = {}
        fresh = take_from_bar(config, [wid for wid in ids if wid not in pool])
        for wid in ids:
            if wid in pool:
                entry, origin = pool.pop(wid)
                entries.append(entry)
                if origin:
                    origins[wid] = origin
            elif wid in fresh:
                widget_entry, origin_section, origin_index, origin_after = fresh[wid]
                entries.append(widget_entry)
                origins[wid] = {"section": origin_section, "index": origin_index,
                                "after": origin_after}
        drawer["widgets"] = entries
        if origins:
            drawer["origins"] = origins
        else:
            drawer.pop("origins", None)
        applied.append(drawer["drawerId"])

    # Whatever nobody claimed goes back to the bar.
    if pool:
        restore_to_bar(config, list(pool.values()))
        drop_plugin_entries(config, list(pool))

    reconcile_center_anchor(config)
    sync_plugins_array(config)
    save_shell_config(config)
    print(json.dumps({"ok": True, "drawers": applied}))
    return 0


# ------------------------------------------------------------- menu wiring

MENU_PATH = os.path.join(HOME, ".config/omarchy/extensions/omarchy-menu.jsonc")
MENU_BEGIN = "  // BEGIN OMARCHY DRAWERS (managed by drawer-config.py)"
MENU_END = "  // END OMARCHY DRAWERS"

MENU_BLOCK = """{begin}
  "setup.drawers": {{"icon":"\U000F024B","label":"Drawers","aliases":["drawer","drawers"]}},
  "setup.drawers.manage": {{"icon":"\U000F0493","label":"Manage Drawers","action":"omarchy-shell {sid} manage"}},
  "setup.drawers.auto": {{"icon":"\U000F0570","label":"Auto-arrange","action":"omarchy-shell {sid} autoArrange"}},
{end}""".format(begin=MENU_BEGIN, end=MENU_END, sid=SELF_ID)


def _strip_menu_block(text):
    """Remove a previously installed block, leaving everything else alone."""
    if MENU_BEGIN not in text:
        return text, False
    head, _, rest = text.partition(MENU_BEGIN)
    _, _, tail = rest.partition(MENU_END)
    return head.rstrip() + "\n" + tail.lstrip("\n"), True


def _write_menu(text):
    os.makedirs(os.path.dirname(MENU_PATH), exist_ok=True)
    write_atomic(MENU_PATH, lambda handle: handle.write(text))


def cmd_install_menu(_args):
    """Add the Drawers entries to the user's Omarchy menu extension.

    The file is JSONC the user also edits by hand, so the block is delimited
    and only ever replaced whole — the same convention omarchy-sensei uses.
    The block goes straight after the opening brace: appending it at the end
    would mean punctuating whatever line happens to be last, which may be
    another tool's END marker comment.
    """
    text = ""
    if os.path.exists(MENU_PATH):
        with open(MENU_PATH, "r", encoding="utf-8") as handle:
            text = handle.read()
    if not text.strip():
        text = "{\n}\n"

    text, _ = _strip_menu_block(text)

    open_at = text.find("{")
    if open_at == -1:
        print(json.dumps({"ok": False, "error": f"{MENU_PATH} has no opening brace"}))
        return 1

    merged = text[:open_at + 1] + "\n" + MENU_BLOCK + "\n" + text[open_at + 1:].lstrip("\n")
    _write_menu(merged)
    print(json.dumps({"ok": True, "path": MENU_PATH,
                      "entries": ["setup.drawers", "setup.drawers.manage", "setup.drawers.auto"]}))
    return 0


def cmd_uninstall_menu(_args):
    if not os.path.exists(MENU_PATH):
        print(json.dumps({"ok": True, "removed": False}))
        return 0
    with open(MENU_PATH, "r", encoding="utf-8") as handle:
        text = handle.read()
    stripped, found = _strip_menu_block(text)
    if found:
        _write_menu(stripped)
    print(json.dumps({"ok": True, "removed": found, "path": MENU_PATH}))
    return 0


def cmd_sync(_args):
    config = load_shell_config()
    sync_plugins_array(config)
    save_shell_config(config)
    print(json.dumps({"ok": True, "plugins": config.get("plugins", [])}))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description="Omarchy Drawers config helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("list-plugins").set_defaults(func=cmd_list_plugins)

    subparsers.add_parser("get-state").set_defaults(func=cmd_get_state)

    save = subparsers.add_parser("save-drawer")
    save.add_argument("--payload", required=True)
    save.set_defaults(func=cmd_save_drawer)

    subparsers.add_parser("sync").set_defaults(func=cmd_sync)

    analyze_cmd = subparsers.add_parser("analyze")
    analyze_cmd.add_argument("--prefs", default="")
    analyze_cmd.set_defaults(func=cmd_analyze)

    adopt = subparsers.add_parser("apply-auto")
    adopt.add_argument("--payload", required=True)
    adopt.set_defaults(func=cmd_apply_auto)

    apply_cmd = subparsers.add_parser("apply-drawers")
    apply_cmd.add_argument("--payload", required=True)
    apply_cmd.set_defaults(func=cmd_apply_drawers)

    subparsers.add_parser("install-menu").set_defaults(func=cmd_install_menu)
    subparsers.add_parser("uninstall-menu").set_defaults(func=cmd_uninstall_menu)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as exc:  # surface a JSON error rather than a traceback
        print(json.dumps({"ok": False, "error": f"{type(exc).__name__}: {exc}"}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
