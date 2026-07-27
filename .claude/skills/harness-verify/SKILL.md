---
name: harness-verify
description: Run the scripted two-instance verification gate for Rogue's Oath changes. Invoke whenever a change needs demonstrating over the wire — milestone Done= checks, overnight-loop gates, or any "prove it works" moment. Encodes the harness recipes, knob gotchas, and assertion patterns validated in real sessions (v0.7.x).
---

# Harness verification — the two-instance gate

"Done" in this repo means **demonstrated two-instance**, never "it compiles" and never
a subagent's word. This skill is the repeatable recipe. Evidence order of preference:
**event-trace assertion > probe-file assertion > screenshot > eyeball**.

## Pre-flight (every run)

1. **Port check** — `Get-NetUDPEndpoint -LocalPort 3000`. If held, Jon may be
   hand-testing a live session: scripted clients WILL join his game. Stop and check
   with him unless the holder is a zombie from a crashed prior scripted run.
2. **Zombie cleanup** — track every PID you `Start-Process`; before a new run, kill
   leftovers from crashed runs (the console exe is safe to `Stop-Process` by tracked
   PID; the non-console exe relaunches itself — never launch that one for tests).
3. **Binary**: `C:\Users\Jon\Documents\Game Development\Engines\Godot 4.7.1\Godot_v4.7.1-stable_win64_console.exe`
   (console variant — stdout capturable when headless).

## Knobs — source of truth

The autostart harness is `debug/debug.gd` (everything after `--` on the command line).
**Do not trust any written knob table, including this file's examples — re-read
debug.gd's arg parser before composing a run.** Knobs exist for session shape
(port=/join=/hostdelay=/maxplayers=/name=/fakever=), movement (move=/hold=/tap=/click=/
shiftclick=), combat + items (shoot=/ability=/pickup=/use=/equip=/swap=), tempo
(tempo=/tactical=/beatsec=), world (goblin=/goblinat=/potion=/weapon=/hostile=), timing
overrides (glidesec=/windupsec=), scripted commands (cmd=/cmdwait=/cmd2=/cmd2wait=), and
capture (eventlog=/screenshot=/overlay=/rangeoverlay=/debugpanel=). The four the assertion
patterns below actually lean on are **`eventlog=<path>`** (the trace channel — an ALLOWLIST,
so check the action you want is in it), **`cmd=`/`cmd2=`** (a dev command through the real
interception path, with `cmd2=` defaulting to the cmd anchor + 2.0s), **`ability=`** and
**`pickup=`** (intent-level, so they bypass the focus-gated key sampler). Their semantics
change; the parser doesn't lie. `docs/dev-commands.md` carries the annotated tables.

## Instance topology

- **Headless host** (`--headless ... -- host ...` with `-RedirectStandardOutput`):
  the truth channel. NetEvents prints every stamped event — durations, sequence,
  outcomes. Most assertions read this log.
- **Windowed client** (no `--headless`): for anything visual (`screenshot=`) and for
  input paths that need a real DisplayServer. Windowed stdout capture is UNRELIABLE
  (the exe forks a GUI child) — never depend on it; use the host log or a probe file.

## The canonical two-instance invocation

One copy-pasteable run — headless host as the truth channel, windowed client for real input.
Adapt the knobs; keep the shape (tracked PIDs, redirected host stdout, an event trace).

```powershell
$godot = "C:\Users\Jon\Documents\Game Development\Engines\Godot 4.7.1\Godot_v4.7.1-stable_win64_console.exe"
$proj  = "C:\Users\Jon\Documents\Game Development\Godot 4.x\rogues_oath"
$out   = "$env:TEMP\ro"; New-Item -ItemType Directory -Force $out | Out-Null

# HOST — headless truth channel: stdout redirected, every stamped event traced to a file.
$h = Start-Process $godot -PassThru -RedirectStandardOutput "$out\host.log" -ArgumentList @(
  "--headless", "--path", $proj, "--",
  "host", "port=3000", "goblin=1", "goblinat=7,15", "eventlog=$out\events.log")

# CLIENT — windowed (real DisplayServer for input/visuals); joins loopback, walks, screenshots.
$c = Start-Process $godot -PassThru -ArgumentList @(
  "--path", $proj, "--",
  "join", "join=127.0.0.1:3000", "move=s,s,e", "movewait=3.0",
  "screenshot=$out\client.png")

Start-Sleep -Seconds 14                       # screenshot= self-quits its instance at ~6s
Stop-Process -Id $h.Id, $c.Id -ErrorAction SilentlyContinue
Get-Content "$out\events.log"                 # the assertion input
```

To script a dev command, add it to the HOST's array as one element (`"cmd=/god"`), then read
`$out\host.log` to confirm it arrived intact — see the two arg-mangling traps below.

## Hard-won gotchas (validated in sessions, dated)

