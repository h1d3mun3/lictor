# Lictor

A macOS menu bar app that shows whether Tailscale SSH is currently enabled on this machine,
and guarantees it gets switched back off on a deadline.

> A lictor was a Roman public officer who walked ahead of a magistrate carrying the fasces.
> The number of rods told passers-by how much authority was currently in force. The job was
> to make present power visible, and to carry it around where people could see it.

## Why

The machine this runs on is a daily-driver laptop, not a server. Tailscale SSH needs to be
open sometimes and closed the rest of the time, and "closed the rest of the time" cannot
rely on anyone remembering.

Replacing the Tailscale GUI with the Homebrew formula build makes it worse. The SSH server
works, but nothing indicates whether it is on; the only way to find out is
`tailscale debug prefs`.

So Lictor keeps the state somewhere it will be seen, makes every enable carry an expiry,
and enforces that expiry whether or not any part of Lictor is still running.

## How it is built

Three processes and one file. The split exists so that enforcement survives the app dying.

```
┌─────────────────────┐  write  ┌──────────────────────┐
│  Lictor.app         │────────►│ ~/.local/state/      │
│  (MenuBarExtra)     │◄────────┤   lictor/state.json  │
│  display + toggle   │  read   └──────────┬───────────┘
└─────────────────────┘                    │ read
┌─────────────────────┐                    │
│ launchd agent       │◄───────────────────┘
│ (every 60s)         │
│ expiry only         ├──► tailscale set --ssh=false
└─────────────────────┘
┌─────────────────────┐
│ zsh prompt          ├──► reads state.json
└─────────────────────┘
```

| Layer | Responsibility | May die? |
|---|---|---|
| launchd agent | enforces the deadline, only ever turning SSH **off** | **no** |
| menu bar app | display, toggle, notifications | yes |
| zsh prompt | a third independent view of the state | yes |

**No `state.json` means no active session.** That is the whole contract between them.

The rules this is built to are in [docs/principles.md](docs/principles.md). Two of them
explain most of the code:

- **Enforcement never lives inside the app.** A timer in the menu bar app dies with the app
  and leaves SSH open forever, which is the failure this exists to prevent
- **Off is one click; on costs Touch ID and a duration.** Friction belongs on the dangerous
  direction and nowhere else

## Requirements

- macOS 26 or later
- Tailscale installed as the **Homebrew formula**, not the App Store or standalone app.
  Tailscale SSH only runs as a server under the open-source `tailscaled`
- `sudo tailscale set --operator=$USER` already applied ([ADR-0001](docs/adr/0001-assume-a-single-user-with-operator-configured.md))
- A single user on the machine

The app cannot run under App Sandbox: it needs `/var/run/tailscaled.socket` and spawns the
`tailscale` CLI. Mac App Store distribution is therefore impossible and out of scope.

## Install

**1. The enforcement agent.** Independent of the app, and the part that actually matters.

```bash
bash agent/install.sh
```

This registers a LaunchAgent that runs every 60 seconds. It is the only component that
turns SSH off, and it keeps working when nothing else does.

> **It takes effect immediately.** If SSH is currently on without Lictor having enabled it,
> the first run closes it, and that disconnects anything already connected.

**2. The app.** Open `lictor.xcodeproj` in Xcode and run it, or build and copy
`lictor.app` to `/Applications`.

**3. The shell prompt** (optional). Add to `~/.zshrc`:

```bash
source /path/to/lictor/shell/lictor-prompt.zsh
```

It shows `ssh 12:34` on the right of the prompt while a session is open, reading only
`state.json`. It never invokes the CLI, because it runs before every prompt.

## Using it

Click the menu bar icon.

- **Off** — a lock icon and nothing else. This is the resting state, and it stays visible,
  because nobody notices an absence
- **On** — an open lock and a live countdown, `1:47`. Enabling asks for Touch ID and a
  duration; there is no unbounded option
- **Turning off** — one click, no authentication. **This disconnects anything currently
  connected** ([ADR-0008](docs/adr/0008-say-that-turning-off-disconnects.md))

Five minutes before expiry a notification offers to extend. Ignoring it is the safe
outcome: the session closes on its own.

`History` opens a window listing every session, and how each one ended. Entries where SSH
was enabled outside Lictor are the only ones marked in colour.

## Files it writes

Everything lives in `~/.local/state/lictor/`, mode `0700`.

| File | Purpose |
|---|---|
| `state.json` | the current session's deadline. Absent when SSH is off |
| `history.jsonl` | append-only session log, read by the history window |
| `agent.log` | what the agent did, for debugging |

Nothing is written anywhere else, and nothing is sent anywhere. The Tailscale LocalAPI on a
local unix socket is the only thing Lictor talks to.

To clear the history, delete `history.jsonl`. There is deliberately no button for it
([ADR-0012](docs/adr/0012-show-history-in-a-window.md)).

## Tests

```bash
bash tests/run-all.sh
```

Swift logic is covered by the `lictorTests` target; everything crossing a language or
process boundary is covered by shell suites, including the agent itself, the unix socket
client against a fake server, and the app and agent agreeing on the files they share.

None of them touch the real `tailscaled`, launchd, or the live state file.

## Design decisions

[docs/adr/](docs/adr/) records what was decided and what it cost. The measured behaviour of
the Tailscale LocalAPI, which has no official documentation, is in
[docs/localapi.md](docs/localapi.md).

## Non-goals

Deliberately absent, and not planned:

- Controlling Tailscale itself — connection state, ACLs, any pref other than `RunSSH`
- Showing or editing ACLs
- Observing who is connected ([ADR-0004](docs/adr/0004-do-not-observe-ssh-sessions.md))
- Telemetry or any outbound network access
- Mac App Store distribution

## License

[MIT](LICENSE).

The parts most likely to be useful on their own are `lictor/Services/UnixSocketHTTP.swift`,
because `URLSession` cannot talk to a unix socket, and `docs/localapi.md`, because the
Tailscale LocalAPI has no official documentation. Take either.

## Status

Built for one machine and one person. The assumptions in
[ADR-0001](docs/adr/0001-assume-a-single-user-with-operator-configured.md) and
[ADR-0002](docs/adr/0002-enforce-from-a-launchagent.md) are sized for that, and are wrong
for corporate or multi-user deployments.
