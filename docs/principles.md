# Design principles

The constraints Lictor is built to. They predate the architecture decisions in
[`adr/`](adr/) and are the thing those decisions are weighed against. Code comments cite
them by number.

Changing one of these is not a refactor. It changes what the project is for.

---

## The problem

The machine Lictor runs on is a daily-driver laptop, not a server. Tailscale SSH needs to
be open sometimes and closed the rest of the time, and "closed the rest of the time"
cannot rely on anyone remembering.

Replacing the Tailscale GUI with the Homebrew formula build made this worse: the SSH
server works, but nothing shows whether it is on. The only way to find out was
`tailscale debug prefs`.

So Lictor does three things:

1. Keep the state somewhere it will be seen
2. Make every enable carry an expiry
3. Enforce that expiry whether or not any part of Lictor is still running

---

## Principle 1 — Enforcement lives outside the app

**The expiry must not be implemented with a timer inside the menu bar app.**

If the app crashes, an in-process timer dies with it and SSH stays open indefinitely. That
is the worst failure this project exists to prevent.

| Layer | Responsibility | May die? |
|---|---|---|
| launchd agent | enforces the deadline | **no** |
| menu bar app | display, toggle, notifications | yes |
| shell prompt | a third independent view of the state | yes |

The property to preserve: **the app dying does not stop SSH from closing on time.**

## Principle 2 — The agent only ever moves toward off

The launchd agent has no ability to enable SSH. Its single write is `--ssh=false`.

Every way it can malfunction therefore fails toward closed.

## Principle 3 — Make the two directions cost different amounts

- **Off**: one click, no authentication, always available
- **On**: Touch ID, and a duration must be chosen

Friction belongs on the dangerous direction and nowhere else. Nothing may make anyone
hesitate to close SSH, and no misclick may open it.

## Principle 4 — There is no "on indefinitely"

Enabling always requires picking a duration. Forgetting is designed out rather than
guarded against, so no UI path may offer an unbounded session.

## Principle 5 — Stay close to read-only

The only thing Lictor writes to Tailscale is `RunSSH`. It does not control the Tailscale
connection itself, edit ACLs, or change any other pref.

A monitoring tool that accumulates control becomes worth attacking. Keeping the write
surface at one boolean keeps that from happening.

---

## The state file contract

`~/.local/state/lictor/state.json`

```json
{
  "version": 1,
  "expiresAt": "2026-08-01T14:30:00Z",
  "enabledAt": "2026-08-01T12:30:00Z",
  "durationSeconds": 7200
}
```

- **No file means no active session.** This is the whole contract; treat absence as
  authoritative, never as an error
- All times are ISO 8601 in UTC
- Writes are atomic: temp file plus `rename`
- Mode `0600`, in a `0700` directory

Both the agent and the app read and write this file, so the format is a cross-language
contract. `tests/run-interop.sh` is what keeps the two implementations honest.

---

## Display rules

- **The countdown is text, not just an icon.** A static icon dissolves into the menu bar
  within days; a number that decreases does not
- **The off state still shows an icon.** Nobody notices an absence. Off is quiet, not
  invisible
- **Never render "closed" before it is closed.** Enforcement runs on an interval, so time
  passes between the deadline and the actual close. Show what was measured, not what
  should have happened by now

---

## When in doubt

The value of this project is not how much it does. It is how few ways it has to fail.

Given an implementation that is more convenient but can leave SSH open when it breaks, and
one that is less convenient but always closes, **choose the second one**.

If a change would trade a failure mode for a feature, don't make it.

---

## Non-goals

Deliberately out of scope. These are not missing features.

- **Controlling Tailscale itself** — connection state, ACLs, any pref other than `RunSSH`
  (principle 5)
- **Showing or editing ACLs** — the data lives only in the admin console, which would mean
  holding an API key
- **A companion app on any other machine** — this runs on one host and stays there
- **Telemetry or any outbound network access** — the Tailscale LocalAPI is the only thing
  it talks to
- **Mac App Store distribution** — impossible, since the sandbox has to be off
