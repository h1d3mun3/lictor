# Working on Lictor

What Lictor is and how to install it: [README.md](README.md).
This file is about changing it.

## Read these first

| Document | What it holds |
|---|---|
| [docs/principles.md](docs/principles.md) | the constraints the project is built to. Code comments cite these by number |
| [docs/adr/](docs/adr/) | what was decided, what it was chosen over, what it costs |
| [docs/localapi.md](docs/localapi.md) | the Tailscale LocalAPI as measured. It has no official documentation |

When a decision recorded in an ADR turns out to be wrong, **update the ADR in the same
change that updates the code**. A superseded ADR is marked and linked, not deleted; the
reason a decision was reversed is worth more than the decision.

The original brief the project was built from is in Japanese, deliberately untracked, and
excluded by `.gitignore`. Everything it specified now lives in `docs/principles.md`, so
nothing in the repository should reference it.

## Two rules that outrank convenience

- **Never implement the deadline with a `Timer` inside the app.** If the app crashes, the
  timer dies with it and SSH stays open indefinitely. That is the failure this project
  exists to prevent (principle 1)
- **The agent may only ever move toward off.** It never runs `--ssh=true` (principle 2)

`agent/test-agent-e2e.sh` asserts the second one by recording every command the agent
invokes across all cases. If a change makes that assertion fail, the change is wrong.

## Language

**Everything that persists in this repository is written in English**: source and comments,
documentation, commit messages, log output, notification bodies, and user-facing UI
strings.

Conversation with the maintainer happens in Japanese. That does not change what gets
committed.

`bash tests/check-language.sh` enforces it. Rationale, and one concrete bug it prevents,
are in [ADR-0007](docs/adr/0007-write-everything-in-english.md).

## Layout

| Path | What it is |
|---|---|
| `agent/` | the launchd agent. Shell, deliberately: it must not share a build with the app |
| `lictor/` | the menu bar app. `Core/` is pure logic, `Services/` touches the world, `Views/` draws |
| `lictorTests/` | Swift Testing target for the app's logic |
| `shell/` | the zsh prompt integration |
| `tests/` | everything that crosses a language or process boundary |
| `verify/` | the one-off script that established the measurements in `docs/localapi.md` |

`lictor/` and `lictorTests/` are file-system-synchronized groups, so a new `.swift` file is
picked up without touching the project file.

## Tests

```bash
bash tests/run-all.sh
```

| Command | Covers |
|---|---|
| `bash agent/test-agent.sh` | `decide()`, the agent's pure decision function |
| `bash agent/test-agent-e2e.sh` | agent side effects, against stub binaries |
| `bash tests/run-unit.sh` | the app's logic, via the `lictorTests` target |
| `bash tests/run-socket.sh` | the unix socket HTTP client, against a fake LocalAPI |
| `bash tests/run-interop.sh` | the app and the agent agreeing on the files they share |
| `bash tests/run-prompt.sh` | the zsh prompt, under real zsh |
| `bash tests/check-language.sh` | the language rule |

None of them touch the real `tailscaled`, launchd, or the live state file.

The split between Swift Testing and shell is deliberate. Swift Testing covers the app's own
logic; shell covers everything crossing a boundary, because that is where a break stays
invisible. `run-interop.sh` in particular is the only thing standing between a serialisation
change and silently disabling enforcement.

**Keep decisions in pure functions.** `decide()` in the agent and `computeDisplay()` in the
app both take the current time as an argument and never call `Date()` internally. That is
what makes the boundary cases testable, and the two must agree: `now == expiresAt` counts
as expired on both sides.

## Build

```bash
xcodebuild -project lictor.xcodeproj -scheme lictor -configuration Debug build
```

App Sandbox is off and has to stay off: the app needs `/var/run/tailscaled.socket` and
spawns the `tailscale` CLI. `LSUIElement` keeps it out of the Dock and Cmd-Tab.

## Files it writes at runtime

`~/.local/state/lictor/`, mode `0700`.

| File | Written by | Notes |
|---|---|---|
| `state.json` | app, agent | the contract between them. **Absent means no session** |
| `history.jsonl` | app, agent | append-only. Never trimmed, never rewritten |
| `agent.log` | agent | free-form, for humans. **Never parse it to build a UI** |

Both shared files are cross-language contracts. Changing either means changing two
implementations and `tests/run-interop.sh` in the same commit.
