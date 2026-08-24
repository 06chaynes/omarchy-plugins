# Changelog

## 0.6.2 - 2026-08-23

- Bound stdout and stderr for every captured child process and terminate the
  process group immediately when either stream crosses its byte ceiling.
- Reject Unix-socket snapshot frames above 1 MiB and cap the normalized model
  at 512 agents, 128 sessions per target, and 512 KiB of emitted JSON.
- Bound opt-in peek output at 64 KiB and replace QML's accumulating
  `StdioCollector` instances with explicitly capped stream consumers.
- Keep only the latest HerdR hook event in an atomically replaced log file,
  using a verified private runtime directory and a per-UID `/tmp` fallback.
- Harden notification state and child-process boundaries with no-follow file
  opens, bounded storage, atomic temporary files, and capped command output.

## 0.6.1 - 2026-08-23

- Focus existing HerdR windows through Hyprland's current Lua dispatcher,
  while retaining compatibility with the legacy dispatcher.
- Choose the right local window when several HerdR clients show one session,
  using the target workspace instead of whichever client has the oldest pid.
- Focus a remote target before retrying its ssh/mosh window title, so a carrier
  currently showing another workspace is still raised instead of duplicated.
- Carry the machine's own hostname in notification click actions for precise
  local and remote title matching.
- Avoid a transient reply-field null access while the panel is being rebuilt
  or the shell is restarting.

## 0.6.0 - 2026-08-22

First public release.

- A glanceable inbox: a herd meter and one legend line, then whoever needs a
  person first across every host, each agent's task underneath, elapsed time
  at the edge. Quiet agents and the host chooser fold behind one row each.
- Herd dots in the bar: one per active agent, grouped by machine, larger for
  an agent that needs input or finished; no numbers, no badge. Arrivals pop
  in, departures shrink out.
- Enter brings an agent to the front — the HerdR window for a local agent, the
  `herdr --remote`, ssh or mosh window showing a remote one — or attaches in a
  terminal when nothing is on screen. `A` always attaches.
- One desktop notification per agent, replaced as its state changes,
  withdrawn when it moves on, clickable to focus; survives shell restarts and
  never leaves a stale ask on screen.
- Instant updates through a HerdR plugin hook, linked on first run.
- Remote hosts monitored over noninteractive OpenSSH with connection sharing,
  discovered from `~/.ssh/config` and Tailscale, hidden with `X` when unwanted.
- Opt-in peek (`P`) and reply (`I`) for agents waiting on an answer.
- Local sessions read straight from HerdR's socket.
