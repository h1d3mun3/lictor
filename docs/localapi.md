# Tailscale LocalAPI — measured contract

> There is no official documentation for the LocalAPI. Everything here comes from
> responses actually captured on the M1 Max on 2026-08-01.
> Nothing below is inferred. If something is not written here, it was not measured.
>
> Identifiers (IP addresses, email, node names, keys) are redacted as `<...>`.
> Raw captures live in `verify/results/` (gitignored).

- Environment: macOS 26.6 / Tailscale **1.98.10** (Homebrew formula build, `tailscaled` running as root)
- Capture script: `verify/m0-verify.sh`
- **This is not an interface Tailscale promises to keep stable.** `tailscale debug`
  says so itself: "it is not a stable interface". Treat breakage on upgrade as expected.

---

## 1. Socket

```
/var/run/tailscaled.socket
srw-rw-rw-  1 root  daemon
```

- The default for the Homebrew formula build. It does **not** exist under
  `/opt/homebrew/var/run/...` or `/usr/local/var/run/...`
- Permissions are **0666**, but being able to connect and being able to write are
  different things. Writes appear to be limited to `OperatorUser`
  (set via `tailscale set --operator`) and root
  - **Not verified**: whether a different user is downgraded to read-only
- `tailscale debug local-creds` prints access instructions (unused so far)

## 2. Host header handling

curl derives the `Host` header from the URL, so use `http://local-tailscaled.sock/...`.

| Host sent | Result |
|---|---|
| `local-tailscaled.sock` | **200** |
| `example.com` | **403** |
| header removed entirely (`-H 'Host:'`) | **400** |
| plus `Sec-Tailscale: localapi` | 200 (**works with or without it; not required**) |

**Always send `Host: local-tailscaled.sock`.** The 400 is not tailscaled rejecting an
empty host; it is the request being invalid HTTP/1.1 without a Host header at all.

## 3. Endpoints

Everything probed so far.

| Path | Method | Result |
|---|---|---|
| `/localapi/v0/prefs` | GET | 200 — current prefs |
| `/localapi/v0/prefs` | PATCH | 200 — partial update via MaskedPrefs. **Succeeds as non-root** |
| `/localapi/v0/status` | GET | 200 — same shape as `tailscale status --json` |
| `/localapi/v0/metrics` | GET | 200 |
| `/localapi/v0/ssh` | GET | 404 |
| `/localapi/v0/ssh-sessions` | GET | 404 |
| `/localapi/v0/sessions` | GET | 404 |
| `/localapi/v0/debug-log` | GET | 405 (presumably POST only) |

**No endpoint lists SSH sessions.** See section 7.

### GET requests are not logged

`tailscaled.log` records `POST` and `PATCH` only; `GET /localapi/v0/prefs` leaves no trace.
**Polling will not bloat the log.**

## 4. `GET /localapi/v0/prefs`

```jsonc
{
  "ControlURL": "https://controlplane.tailscale.com",
  "RouteAll": false,
  "ExitNodeID": "",
  "ExitNodeIP": "",
  "InternalExitNodePrior": "",
  "ExitNodeAllowLANAccess": false,
  "CorpDNS": true,
  "RunSSH": true,              // the one value Lictor cares about
  "RunWebClient": false,
  "WantRunning": true,         // whether Tailscale itself is up; Lictor reads, never writes
  "LoggedOut": false,
  "ShieldsUp": false,
  "AdvertiseTags": null,
  "Hostname": "",
  "NotepadURLs": false,
  "AdvertiseRoutes": null,
  "AdvertiseServices": null,
  "Sync": null,
  "NoSNAT": false,
  "NoStatefulFiltering": true,
  "NetfilterMode": 2,
  "OperatorUser": "<user>",    // whoever was passed to --operator
  "AutoUpdate": { "Check": true, "Apply": null },
  "AppConnector": { "Advertise": false },
  "PostureChecking": false,
  "NetfilterKind": "",
  "DriveShares": null,
  "AllowSingleHosts": true,
  "Config": {
    // private keys come back zeroed out, not populated
    "PrivateNodeKey":    "privkey:0000...0000",
    "OldPrivateNodeKey": "privkey:0000...0000",
    "NetworkLockKey":    "nlpriv:0000...0000",
    "UserProfile": {
      "ID": 0,
      "LoginName":     "<email>",
      "DisplayName":   "<name>",
      "ProfilePicURL": "<url>"
    },
    "NodeID": "<node-id>"
  }
}
```

**Private keys are zeroed, so reading prefs never exposes key material to Lictor.**
`Config.UserProfile.LoginName` (an email address) does come back verbatim — keep it out
of logs and history.

`tailscale debug prefs` produced byte-identical output.

## 5. `PATCH /localapi/v0/prefs` (writing)

MaskedPrefs format: send **both** the field and a `Set` flag named after it.

```bash
curl -sS -X PATCH \
  -H 'Content-Type: application/json' \
  --unix-socket /var/run/tailscaled.socket \
  --data '{"RunSSHSet":true,"RunSSH":false}' \
  http://local-tailscaled.sock/localapi/v0/prefs
```