- **PS 5.1 `Start-Process -ArgumentList` does NOT quote array elements (2026-07-26 — cost two
  runs):** the elements are joined with spaces raw, so `"--path", $proj` with this project's
  space-containing path splits into broken argv and Godot silently sits at the project-manager
  banner forever — log shows ONLY the engine banner, no version print, no eventlog file ever
  appears. Fix: embed quotes in the element itself: `"--path", "`"$proj`""`. A banner-only log
  IS this failure — don't wait longer, re-check the argv.
- **The SAME raw join silently truncates space-containing `cmd=` values (2026-07-27 — cost a
  gate run):** `"cmd=/config root_breaks_on_damage 1"` as a plain array element splits into
  three argv tokens; the game receives `cmd=/config` alone and the command lands as a usage
  reject (or, worse, a defaults-only variant that HAPPENS to pass — `/root me 30` truncating
  to `/root` still roots you for 30). Fix: embed quotes — `'"cmd=/config root_breaks_on_damage
  1"'` — and ALWAYS read the receipt back from that instance's stdout before trusting the
  assertion.

- **`cmd=` values are mangled by BOTH shells, silently, in two different ways (2026-07-26 —
  each cost a real run):**
  - *Git Bash / MSYS path conversion:* any value that starts with `/` is rewritten to a Windows
    path, so `cmd=/god` reaches the game as `cmd=C:/Program Files/Git/god` and parses as
    nothing. Fix: `MSYS_NO_PATHCONV=1` on the command (or run it from PowerShell).
  - *PowerShell argument-array splitting:* a value containing SPACES becomes several argv
    tokens, so `cmd=/w longsword 3` arrives as `cmd=/w` plus two orphans and the command lands
    TRUNCATED — no error, just a tuning that never happened. Pass it as a single quoted array
    element and then VERIFY from that instance's stdout that the whole command was received;
    if it still splits, use `--%` (stop-parsing) or set the value through the debug panel.
  - Both fail silently in the same shape: the run completes, the assertion just quietly tests
    the untuned game. Never assume a `cmd=` landed — read it back.
- `hold=` samples real input gated on OS window FOCUS — only the last-launched
  (client) window reliably holds keys. Host-side movement: use `move=` (submits
  intents directly, focus-immune).
- `click=` / synthetic mouse is DEAD under `--headless` — the headless DisplayServer
  never routes InputEventMouseButton. Verify clicks in a windowed instance.
- `screenshot=<path>` fires ~6s after that instance's `_ready` **and then quits the
  instance** — choreograph everything you want visible to happen before ~6s, and
  don't expect that instance to act afterward.
- A full-rect Control on a CanvasLayer with default `mouse_filter` (STOP) silently
  eats ALL mouse input (v0.7.1 bug) — screen-space overlays must set
  `mouse_filter = 2`.
- Referee cadence is server-paced: submitting `move=` faster than the busy window
  just produces rejects; space scripted moves ≥ the current step cycle
  (glide + rest at the live beat) or read the accepts, not the submits.
- Intent REJECTS print on the SENDER's stdout (reject-to-sender, §2.2.8), NOT the
  host's — a host-log-only capture sees accepted events but misses every reject. To
  observe rejects from a client-submitted intent, capture the CLIENT's stdout
  (headless client + cmd-redirect works; intent knobs need no rendering). A "missing"
  event with no reject in the host log usually means the reject went to the sender.

## Assertion patterns

1. **Event-trace assertion** (preferred): run, then assert on the host log — event
   presence/absence, `duration_sec` values before/after a change, sequence ordering,
   spacing between broadcasts. This is how tempo restamps, go-stop-go cadence, and
   instant-strike shapes were all verified.
2. **Headless logic script**: for pure-logic invariants (map connectivity, resource
   sanity), a `SceneTree` script run with `-s` — pattern: build inputs, call the
   static/loaded API, print `RESULT: PASS/FAIL`, `quit(0)`. Note: `-s` skips
   autoloads, so scripts that `load()` game scripts referencing autoloads will spew
   compile errors — load only autoload-free scripts (WorldGrid is safe), or ignore
   the noise if the data you print still emerges.
3. **Probe file**: when you must see inside a WINDOWED instance (input handlers,
   client-side state), temporarily add a `FileAccess` append inside the code under
   test writing to a scratch path; run; read the file; REMOVE the probe (grep for it)
   before committing. This found the v0.7.1 click-eater when stdout couldn't.
4. **Screenshot**: for visual claims only (tints, camera framing, labels). Read the
   PNG and name what you observe; a screenshot that merely "looks fine" is not an
   assertion — say what pixel-level fact it proves.

## Honesty rule

Report only what a run actually showed. "Verified by logic" / "wired correctly" is
NOT verification — label it explicitly as not-directly-observed, as prior session
reports do. A verification gap named honestly is acceptable; one papered over is not.
