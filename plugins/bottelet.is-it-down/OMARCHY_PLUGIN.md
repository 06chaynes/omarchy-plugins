# Is It Down? — Omarchy plugin

Bar widget (`kinds: ["bar-widget"]`, entry `BarWidget.qml`), id `bottelet.is-it-down`.
Watches service status pages and badges the bar when something a user depends on
is degraded.

## Install

Installs to `~/.config/omarchy/plugins/bottelet.is-it-down/`.

```sh
omarchy plugin add https://github.com/Bottelet/omarchy-is-it-down.git --enable
omarchy bar put bottelet.is-it-down --after omarchy.weather
```

## IPC

`IpcHandler` target `bottelet.is-it-down` exposes: `open`, `close`, `show`,
`hide`, `toggle`, `refresh`, `settings` — e.g. bind a key to
`omarchy-shell ipc call bottelet.is-it-down toggle`.

## Settings

Configured in the widget's own entry in `~/.config/omarchy/shell.json`, or via
the ⚙ panel / `omarchy bar set`:

| Key | Type | Meaning |
| --- | --- | --- |
| `services` | multiselect | Which status pages to watch (empty = default set) |
| `awsIgnoreRegions` | multiselect | AWS regions to mute (legacy; folded into `ignore.aws`) |
| `ignore` | object | Per-service muted components/regions, keyed by service |
| `customServices` | array | User-defined Statuspage services `{key,name,api,page}` |
| `refreshMinutes` | integer | Poll cadence (default 3, min 1) |
| `okColor` / `warnColor` / `downColor` | string | Status colors (theme urgent is the default for down) |

```sh
omarchy bar set bottelet.is-it-down refreshMinutes 10
omarchy bar set bottelet.is-it-down okColor "#a6e3a1"
```

## Technical

Follows the Omarchy panel shape: exposes `settings` and `setting(name, fallback)`,
delegates `Color` and `Style` to Omarchy's `qs.Commons` / `qs.Ui`. Fetches run
through stock `curl`/`jq`/`iconv`; responses are byte-capped and service-supplied
strings are rendered as plain text. Settings persist only to this plugin's own
`shell.json` entry.
