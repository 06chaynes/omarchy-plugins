import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "retro-library"


class RetroLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.config = self.base / "config"
        self.playlists = self.config / "playlists"
        self.cores = self.base / "cores"
        self.info = self.base / "info"
        self.assets = self.base / "assets"
        self.thumbnails = self.base / "thumbnails"
        self.roms = self.base / "ROM Collection" / "NES"
        for path in (self.playlists, self.cores, self.info, self.assets, self.thumbnails, self.roms):
            path.mkdir(parents=True, exist_ok=True)

        self.rom = self.roms / "Demo Game.nes"
        self.rom.write_bytes(b"NES")
        self.archive = self.roms / "Archive Game.zip"
        self.archive.write_bytes(b"ZIP")
        self.mesen = self.cores / "mesen_libretro.so"
        self.nestopia = self.cores / "nestopia_libretro.so"
        self.mesen.write_bytes(b"core")
        self.nestopia.write_bytes(b"core")
        (self.info / "mesen_libretro.info").write_text('display_name = "Mesen Test Core"\n', encoding="utf-8")

        icon = self.assets / "ozone/png/icons/Nintendo - Nintendo Entertainment System.png"
        icon.parent.mkdir(parents=True, exist_ok=True)
        icon.write_bytes(b"icon")
        boxart = self.thumbnails / "Nintendo - Nintendo Entertainment System/Named_Boxarts/Demo Game.png"
        boxart.parent.mkdir(parents=True, exist_ok=True)
        boxart.write_bytes(b"art")

        self.config.joinpath("retroarch.cfg").write_text(
            "\n".join([
                f'playlist_directory = "{self.playlists}"',
                f'libretro_directory = "{self.cores}"',
                f'libretro_info_path = "{self.info}"',
                f'assets_directory = "{self.assets}"',
                f'thumbnails_directory = "{self.thumbnails}"',
                f'savefile_directory = "{self.base / "custom saves"}"',
                f'savestate_directory = "{self.base / "custom states"}"',
            ]) + "\n",
            encoding="utf-8",
        )
        self.write_playlist()
        self.env = os.environ.copy()
        self.env.update({
            "RETRO_LIBRARY_CONFIG_DIR": str(self.config),
            "RETRO_LIBRARY_COMMAND": "/bin/true",
            "RETRO_LIBRARY_CORE_DIRS": str(self.cores),
            "RETRO_LIBRARY_INFO_DIRS": str(self.info),
            "RETRO_LIBRARY_ASSET_DIRS": str(self.assets),
            "XDG_STATE_HOME": str(self.base / "state"),
        })

    def tearDown(self):
        self.temporary.cleanup()

    def write_playlist(self, missing=False):
        items = [
            {
                "path": str(self.base / "missing.nes") if missing else str(self.rom),
                "label": "Demo Game",
                "core_path": str(self.mesen),
                "core_name": "Nintendo - NES / Famicom (Mesen)",
                "crc32": "DETECT",
                "db_name": "Nintendo - Nintendo Entertainment System.lpl",
            },
            {
                "path": f"{self.archive}#member.nes",
                "label": "Archive Game",
                "core_path": "DETECT",
                "core_name": "DETECT",
                "crc32": "DETECT",
                "db_name": "Nintendo - Nintendo Entertainment System.lpl",
            },
        ]
        payload = {
            "version": "1.5",
            "default_core_path": str(self.mesen),
            "default_core_name": "Nintendo - NES / Famicom (Mesen)",
            "items": items,
        }
        self.playlists.joinpath("Nintendo - NES.lpl").write_text(json.dumps(payload), encoding="utf-8")

    def run_helper(self, *arguments, ok=True):
        result = subprocess.run(
            [str(HELPER), *arguments], env=self.env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        payload = json.loads(result.stdout)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr or payload)
            self.assertTrue(payload["ok"])
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(payload["ok"])
        return payload

    def test_discovers_custom_config_and_directories(self):
        payload = self.run_helper("doctor")
        self.assertEqual(payload["source_kind"], "Custom")
        self.assertEqual(payload["config_dir"], str(self.config))
        self.assertEqual(payload["games"], 2)
        self.assertEqual(payload["playable_games"], 2)
        self.assertEqual(payload["save_dir"], str(self.base / "custom saves"))

    def test_lists_icons_thumbnails_and_compatible_cores(self):
        payload = self.run_helper("list")
        self.assertEqual(payload["total_games"], 2)
        self.assertEqual(payload["systems"][0]["short_name"], "NES")
        self.assertTrue(payload["systems"][0]["icon"].endswith("Nintendo Entertainment System.png"))
        self.assertEqual([core["id"] for core in payload["systems"][0]["cores"]], ["mesen", "nestopia"])
        demo = next(game for game in payload["games"] if game["label"] == "Demo Game")
        self.assertTrue(demo["thumbnail"].endswith("Demo Game.png"))

    def test_archive_member_uses_archive_for_availability(self):
        payload = self.run_helper("list")
        archive = next(game for game in payload["games"] if game["label"] == "Archive Game")
        self.assertTrue(archive["content_available"])
        self.assertTrue(archive["core_available"])

    def test_dry_run_uses_detected_command_and_playlist_core(self):
        payload = self.run_helper("launch", "--path", str(self.rom), "--dry-run")
        self.assertEqual(payload["command"], ["/bin/true", "-L", str(self.mesen), str(self.rom)])

    def test_favorite_and_core_override_round_trip(self):
        self.run_helper("favorite", "--path", str(self.rom), "--value", "true")
        self.run_helper("set-core", "--path", str(self.rom), "--core", str(self.nestopia))
        payload = self.run_helper("list")
        demo = next(game for game in payload["games"] if game["label"] == "Demo Game")
        self.assertTrue(demo["favorite"])
        self.assertEqual(demo["override_core_path"], str(self.nestopia))
        self.run_helper("set-core", "--path", str(self.rom), "--core", "auto")
        payload = self.run_helper("list")
        demo = next(game for game in payload["games"] if game["label"] == "Demo Game")
        self.assertEqual(demo["override_core_path"], "")

    def test_missing_content_is_reported_without_mutation(self):
        self.write_playlist(missing=True)
        payload = self.run_helper("list")
        missing = next(game for game in payload["games"] if game["label"] == "Demo Game")
        self.assertFalse(missing["content_available"])
        self.assertEqual(payload["playable_games"], 1)

    def test_unavailable_config_is_actionable_json_error(self):
        self.env["RETRO_LIBRARY_CONFIG_DIR"] = str(self.base / "does-not-exist")
        payload = self.run_helper("list", ok=False)
        self.assertIn("does not exist", payload["error"])

    def test_configure_persists_without_touching_retroarch(self):
        payload = self.run_helper(
            "configure", "--config-dir", str(self.config),
            "--retroarch-command", "/bin/true --verbose",
        )
        self.assertEqual(payload["settings"]["config_dir"], str(self.config))
        self.assertEqual(payload["settings"]["retroarch_command"], ["/bin/true", "--verbose"])
        state = json.loads((self.base / "state/retro-library/state.json").read_text(encoding="utf-8"))
        self.assertEqual(state["settings"], payload["settings"])
        self.assertTrue(self.config.joinpath("retroarch.cfg").is_file())

    def test_detects_flatpak_layout_and_command(self):
        fake_home = self.base / "flatpak-home"
        flatpak_config = fake_home / ".var/app/org.libretro.RetroArch/config/retroarch"
        flatpak_config.mkdir(parents=True)
        flatpak_playlists = flatpak_config / "playlists"
        flatpak_playlists.mkdir()
        shutil_source = self.playlists / "Nintendo - NES.lpl"
        flatpak_playlists.joinpath(shutil_source.name).write_bytes(shutil_source.read_bytes())
        flatpak_config.joinpath("retroarch.cfg").write_text(
            f'playlist_directory = "{flatpak_playlists}"\nlibretro_directory = "{self.cores}"\n',
            encoding="utf-8",
        )
        fake_bin = self.base / "fake-bin"
        fake_bin.mkdir()
        fake_flatpak = fake_bin / "flatpak"
        fake_flatpak.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        fake_flatpak.chmod(0o755)
        for name in (
            "RETRO_LIBRARY_CONFIG_DIR", "RETRO_LIBRARY_COMMAND", "RETRO_LIBRARY_CORE_DIRS",
            "RETRO_LIBRARY_INFO_DIRS", "RETRO_LIBRARY_ASSET_DIRS",
        ):
            self.env.pop(name, None)
        self.env.update({
            "HOME": str(fake_home),
            "XDG_CONFIG_HOME": str(fake_home / ".config"),
            "XDG_STATE_HOME": str(self.base / "flatpak-state"),
            "PATH": f"{fake_bin}:/usr/bin",
        })
        payload = self.run_helper("list")
        self.assertEqual(payload["source_kind"], "Flatpak")
        self.assertEqual(payload["retroarch"], f"{fake_flatpak} run org.libretro.RetroArch")


if __name__ == "__main__":
    unittest.main()
