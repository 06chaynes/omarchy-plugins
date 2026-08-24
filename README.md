# Omarchy Plugins

A collection of third-party shell plugins and bar widgets for Omarchy.

## Plugins

| Plugin | ID | Description | Upstream |
| :--- | :--- | :--- | :--- |
| **Is It Down?** | [`bottelet.is-it-down`](plugins/bottelet.is-it-down) | Service status page monitor with Azure, AWS, and Statuspage support. | [Bottelet/omarchy-is-it-down](https://github.com/Bottelet/omarchy-is-it-down.git) |
| **System Monitor** | [`harshith.system-monitor`](plugins/harshith.system-monitor) | System resource monitor and dashboard for the status bar. | [Harshith292002/omarchy-system-monitor](https://github.com/Harshith292002/omarchy-system-monitor.git) |
| **Omaprox** | [`io.github.andressm415.omaprox`](plugins/io.github.andressm415.omaprox) | Proxmox VE status dashboard with container and VM controls. | [AndresSM415/omaprox](https://github.com/AndresSM415/omaprox.git) |
| **Detailed Weather** | [`io.github.calebhat.weather`](plugins/io.github.calebhat.weather) | Weather forecasts, radar integration, and condition indicators. | [calebhat/omarchy-weather](https://github.com/calebhat/omarchy-weather.git) |
| **OmaRGB** | [`io.github.ilkaydnc.omargb`](plugins/io.github.ilkaydnc.omargb) | OpenRGB hardware lighting controller with theme synchronization. | [ilkaydnc/omargb](https://github.com/ilkaydnc/omargb.git) |
| **Omaherd** | [`io.github.salemsayed.omaherd`](plugins/io.github.salemsayed.omaherd) | HerdR agent task and attention inbox integration. | [salemsayed/omaherd](https://github.com/salemsayed/omaherd.git) |
| **Dropdown Terminal** | [`io.github.tuthan.dropdown-terminal`](plugins/io.github.tuthan.dropdown-terminal) | Floating dropdown terminal for special workspaces. | [tuthan/omarchy-dropdown-terminal](https://github.com/tuthan/omarchy-dropdown-terminal.git) |
| **Philips Hue Control** | [`omarchy-philips-hue`](plugins/omarchy-philips-hue) | Philips Hue light controls with Omarchy theme color synchronization. | [sethchev/omarchy-philips-hue](https://github.com/sethchev/omarchy-philips-hue.git) |
| **Omawire (WireGuard)** | [`glafeara.wireguard`](plugins/glafeara.wireguard) | WireGuard tunnel manager with multi-tunnel switching, live traffic, QR code export, and import. | [glafeara/omarchy-wireguard](https://github.com/glafeara/omarchy-wireguard.git) |
| **Notification Center** | [`jankeesvw.notification-center`](plugins/jankeesvw.notification-center) | Persistent notification history archive, DND controls, and notification drawer. | [jankeesvw/omarchy-notification-center](https://github.com/jankeesvw/omarchy-notification-center.git) |
| **Omarchy X-Ray** | [`io.github.randazraik.xray`](plugins/io.github.randazraik.xray) | Live process inspector and system trace overlay for windows, services, containers, ports, and devices. | [RandaZraik/omarchy-xray](https://github.com/RandaZraik/omarchy-xray.git) |
| **Omarchy Sensei** | [`io.github.nilszeilon.omarchy-sensei`](plugins/io.github.nilszeilon.omarchy-sensei) | Keyboard-first coach that turns mouse habits into shortcut practice tasks. | [nilszeilon/omarchy-sensei](https://github.com/nilszeilon/omarchy-sensei.git) |
| **Omagotchi** | [`slcode777.omagotchi`](plugins/slcode777.omagotchi) | Virtual desktop pet widget for the status bar. | [SLcode777/omagotchi](https://github.com/SLcode777/omagotchi.git) |

## Installation

Copy any desired plugin directory to your local configuration:

```bash
cp -r plugins/<plugin-id> ~/.config/omarchy/plugins/
```

Enable the plugin:

```bash
omarchy plugin enable <plugin-id>
```

Add the widget to your bar layout (in `~/.config/omarchy/shell.json`):

```bash
omarchy bar put <plugin-id>
```

## Changes and Maintenance

See [CHANGELOG.md](CHANGELOG.md) for details on custom patches, layout adjustments, and bug fixes applied to plugins in this collection.
