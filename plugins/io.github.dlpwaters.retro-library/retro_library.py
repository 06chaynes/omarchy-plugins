#!/usr/bin/env python3
"""Portable RetroArch playlist bridge for the Retro Library Omarchy plugin."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


HOME = Path.home()
PLUGIN_ID = "io.github.dlpwaters.retro-library"
FLATPAK_ID = "org.libretro.RetroArch"
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", HOME / ".local" / "state")) / "retro-library"
STATE_FILE = STATE_DIR / "state.json"


SYSTEMS = {
    "Arcade - FBNeo": {
        "name": "Arcade · FinalBurn Neo", "short": "Arcade · FBNeo", "maker": "Arcade",
        "icon": "FBNeo - Arcade Games", "cores": ["fbneo"],
    },
    "Arcade - MAME": {
        "name": "Arcade · MAME", "short": "Arcade · MAME", "maker": "Arcade",
        "icon": "MAME", "cores": ["mame", "mame2016"],
    },
    "NEC - PC Engine - TurboGrafx 16": {
        "name": "NEC PC Engine / TurboGrafx-16", "short": "TurboGrafx-16", "maker": "NEC",
        "icon": "NEC - PC Engine - TurboGrafx 16", "cores": ["mednafen_pce_fast", "mednafen_pce"],
    },
    "Nintendo - Game Boy": {
        "name": "Nintendo Game Boy", "short": "Game Boy", "maker": "Nintendo",
        "icon": "Nintendo - Game Boy", "cores": ["gambatte", "sameboy", "mgba"],
    },
    "Nintendo - Game Boy Color": {
        "name": "Nintendo Game Boy Color", "short": "Game Boy Color", "maker": "Nintendo",
        "icon": "Nintendo - Game Boy Color", "cores": ["gambatte", "sameboy", "mgba"],
    },
    "Nintendo - Game Boy Advance": {
        "name": "Nintendo Game Boy Advance", "short": "Game Boy Advance", "maker": "Nintendo",
        "icon": "Nintendo - Game Boy Advance", "cores": ["mgba"],
    },
    "Nintendo - GameCube": {
        "name": "Nintendo GameCube", "short": "GameCube", "maker": "Nintendo",
        "icon": "Nintendo - GameCube", "cores": ["dolphin"],
    },
    "Nintendo - NES": {
        "name": "Nintendo Entertainment System", "short": "NES", "maker": "Nintendo",
        "icon": "Nintendo - Nintendo Entertainment System", "cores": ["mesen", "nestopia"],
    },
    "Nintendo - Nintendo 64": {
        "name": "Nintendo 64", "short": "Nintendo 64", "maker": "Nintendo",
        "icon": "Nintendo - Nintendo 64", "cores": ["mupen64plus_next", "parallel_n64"],
    },
    "Nintendo - Nintendo DS": {
        "name": "Nintendo DS", "short": "Nintendo DS", "maker": "Nintendo",
        "icon": "Nintendo - Nintendo DS", "cores": ["melonds", "desmume"],
    },
    "Nintendo - SNES": {
        "name": "Super Nintendo Entertainment System", "short": "SNES", "maker": "Nintendo",
        "icon": "Nintendo - Super Nintendo Entertainment System",
        "cores": ["snes9x", "bsnes", "mesen-s", "bsnes_hd_beta", "bsnes2014_accuracy", "bsnes2014_balanced", "bsnes2014_performance"],
    },
    "Nintendo - Wii": {
        "name": "Nintendo Wii", "short": "Wii", "maker": "Nintendo",
        "icon": "Nintendo - Wii", "cores": ["dolphin"],
    },
    "Sega - Dreamcast": {
        "name": "Sega Dreamcast", "short": "Dreamcast", "maker": "Sega",
        "icon": "Sega - Dreamcast", "cores": ["flycast"],
    },
    "Sega - Game Gear": {
        "name": "Sega Game Gear", "short": "Game Gear", "maker": "Sega",
        "icon": "Sega - Game Gear", "cores": ["genesis_plus_gx", "picodrive"],
    },
    "Sega - Genesis - Mega Drive": {
        "name": "Sega Genesis / Mega Drive", "short": "Genesis / Mega Drive", "maker": "Sega",
        "icon": "Sega - Mega Drive - Genesis", "cores": ["genesis_plus_gx", "blastem", "picodrive"],
    },
    "Sony - PlayStation": {
        "name": "Sony PlayStation", "short": "PlayStation", "maker": "Sony",
        "icon": "Sony - PlayStation", "cores": ["mednafen_psx_hw", "mednafen_psx"],
    },
    "Sony - PlayStation 2": {
        "name": "Sony PlayStation 2", "short": "PlayStation 2", "maker": "Sony",
        "icon": "Sony - PlayStation 2", "cores": ["pcsx2_launcher", "play"],
    },
    "Sony - PlayStation Portable": {
        "name": "Sony PlayStation Portable", "short": "PSP", "maker": "Sony",
        "icon": "Sony - PlayStation Portable", "cores": ["ppsspp"],
    },
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_json(path: Path, fallback):
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError):
        return fallback


def default_state() -> dict:
    return {"version": 1, "favorites": [], "core_overrides": {}, "history": [], "settings": {}}


def load_state() -> dict:
    state = load_json(STATE_FILE, default_state())
    if not isinstance(state, dict):
        state = default_state()
    state.setdefault("favorites", [])
    state.setdefault("core_overrides", {})
    state.setdefault("history", [])
    state.setdefault("settings", {})
    return state


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="state.", suffix=".json", dir=STATE_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(state, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(temporary, STATE_FILE)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def unique_paths(paths) -> list[Path]:
    result = []
    seen = set()
    for value in paths:
        if not value:
            continue
        path = Path(value).expanduser()
        key = str(path)
        if key not in seen:
            seen.add(key)
            result.append(path)
    return result


def parse_retroarch_config(config_file: Path) -> dict[str, str]:
    try:
        text = config_file.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return {}
    result = {}
    for line in text.splitlines():
        match = re.match(r'^\s*([A-Za-z0-9_]+)\s*=\s*"(.*)"\s*$', line)
        if match:
            result[match.group(1)] = match.group(2).replace('\\"', '"')
    return result


def resolve_directory(raw: str, config_dir: Path, fallback: Path) -> Path:
    if not raw or raw == "default":
        return fallback
    expanded = Path(os.path.expandvars(os.path.expanduser(raw)))
    return expanded if expanded.is_absolute() else config_dir / expanded


def env_path_list(name: str) -> list[Path]:
    return [Path(value).expanduser() for value in os.environ.get(name, "").split(os.pathsep) if value]


def flatpak_roots() -> list[Path]:
    return unique_paths([
        HOME / ".local/share/flatpak/app" / FLATPAK_ID / "current/active/files",
        Path("/var/lib/flatpak/app") / FLATPAK_ID / "current/active/files",
    ])


def choose_config_dir(state: dict) -> tuple[Path, str]:
    settings = state.get("settings", {})
    explicit = os.environ.get("RETRO_LIBRARY_CONFIG_DIR") or settings.get("config_dir", "")
    if explicit:
        path = Path(os.path.expandvars(os.path.expanduser(str(explicit))))
        if not path.is_dir():
            raise RuntimeError(f"Configured RetroArch directory does not exist: {path}")
        return path, "Custom"

    xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
    candidates = [
        (xdg_config / "retroarch", "Native"),
        (HOME / ".var/app" / FLATPAK_ID / "config/retroarch", "Flatpak"),
        (HOME / "snap/retroarch/current/.config/retroarch", "Snap"),
    ]
    ranked = []
    for config_dir, kind in candidates:
        config = parse_retroarch_config(config_dir / "retroarch.cfg")
        playlist_dir = resolve_directory(config.get("playlist_directory", ""), config_dir, config_dir / "playlists")
        count = sum(1 for _ in playlist_dir.glob("*.lpl")) if playlist_dir.is_dir() else 0
        if count or (config_dir / "retroarch.cfg").is_file():
            ranked.append((count, config_dir, kind))
    if ranked:
        _count, config_dir, kind = max(ranked, key=lambda item: item[0])
        return config_dir, kind
    raise RuntimeError(
        "No RetroArch configuration was found. Install or run RetroArch once, or configure this plugin with "
        "retro-library configure --config-dir /path/to/retroarch."
    )


def launch_command(state: dict, config_kind: str, config_dir: Path) -> tuple[list[str], str]:
    settings = state.get("settings", {})
    raw = os.environ.get("RETRO_LIBRARY_COMMAND") or settings.get("retroarch_command", "")
    if isinstance(raw, list):
        command = [str(value) for value in raw if str(value)]
    elif raw:
        command = shlex.split(str(raw))
    else:
        command = []
    if command:
        if not shutil.which(command[0]) and not Path(command[0]).is_file():
            raise RuntimeError(f"Configured RetroArch command is unavailable: {command[0]}")
        return command, "Custom"

    flatpak = shutil.which("flatpak")
    native = shutil.which("retroarch")
    is_flatpak_config = config_kind == "Flatpak" or f"/.var/app/{FLATPAK_ID}/" in str(config_dir)
    if is_flatpak_config and flatpak:
        return [flatpak, "run", FLATPAK_ID], "Flatpak"
    if native:
        return [native], config_kind if config_kind != "Custom" else "Native"
    if flatpak and (HOME / ".var/app" / FLATPAK_ID).is_dir():
        return [flatpak, "run", FLATPAK_ID], "Flatpak"
    raise RuntimeError("RetroArch is not installed or its launch command could not be found.")


def detect_runtime() -> dict:
    state = load_state()
    config_dir, config_kind = choose_config_dir(state)
    config_file = config_dir / "retroarch.cfg"
    config = parse_retroarch_config(config_file)
    command, source_kind = launch_command(state, config_kind, config_dir)
    playlist_dir = resolve_directory(config.get("playlist_directory", ""), config_dir, config_dir / "playlists")
    thumbnail_dir = resolve_directory(config.get("thumbnails_directory", ""), config_dir, config_dir / "thumbnails")
    save_dir = resolve_directory(config.get("savefile_directory", ""), config_dir, config_dir / "saves")
    state_dir = resolve_directory(config.get("savestate_directory", ""), config_dir, config_dir / "states")

    configured_core = resolve_directory(config.get("libretro_directory", ""), config_dir, config_dir / "cores")
    core_dirs = unique_paths(env_path_list("RETRO_LIBRARY_CORE_DIRS") + [
        configured_core, config_dir / "cores", Path("/usr/lib/libretro"), Path("/usr/lib64/libretro"),
        Path("/usr/local/lib/libretro"),
    ])
    configured_info = resolve_directory(config.get("libretro_info_path", ""), config_dir, config_dir / "info")
    info_dirs = unique_paths(env_path_list("RETRO_LIBRARY_INFO_DIRS") + [
        configured_info, config_dir / "info", Path("/usr/share/libretro/info"), Path("/usr/share/retroarch/info"),
    ] + [root / "share/libretro/info" for root in flatpak_roots()])
    configured_assets = resolve_directory(config.get("assets_directory", ""), config_dir, config_dir / "assets")
    asset_dirs = unique_paths(env_path_list("RETRO_LIBRARY_ASSET_DIRS") + [
        configured_assets, config_dir / "assets", Path("/usr/share/libretro/assets"), Path("/usr/share/retroarch/assets"),
    ] + [root / "share/libretro/assets" for root in flatpak_roots()])

    return {
        "config_dir": config_dir,
        "config_file": config_file,
        "config": config,
        "source_kind": source_kind,
        "command": command,
        "playlist_dir": playlist_dir,
        "thumbnail_dir": thumbnail_dir,
        "save_dir": save_dir,
        "state_dir": state_dir,
        "core_dirs": core_dirs,
        "info_dirs": info_dirs,
        "asset_dirs": asset_dirs,
        "organizer": shutil.which("organizeroms") or "",
    }


def core_id_from_path(path: str) -> str:
    name = Path(path).name
    return name[:-12] if name.endswith("_libretro.so") else Path(path).stem


def core_display_name(core_id: str, runtime: dict, fallback: str = "") -> str:
    for directory in runtime["info_dirs"]:
        info = directory / f"{core_id}_libretro.info"
        try:
            text = info.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        match = re.search(r'^display_name\s*=\s*"([^"]+)"', text, re.MULTILINE)
        if match:
            return match.group(1)
    return fallback or core_id.replace("_", " ").title()


def find_core(core_id: str, runtime: dict) -> str:
    filename = f"{core_id}_libretro.so"
    for directory in runtime["core_dirs"]:
        candidate = directory / filename
        if candidate.is_file():
            return str(candidate)
    return ""


def core_available(path: str, runtime: dict) -> bool:
    if not path or path == "DETECT":
        return False
    expanded = os.path.expandvars(os.path.expanduser(path))
    if Path(expanded).is_file():
        return True
    return runtime["source_kind"] == "Flatpak" and expanded.startswith("/app/")


def ozone_icon(name: str, runtime: dict) -> str:
    for assets in runtime["asset_dirs"]:
        for relative in (Path("ozone/png/icons"), Path("assets/ozone/png/icons")):
            icon = assets / relative / f"{name}.png"
            if icon.is_file():
                return str(icon)
    return ""


def thumbnail_name(label: str) -> str:
    return re.sub(r'[&*/:`<>?\\|]', "_", label)


def find_thumbnail(db_name: str, label: str, runtime: dict) -> str:
    database = db_name[:-4] if db_name.endswith(".lpl") else db_name
    folder = runtime["thumbnail_dir"] / database / "Named_Boxarts"
    for title in (label, thumbnail_name(label)):
        for suffix in (".png", ".jpg", ".jpeg", ".webp"):
            candidate = folder / f"{title}{suffix}"
            if candidate.is_file():
                return str(candidate)
    return ""


def content_file(path: str) -> Path:
    return Path(os.path.expandvars(os.path.expanduser(path.split("#", 1)[0])))


def candidate_cores(system_id: str, playlist: dict, runtime: dict) -> list[dict]:
    definition = SYSTEMS.get(system_id, {})
    ordered = list(definition.get("cores", []))
    default_path = str(playlist.get("default_core_path", ""))
    default_name = str(playlist.get("default_core_name", ""))
    default_id = core_id_from_path(default_path) if default_path and default_path != "DETECT" else ""
    if default_id and default_id not in ordered:
        ordered.insert(0, default_id)

    options = []
    for core_id in ordered:
        path = find_core(core_id, runtime)
        if path:
            options.append({
                "id": core_id,
                "path": path,
                "name": core_display_name(core_id, runtime, default_name if core_id == default_id else ""),
                "default": path == default_path,
            })
    if default_path and default_path != "DETECT" and core_available(default_path, runtime) \
            and not any(option["path"] == default_path for option in options):
        options.insert(0, {
            "id": default_id,
            "path": default_path,
            "name": default_name or core_display_name(default_id, runtime),
            "default": True,
        })
    return options


def history_index(state: dict) -> dict:
    return {str(item.get("path", "")): item for item in state.get("history", []) if item.get("path")}


def read_library() -> dict:
    runtime = detect_runtime()
    state = load_state()
    favorites = set(map(str, state.get("favorites", [])))
    overrides = state.get("core_overrides", {})
    recent = history_index(state)
    systems = []
    games = []

    if not runtime["playlist_dir"].is_dir():
        raise RuntimeError(f"RetroArch playlist directory is missing: {runtime['playlist_dir']}")

    playlist_paths = sorted(runtime["playlist_dir"].glob("*.lpl"), key=lambda path: path.stem.casefold())
    for playlist_path in playlist_paths:
        playlist = load_json(playlist_path, {})
        items = playlist.get("items", []) if isinstance(playlist, dict) else []
        if not isinstance(items, list) or not items:
            continue

        system_id = playlist_path.stem
        definition = SYSTEMS.get(system_id, {
            "name": system_id, "short": system_id.split(" - ")[-1], "maker": system_id.split(" - ")[0],
            "icon": system_id, "cores": [],
        })
        cores = candidate_cores(system_id, playlist, runtime)
        default_core_path = str(playlist.get("default_core_path", ""))
        default_core_name = str(playlist.get("default_core_name", ""))
        system = {
            "id": system_id,
            "name": definition["name"],
            "short_name": definition["short"],
            "manufacturer": definition["maker"],
            "icon": ozone_icon(definition["icon"], runtime),
            "count": len(items),
            "default_core_path": default_core_path,
            "default_core_name": default_core_name,
            "cores": cores,
        }
        systems.append(system)

        allowed_paths = {option["path"] for option in cores}
        if core_available(default_core_path, runtime):
            allowed_paths.add(default_core_path)

        for item in items:
            if not isinstance(item, dict):
                continue
            content_path = str(item.get("path", ""))
            label = str(item.get("label", content_file(content_path).stem))
            item_core_path = str(item.get("core_path", ""))
            if item_core_path in ("", "DETECT"):
                item_core_path = default_core_path
            item_core_name = str(item.get("core_name", ""))
            if item_core_name in ("", "DETECT"):
                item_core_name = default_core_name
            override = str(overrides.get(content_path, ""))
            if override not in allowed_paths or not core_available(override, runtime):
                override = ""
            recent_item = recent.get(content_path, {})
            game_id = hashlib.sha1(f"{system_id}\0{content_path}".encode("utf-8")).hexdigest()[:16]
            games.append({
                "id": game_id,
                "label": label,
                "path": content_path,
                "system_id": system_id,
                "system_name": definition["name"],
                "system_short_name": definition["short"],
                "system_icon": system["icon"],
                "thumbnail": find_thumbnail(str(item.get("db_name", system_id)), label, runtime),
                "core_path": item_core_path,
                "core_name": item_core_name,
                "override_core_path": override,
                "favorite": content_path in favorites,
                "last_played": str(recent_item.get("played_at", "")),
                "play_count": int(recent_item.get("play_count", 0) or 0),
                "content_available": content_file(content_path).exists(),
                "core_available": core_available(override or item_core_path, runtime),
            })

    systems.sort(key=lambda item: (item["short_name"].casefold(), item["name"].casefold()))
    games.sort(key=lambda item: (item["system_short_name"].casefold(), item["label"].casefold(), item["path"].casefold()))
    return {
        "ok": True,
        "generated_at": utc_now(),
        "retroarch": shlex.join(runtime["command"]),
        "source_kind": runtime["source_kind"],
        "config_dir": str(runtime["config_dir"]),
        "playlist_dir": str(runtime["playlist_dir"]),
        "organizer_available": bool(runtime["organizer"]),
        "systems": systems,
        "games": games,
        "total_games": len(games),
        "playable_games": sum(game["content_available"] and game["core_available"] for game in games),
        "favorite_games": sum(game["favorite"] for game in games),
        "recent_games": sum(bool(game["last_played"]) for game in games),
    }


def find_game(content_path: str) -> tuple[dict, dict]:
    library = read_library()
    for game in library["games"]:
        if game["path"] == content_path:
            system = next(system for system in library["systems"] if system["id"] == game["system_id"])
            return game, system
    raise RuntimeError("That game is not present in a RetroArch playlist.")


def validate_core(core_path: str, game: dict, system: dict, runtime: dict) -> str:
    if not core_path or core_path == "auto":
        core_path = game.get("override_core_path") or game.get("core_path") or system.get("default_core_path")
    allowed = {option["path"] for option in system.get("cores", [])}
    if game.get("core_path"):
        allowed.add(game["core_path"])
    if core_path not in allowed:
        raise RuntimeError("The selected core is not compatible with this playlist.")
    if not core_available(core_path, runtime):
        raise RuntimeError(f"The selected RetroArch core is not installed: {core_path}")
    return core_path


def command_list(_args) -> dict:
    return read_library()


def command_launch(args) -> dict:
    runtime = detect_runtime()
    game, system = find_game(args.path)
    core_path = validate_core(args.core, game, system, runtime)
    content = content_file(game["path"])
    if not content.exists():
        raise RuntimeError(f"Game content is missing: {content}")
    command = runtime["command"] + ["-L", core_path, game["path"]]
    if args.dry_run:
        return {"ok": True, "dry_run": True, "command": command, "game": game["label"], "core": core_path}

    process = detached(command)
    state = load_state()
    old = history_index(state).get(game["path"], {})
    history = [entry for entry in state.get("history", []) if entry.get("path") != game["path"]]
    history.insert(0, {
        "path": game["path"], "label": game["label"], "system_id": game["system_id"],
        "played_at": utc_now(), "play_count": int(old.get("play_count", 0) or 0) + 1,
    })
    state["history"] = history[:100]
    save_state(state)
    return {"ok": True, "pid": process.pid, "game": game["label"], "core": core_path}


def command_favorite(args) -> dict:
    game, _system = find_game(args.path)
    state = load_state()
    favorites = set(map(str, state.get("favorites", [])))
    if args.value == "true":
        favorites.add(game["path"])
    else:
        favorites.discard(game["path"])
    state["favorites"] = sorted(favorites)
    save_state(state)
    return {"ok": True, "favorite": game["path"] in favorites, "game": game["label"]}


def command_set_core(args) -> dict:
    runtime = detect_runtime()
    game, system = find_game(args.path)
    state = load_state()
    overrides = state.setdefault("core_overrides", {})
    if args.core in ("", "auto"):
        overrides.pop(game["path"], None)
        core_path = game["core_path"]
        automatic = True
    else:
        core_path = validate_core(args.core, game, system, runtime)
        overrides[game["path"]] = core_path
        automatic = False
    save_state(state)
    return {"ok": True, "game": game["label"], "core": core_path, "automatic": automatic}


def detached(command: list[str]) -> subprocess.Popen:
    return subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, start_new_session=True)


def command_open(_args) -> dict:
    runtime = detect_runtime()
    process = detached(runtime["command"])
    return {"ok": True, "pid": process.pid}


def command_open_folder(args) -> dict:
    runtime = detect_runtime()
    if args.kind == "roms":
        if not args.path:
            raise RuntimeError("A selected game is required to open its content folder.")
        path = content_file(args.path).parent
    elif args.kind == "saves":
        path = runtime["save_dir"]
    else:
        path = runtime["state_dir"]
    path.mkdir(parents=True, exist_ok=True)
    opener = shutil.which("xdg-open")
    if not opener:
        raise RuntimeError("xdg-open is required to open folders.")
    process = detached([opener, str(path)])
    return {"ok": True, "pid": process.pid, "path": str(path)}


def command_organize(_args) -> dict:
    runtime = detect_runtime()
    if not runtime["organizer"]:
        raise RuntimeError("No optional 'organizeroms' command was found in PATH.")
    process = detached([runtime["organizer"]])
    return {"ok": True, "pid": process.pid}


def command_configure(args) -> dict:
    state = load_state()
    settings = state.setdefault("settings", {})
    if args.clear:
        settings.clear()
    else:
        if args.config_dir is not None:
            settings["config_dir"] = str(Path(args.config_dir).expanduser()) if args.config_dir else ""
        if args.retroarch_command is not None:
            settings["retroarch_command"] = shlex.split(args.retroarch_command) if args.retroarch_command else []
    save_state(state)
    return {"ok": True, "settings": settings, "message": "Configuration saved. Refresh the plugin."}


def command_doctor(_args) -> dict:
    runtime = detect_runtime()
    library = read_library()
    return {
        "ok": True,
        "source_kind": runtime["source_kind"],
        "command": runtime["command"],
        "config_dir": str(runtime["config_dir"]),
        "playlist_dir": str(runtime["playlist_dir"]),
        "thumbnail_dir": str(runtime["thumbnail_dir"]),
        "save_dir": str(runtime["save_dir"]),
        "state_dir": str(runtime["state_dir"]),
        "core_dirs": [str(path) for path in runtime["core_dirs"]],
        "asset_dirs": [str(path) for path in runtime["asset_dirs"]],
        "systems": len(library["systems"]),
        "games": library["total_games"],
        "playable_games": library["playable_games"],
    }


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="RetroArch library bridge")
    commands = root.add_subparsers(dest="command", required=True)
    commands.add_parser("list")

    launch = commands.add_parser("launch")
    launch.add_argument("--path", required=True)
    launch.add_argument("--core", default="auto")
    launch.add_argument("--dry-run", action="store_true")

    favorite = commands.add_parser("favorite")
    favorite.add_argument("--path", required=True)
    favorite.add_argument("--value", choices=("true", "false"), required=True)

    set_core = commands.add_parser("set-core")
    set_core.add_argument("--path", required=True)
    set_core.add_argument("--core", default="auto")

    commands.add_parser("open")
    folder = commands.add_parser("open-folder")
    folder.add_argument("--kind", choices=("roms", "saves", "states"), required=True)
    folder.add_argument("--path", default="")
    commands.add_parser("organize")
    configure = commands.add_parser("configure")
    configure.add_argument("--config-dir")
    configure.add_argument("--retroarch-command")
    configure.add_argument("--clear", action="store_true")
    commands.add_parser("doctor")
    return root


COMMANDS = {
    "list": command_list,
    "launch": command_launch,
    "favorite": command_favorite,
    "set-core": command_set_core,
    "open": command_open,
    "open-folder": command_open_folder,
    "organize": command_organize,
    "configure": command_configure,
    "doctor": command_doctor,
}


def main() -> int:
    args = parser().parse_args()
    try:
        payload = COMMANDS[args.command](args)
        print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
        return 0
    except Exception as error:
        print(json.dumps({"ok": False, "error": str(error)}, ensure_ascii=False, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    sys.exit(main())
