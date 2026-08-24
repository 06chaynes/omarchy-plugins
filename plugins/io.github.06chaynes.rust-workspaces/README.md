# Rust Workspaces for Omarchy

An Omarchy status bar plugin to automatically discover, monitor, inspect, and clean all Rust workspaces across your system to reclaim disk space from `target/` build artifacts.

## Features

- **Zero-Config Automatic Discovery:** Fast, non-blocking scan across common development directories (`~/Projects`, `~/Work`, `~/src`, `~/code`, `~/dev`, `~/Repositories`).
- **Disk Usage Breakdown:** Compares project source code size against disposable `target/` directory bloat.
- **Single & Batch Cleaning:** Run `cargo clean` per workspace, clean stale projects (>14 days inactive), or select custom batches with a 1-click reclaim summary.
- **Desktop Actions:** Quick buttons to launch your default terminal, open in `$EDITOR`, or reveal the workspace folder in your file manager.
- **Custom Scan Roots:** Add and manage custom scan paths from the settings drawer or configuration file.
- **Omarchy Bar Widget:** Displays the Rust crab/gear glyph and live total reclaimable space with middle-click rescan.

## CLI Usage

The backend engine can also be queried directly from the command line:

```bash
# Scan and output JSON summary
~/.config/omarchy/plugins/io.github.06chaynes.rust-workspaces/bin/rustctl scan

# Clean a specific workspace target
~/.config/omarchy/plugins/io.github.06chaynes.rust-workspaces/bin/rustctl clean /path/to/project

# Batch clean multiple workspaces
~/.config/omarchy/plugins/io.github.06chaynes.rust-workspaces/bin/rustctl clean-batch /path/1 /path/2

# Clean stale targets (>14 days)
~/.config/omarchy/plugins/io.github.06chaynes.rust-workspaces/bin/rustctl clean-stale 14

# Add or remove scan roots
~/.config/omarchy/plugins/io.github.06chaynes.rust-workspaces/bin/rustctl roots-add ~/CustomCode
~/.config/omarchy/plugins/io.github.06chaynes.rust-workspaces/bin/rustctl roots-remove ~/CustomCode
```

## Configuration

Configuration is stored in `${XDG_CONFIG_HOME:-~/.config}/omarchy/rust-workspaces.json`:

```json
{
  "scanRoots": [
    "~/Projects",
    "~/Work",
    "/workspace"
  ],
  "staleDaysThreshold": 14,
  "sizeWarningThresholdGB": 20,
  "useCargoClean": true
}
```

## License

MIT
