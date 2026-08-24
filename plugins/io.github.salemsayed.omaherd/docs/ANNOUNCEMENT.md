# Announcement

Image: `docs/images/announcement.png` (1600×900, Discord and Twitter).
Regenerate with `tools/demo/capture.sh card`.

## Discord

**Omaherd** — your coding agents, in the Omarchy bar.

HerdR runs your agents; Omaherd tells you who needs you. One glance at the
bar says whether anyone is waiting, one click shows what each agent is doing
and for how long, and Enter drops you into its pane — on this machine or on
any host you can reach over SSH.

- Who needs input, who finished, who is working — loudest first, across hosts
- The task each agent is on, from the title it sets itself
- One notification per agent that withdraws itself when the agent moves on
- Instant updates through a HerdR hook; remote hosts polled over shared SSH
- Keyboard first: `J`/`K`, Enter, `A`, `X`, `G`, and opt-in `P` peek / `I` reply

```bash
omarchy plugin add https://github.com/salemsayed/omaherd.git --enable
```

Needs HerdR 0.8.0+ (remote window matching: 0.8.2 on the remote).

Marketplace: https://omarchyplugins.com/plugin.html?id=io.github.salemsayed.omaherd
Source: https://github.com/salemsayed/omaherd

## Tweet

> Omaherd — your coding agents, in the Omarchy bar.
>
> Who needs you, what each agent is doing, how long it has waited — local and
> remote — with one keypress to the pane. Built on HerdR.
>
> omarchyplugins.com/plugin.html?id=io.github.salemsayed.omaherd
