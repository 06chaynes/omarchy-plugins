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

## remco.wireguard

- Removed `statusSlot` constraint and set icon size to 16px (`Style.space(16)`).
- Matched active status highlight to `Color.accent` and idle state to theme foreground.
- Fixed ping measurement logic to auto-detect subnet gateway or accept configurable `pingTarget`.
- Added configurable `endpoint` and `pingTarget` settings schema to `manifest.json`.
- Translated Dutch strings to English in the details panel and status script.
