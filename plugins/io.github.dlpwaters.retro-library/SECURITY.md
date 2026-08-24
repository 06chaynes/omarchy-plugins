# Security

## Design

Retro Library runs with the current user's permissions inside the Omarchy shell. It reads RetroArch configuration, playlists, installed-core metadata, local thumbnails, and its own state file. It does not use the network or request elevated privileges.

Launches use argument arrays without a shell. Playlist paths and configured commands are never interpolated into shell source. State updates use an atomic same-directory replacement.

## Reports

Please use GitHub's private security-advisory form for suspected vulnerabilities. Do not include ROMs, firmware, credentials, or private playlist contents in a report.
