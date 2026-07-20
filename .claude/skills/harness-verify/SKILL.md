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
debug.gd's arg parser before composing a run.** Knobs exist for movement (move=/hold=/
tap=/click=), tempo (tempo=/tempowait=/beatsec=), world (goblin=/hostile=), timing
overrides (glidesec=/windupsec=), identity (name=), and capture (screenshot=,
overlay=). Their semantics change; the parser doesn't lie.

## Instance topology

- **Headless host** (`--headless ... -- host ...` with `-RedirectStandardOutput`):
  the truth channel. NetEvents prints every stamped event — durations, sequence,
  outcomes. Most assertions read this log.
- **Windowed client** (no `--headless`): for anything visual (`screenshot=`) and for
  input paths that need a real DisplayServer. Windowed stdout capture is UNRELIABLE
  (the exe forks a GUI child) — never depend on it; use the host log or a probe file.

## Hard-won gotchas (validated in sessions, dated)

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