- The response is the **full updated prefs** (same shape as GET)
- Returns **200** as non-root (as the operator user)
- Shows up in `tailscaled.log` as `EditPrefs: MaskedPrefs{RunSSH=false}`

### How this differs from the CLI

`tailscale set --ssh=false` issues two calls:

```
localapi: [POST]  /localapi/v0/check-prefs      <- validation
localapi: [PATCH] /localapi/v0/prefs
```

**A raw PATCH skips `check-prefs`.** Use the CLI when validation matters.

## 6. `GET /localapi/v0/status`

Identical to `tailscale status --json`.

```jsonc
{
  "Version": "...",
  "TUN": true,
  "BackendState": "Running",     // used for anomaly detection
  "HaveNodeKey": true,
  "AuthURL": "",                 // presumably carries a URL when logged out (not verified)
  "TailscaleIPs": ["<v4>", "<v6>"],
  "Self": { /* see below */ },
  "Health": [],                  // empty array means healthy; array of strings
  "MagicDNSSuffix": "<tailnet>.ts.net",
  "CurrentTailnet": { "Name": "...", "MagicDNSSuffix": "...", "MagicDNSEnabled": true },
  "CertDomains": null,
  "Peer": { "<nodekey>": { /* same shape as Self */ } },
  "User": { "<userid>": { /* profile */ } },
  "ClientVersion": null
}
```

Keys on `Self` and each `Peer`:

```
Active, Addrs, AllowedIPs, CapMap, Capabilities, Created, CurAddr, DNSName,
ExitNode, ExitNodeOption, HostName, ID, InEngine, InMagicSock, InNetworkMap,
KeyExpiry, LastHandshake, LastSeen, LastWrite, NoFileSharingReason, OS, Online,
PeerAPIURL, PeerRelay, PublicKey, Relay, RxBytes, TaildropTarget, TailscaleIPs,
TxBytes, UserID
```

`Self.CapMap` contained `https://tailscale.com/cap/ssh` and `ssh-behavior-v1`.
**That only says the tailnet permits the SSH feature.** It says nothing about whether
SSH is currently enabled, nor whether a session is in progress.

### Signals usable for anomaly detection

| Signal | Healthy value |
|---|---|
| `BackendState` | `"Running"` |
| `Health` | `[]` (empty) |
| connecting to the socket at all | succeeds (failure means tailscaled is down) |

`LastHandshake` / `RxBytes` / `TxBytes` describe peer traffic, **not SSH sessions**.
Do not conflate them.

---

## 7. Observing SSH sessions (S-3)

**Not available through the LocalAPI. Only through logs.**

### Stream: `tailscale debug daemon-logs`

Delivers log lines as they happen (logtap). **Events from before you subscribe are lost.**

```
ssh-conn-<YYYYMMDDTHHMMSS>-<hex>: handling conn: <peer-ip>:<port>-><user>@<self-ip>:22
ssh-conn-<...>: starting session: sess-<YYYYMMDDTHHMMSS>-<hex>
ssh-session(sess-<...>): handling new SSH connection from <email> (<peer-ip>) to ssh-user "<user>"
ssh-session(sess-<...>): access granted to <email> as ssh-user "<user>"
ssh-session(sess-<...>): starting pty command: [... tailscaled be-child ssh ...]
ssh-session(sess-<...>): Session complete          <- end of session
```

- **Both start and end are visible.** `sess-<...>` correlates them
- Timestamps embedded in the IDs are **UTC**
- **Not verified**: what is logged when access is denied instead of granted

### Persistent log: `/opt/homebrew/var/log/tailscaled.log`

Where `brew services` redirects stdout. Mode `-rw-r--r-- root admin`, so it is
**readable as non-root**. It contains the same lines historically, which is what an
app would need at launch to reconstruct sessions that started earlier.

### Pitfalls

1. **Rate limiting is real.** `[RATELIMIT] format("localapi: [%s] %s")` was observed.
   **Log lines can be dropped**
2. `daemon-logs` is a stream; it cannot tell you about the past
3. The log format is undocumented and unstable
4. macOS has no `getent`, so every session logs
   `error calling getent for user "..."`. Sessions still establish normally.
   Harmless noise

### Conclusion

**Session observation must never feed the enforcement decision in the launchd agent.**
Keep it as display-only, supplementary information.

Rationale: lines can be dropped by rate limiting and the format is unstable. Depending
on it would tilt failures toward "SSH left open" (docs/principles.md).

---

## 8. Still unverified

- Whether LocalAPI access from another user or process is downgraded to read-only
- What `status` / `prefs` return when logged out or when `tailscaled` is stopped
- Log format when an SSH connection is **denied**
- Behaviour and logging when `check` mode requires re-authentication
- `/localapi/v0/watch-ipn-bus` (would let us subscribe to prefs changes instead of
  polling; corresponds to `tailscale debug watch-ipn`)
