# Changelog

All local modifications, bug fixes, and feature additions applied to plugins in this collection.

## bottelet.is-it-down

- Added Microsoft Azure status feed integration (`https://azure.status.microsoft/en-us/status/feed/`).
- Added Azure region catalog and region muting in settings.
- Scaled bar icon to 22px (`Style.space(22)`) to match standard bar icons.
- Fixed popup anchoring so the panel opens directly beneath the bar button (`centerOnBar: false`).
- Matched bar icon idle color to the active theme foreground.

## harshith.system-monitor

- Updated bar text font size to `Style.font.body` and set margins to `8.75` to align with the standard datetime widget.

## io.github.calebhat.weather

- Replaced legacy 16px Weather Icons with Material Design weather glyphs for consistent scale and baseline.
- Added night-aware glyph variants for clear and cloudy conditions.
- Scaled bar icon to 26px (`Style.space(26)`).
- Fixed popup anchoring so the forecast panel opens directly beneath the bar button (`centerOnBar: false`).

## io.github.salemsayed.omaherd

- Scaled `SheepIcon` to 22px (`Style.space(22)`) in `SheepIcon.qml` and `BarWidget.qml`.

## io.github.tuthan.dropdown-terminal

- Removed `statusSlot` constraint and scaled terminal icon to 22px (`Style.space(22)`).

## omarchy-philips-hue

- Redesigned panel layout to 540px width with single-row light controls.
- Added collapsible room groups with global Expand/Collapse All controls.
- Added custom `HueSlider.qml` to prevent mouse wheel events from hijacking brightness while scrolling.
- Filtered API groups to physical `Room` types only to remove duplicate zones.
- Fixed Bash variable scoping bug in `pair.sh` during bridge discovery.
- Supported alphanumeric Base64 tokens on Hue Bridge firmware v1.78+.
- Fixed `45-hue.sh` theme hook environment sourcing and added on-demand palette sync.
- Set default theme sync state to disabled.
- Fixed popup anchoring so the panel opens directly beneath the bar button (`centerOnBar: false`).

## glafeara.wireguard (Omawire)

- Switched to `glafeara.wireguard` (Omawire) for full NetworkManager multi-tunnel management.
- Transactional tunnel switching, config import from file/clipboard, in-place rename, and editing.
- Added on-screen QR code export for mobile device pairing.
- Real-time traffic rate and total counters.
- Subnet gateway ping latency probing with configurable `pingHost` setting.

## jankeesvw.notification-center

- Added persistent notification center widget and history archive.
- Integrated quick DND toggle via right-click on the bar bell icon.
- Added support for searchable notification history, app grouping, and image attachment previews.

## io.github.randazraik.xray

- Added Omarchy X-Ray system trace overlay and launcher widget.
- Support for process lineage inspection, resource graphs, open file descriptors, listening sockets, and container runtimes.
- Built-in sensitive argument redaction and same-user process isolation.
- Integrated into center bar layout.

## io.github.nilszeilon.omarchy-sensei

- Added Omarchy Sensei keyboard coaching widget and practice tracker.
- Real-time mouse habit interception, automatic Super+K shortcut task generation, and lifetime leveling.
- Integrated into right bar layout with task badge counter.

## clipbasket.clipboard

- Added Clipbasket clipboard history manager with SQLite backend.
- Filter by Text, Links, Images, Files, and Saved/Pinned clips.
- Support for HTML-to-Markdown conversion, image dimensions lightbox, and password manager privacy filtering.
- Integrated into right bar layout.

## io.github.06chaynes.rust-workspaces

- Added Rust Workspaces manager and target cleaner plugin.
- Fast non-blocking discovery of Rust workspaces across development roots (~/Projects, ~/Work, ~/src, ~/code, ~/dev, ~/Repositories, ~/github).
- Disk usage inspection comparing source code size against disposable target/ build artifacts.
- Single workspace clean, multi-select batch clean, and stale build clean (>14d).
- 1-click desktop actions to launch default terminal (xdg-terminal-exec), default editor (omarchy-launch-editor), and file manager (xdg-open).
- Status bar widget with 5 right-click cyclable display modes (Size, Count, Detailed, Status, IconOnly) and middle-click rescan.
- Integrated into center bar layout.

## io.github.06chaynes.github-tracker

- Added GitHub Tracker & CI Alerts dashboard and bar widget plugin.
- Direct GraphQL and REST API querying via authenticated `gh` CLI credentials (zero token storage).
- 5-tab developer dashboard covering failing/running CI Action Alerts, live Actions Log, Review Requests, authored Pull Requests, and Pinned/Org Repositories.
- Multi-organization support with account switcher dropdown (`O`) for scoped filtering across personal and organizational memberships.
- Status bar widget with Octocat glyph and live dynamic badges for failing actions, review requests, and open authored PRs.
- 3 cyclable bar display modes (`BadgeCounts`, `AlertsOnly`, `IconOnly`), keyboard navigation (`1`-`5`, `O`, `/`, `R`, `Esc`), and instant background cache loading.
- Integrated into center bar layout.

## io.github.agata.omanano

- Added OmaNano Notes local-first Markdown notes library.
- 3-pane library panel with live syntax highlighting, folder organization, full-text search, and trash recovery.
- Detached tiled note window support (`Ctrl+Enter`) and full library window support (`Ctrl+Shift+Enter`).
- Fixed missing `qs.Ui` import in `PlainTextDropdown.qml` to resolve `BorderSurface` type error.
- Updated `BarWidget.qml` to use `BarIconButton` with 22px icon scaling.
- Integrated into center bar layout.

## melonamin.apple-music

- Added Apple Music dropdown, compact queue, live audio spectrum, and mini-player plugin.
- Added full-screen layer-shell click backdrop in `BarWidget.qml` to prevent accidental hover focus loss under `follow_mouse = 1` while ensuring clean click-away dismissal.
- Integrated into center bar layout.

## io.github.dlpwaters.retro-library

- Added Retro Library console-organized RetroArch launcher and playlist browser.
- Multi-system navigation, local box art previews, search, favorites, and 1-click ROM/save folder actions.
- Integrated into center bar layout.

## harel.omarchy-synchro

- Added 1-click atomic `sync` pipeline combining live capture, commit, and push in a single action.
- Added categorized visual change breakdown cards (Themes, Screensavers, Terminals/WM, Scripts, Hardware).
- Streamlined UI from 5 separate pages into a clean 3-tab layout (Dashboard, Restore & History, Settings & Policy).
- Added comprehensive pretty-printing formatter across all status previews, seed diagnostic stages, and remote actions.
- Updated top-bar widget with live dynamic sync state icons and status badges.
- Integrated into right bar layout.

## silvaio.gamemode

- Added Game Mode Switcher widget and control panel.
- Dynamic Hyprland optimizations: disable animations, blur, drop shadows, and window gaps while gaming with complete automatic restoration on exit.
- Distraction-free session management: Do Not Disturb, stay-awake idle inhibition, night light deactivation, and performance power profile switching.
- Steam Deck UI in Gamescope / Steam Big Picture session launcher.
- Quick launcher detection for installed game clients (Steam, Heroic, Lutris, Bottles, Prism Launcher, RetroArch).
- Integrated into right bar layout.
