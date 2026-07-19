# ROADMAP.md — Rogue's Oath

The milestone chain. Each milestone ends with something you can see work (its **Done =**
criterion), gets verified, and gets committed — with its checkbox updated in the same commit.
A stale roadmap is a roadmap bug.

Legend: `[x]` done · `[ ]` open · **[BLOCKED: …]** names the DESIGN.md Part 4 question that
gates it · **[size S/M/L]** is a rough per-milestone effort signal (session-or-few each).

---

## Milestones

- [x] **M0 — Foundations** *(2026-07-15)*
  DESIGN.md v0.3, CLAUDE.md router, git repo, 32rogues assets, v0.3 PDF exported for Jeff.

- [x] **M1 — See Each Other** *(2026-07-15)* **[size S]**
  The smallest real multiplayer milestone. Lift from MWF: `network_manager.gd`
  (near-verbatim), minimal GameManager/GameConfig, simplified 2D host/join menu. Fresh
  `main.tscn`/`main.gd`: MultiplayerSpawner, `peer_ready` flow, player = 32rogues sprite +
  name label at server-assigned positions. DEBUG-style two-window test helper. Basic
  disconnects (client quit → host despawns them; host quit → client back to a working
  menu). Principle that carries into everything after: **the host is the referee** —
  clients send requests, only the host changes game state.
  **Done =** two windows, one hosts one joins, each shows both players' sprites; the
  basic disconnect paths work.

- [x] **M1.2 — Session Hardening** *(2026-07-17)* **[size S]**
  Join handshake: client resends `peer_ready` (0.5s interval, 5s budget) until its own
  player node replicates in (implicit ack) or it gives up — closes the silent-drop race
  when the host's main scene isn't loaded yet (GLM sweep finding, 2026-07-15; reproduced
  and verified via the harness's `hostdelay=` knob). Host-left polish: every session-end
  path (host left, kicked, handshake timeout) funnels through `_end_session(reason)` and
  surfaces its reason on the menu's error label; name field prefilled on return.
  (Capacity kick, dedup guard, NetworkManager reset, and server-side name clamping shipped
  early — M1 + the code-smell pass already cover them.)

- [x] **M1.3 — Event Pipe + Chat/Combat Log** *(2026-07-16)* **[size S]**
  The referee plumbing all gameplay rides: `submit_intent` → host validator registry →
  stamped `{seq, peer, action, data, server_time}` broadcast (+ reject-to-sender — the
  §2.2.8 bonk seam). First passenger: player chat, rendered in the shared chat/combat log
  panel (join/leave system lines included; the §2.3.4 combat-log surface). Dev console
  (MWF lift) deferred to when it's needed.

- [x] **M1.5 — Wire Check** *(2026-07-18)* **[size S]**
  Event round-trips between Jon's and Jeff's machines over the real internet; log median
  RTT/jitter as a latency baseline. Validates NAT/reachability. Does not block M2.
  *Pre-check (2026-07-17, same-PC through the playit.gg tunnel):* full join + chat
  round-trip works via both `147.185.221.211:22619` and the ply.gg hostname (Godot
  resolves TYPE_ANY → the A record; the AAAA is never picked on Jon's IPv4-only machine).
  Harness knob for Jeff's session: `-- join join=<addr[:port]>`.
  *Update (2026-07-18):* **reachability validated for real** — Jon+Jeff full session over the
  tunnel: join, chat, and every movement method worked.
  *Root cause, corrected (2026-07-18):* BOTH sessions' connection failures were the menu's
  **host-port footgun** — the address field's `:port` applied to hosting too, so with the
  tunnel address (`...:22619`) left in the field, Host bound 22619 while the tunnel forwards
  to 127.0.0.1:3000 (verified live: the running host sat on 22619, nothing on 3000). The
  interim "no host running" diagnosis was wrong — the host was up, one port to the left. The
  07-17 "playit agent churn" theory is demoted to a possible-but-unconfirmed contributor:
  Jon self-tested a tunnel join that morning and likely hosted with the address still in the
  field (producing the identical In>0/Out=0 signature), while the harness's own tests bound
  3000 by construction — which alone explains "it settled on its own." Fixed in code:
  hosting honors the field's :port only for loopback-style addresses (main_menu.host_port)
  and the log's first line prints "Hosting on port N." (+ an ignore notice). Runbook: FIRST
  check that line; the agent-restart recipe is the fallback if the port checks out.
  **Done (2026-07-18): latency baseline recorded** — first wire session on the pipelined
  build (v0.3.4). Client (Jeff) F3 move verdict: **median 66.7ms / p95 83.3ms** (145
  samples, 60fps steady); host ≈0 (synchronous idle verdicts). The pipeline's smoothness
  bound (RTT < step duration) holds with ~4× headroom against the 350ms normal step.

- [x] **M2 — Grid & Glide** *(2026-07-17)* **[size M]**
  Logical tile grid (WorldGrid is truth, TileMapLayer is paint); commit/glide movement with
  designer-editable speed tiers (`.tres`) and the diagonal duration multiplier; host-authoritative
  tile reservation incl. the diagonal corner rule (walls block the squeeze, bodies don't — both
  rules are provisional GameConfig toggles: `bodies_block_corners`, `origin_frees_at_glide_start`);
  server verdicts stamped from shared config; §2.2.8 "commit sent" ack + rejection bonk
  (sound + flash + log line); attack-of-opportunity TRIGGER wiring — the host-authored
  `free_attack` event over 8-neighbour adjacency (no combat yet), demoable two-instance via the
  `hostile=1` harness knob.
  **Done =** two players glide around one room; commitment is *felt* — no canceling
  mid-glide.

- [x] **M2.1 — Input Methods** *(2026-07-17)* **[size S]**
  Numpad with dual-bound diagonals + gamepad d-pad/left-stick, via InputMap alone (action
  deadzones 0.2 → 0.35); click-to-move with client-side pathing — lazy `AStarGrid2D` over
  WorldGrid (`DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` = the corner rule's wall half, octile
  heuristics) feeding the SAME one-step intent pipe, so the server never sees a path or a
  target (DESIGN §2.2.9). Per-step recompute detours around bodies via a transient avoid
  tile; two consecutive rejects drop the walk ("Stopped walking."); unreachable clicks get
  "Can't reach that."; commit-sent cue fires on fresh input only (one click = one cue); a
  faint target marker shows the standing destination. Harness knobs: `tap=`/`tapsec=`
  (through the real InputMap), `click=`/`clickdelay=`, `holdwait=`.
  **Done =** scripted numpad diagonal, stick steps, and a click-path bending around a
  pillar — all two-instance.

- [x] **M3 — First Blood** *(2026-07-18)* **[size M]**
  One monster type as a `.tres` resource (Goblin — chases via the referee, whole-room
  aggro placeholder); telegraphed TILE-commit wind-up (vacate to whiff — §2.3.3);
  DETERMINISTIC resolution (RF3 baseline, Jeff — the planned hit/miss roll is PARKED in
  §2.3.1) with distinct per-outcome feedback + combat log; HP (nameplate readouts); death.
  Death placeholder = instant despawn + spectate log, **explicitly disposable** — Q1's
  real answer replaces it; nothing is built on top of it.
  **Done = verified 2026-07-18, two-instance:** bump kill (2×5 vs 10 HP), chase→wind-up→
  hit, dodge=whiff (with the goblin's free attack punishing the flee — §2.2.6 composing),
  AoO real damage, and a full party wipe (goblin killed host then client; session
  survived). Player bump swing interval carries 0-0.25s retry jitter (~0.5-0.75s) — Jeff
  feel-test pending; queued-attack-slot follow-up parked if it reads as lag.

- [x] **M3.5 — Tempo** *(2026-07-19)* **[size M]** *(plan: 2026-07-19 playtest feedback)*
  The beat becomes a variable (DESIGN §2.8): global `beat_sec`, all durations authored in
  beats, stamp-and-bake at verdict time; live +/- tempo knob (any peer requests, host
  clamps/broadcasts, readout + late-join sync); go-stop-go movement (1-beat glide +
  1-beat rest, all movers); windup experiment closed — instant strike + 2-beat visible
  recovery both sides (machinery kept behind `windup_beats=0`); aggro persistence
  (acquire-only range); disposable multi-room map + follow camera.
  **Done =** two-instance: client +/- changes both windows' cadence live (stamped
  in-flight commits finish at old tempo); go-stop-go hold; symmetric attack trades with
  visible recovery; cross-room chase without aggro drop; camera follows through rooms;
  late joiner matches a mid-session tempo.

- [ ] **M4a — Dungeon Generation** **[size M]**
  Room-and-corridor generation (its own design pass first, per DESIGN §2.7); a goal/stairs
  placeholder (hardcoded scene is fine — disposable; M5's resource pipeline doesn't
  govern it). *Spec constraints (added v0.5.2, from the review pass):* every generated map
  keeps a full solid border — MoveReferee's `_NO_TILE` sentinel assumes (0,0) is wall —
  and regeneration must rebuild WorldGrid's cached A* grid (a stale grid paths through the
  old walls).
  **Done =** a generated dungeon with a start and a goal, walkable in multiplayer.

- [ ] **M4b — Seeing the Dungeon** **[size M]** *(Q3 answered: 8-way — LoS must handle
  diagonals and corner cases)*
  LoS/fog; minimap that also shows teammates.
  **Done =** a start-to-goal run exists with real visibility rules.

- [ ] **M5 — Loot & Builds** **[size M]**
  Items + placeholder stats as resources; drop tables; the designer pipeline proven.
  **Done =** a new monster/item ships via a `.tres` file alone, no code — ideally authored
  by Jeff; if he's unavailable that session, Jon (or a scripted `.tres` round-trip check)
  closes the gate and Jeff's authoring test moves to the next touchpoint.

- [ ] **M6 — The Loop** **[size M]**
  Permadeath + run start/end flow; party HUD (portraits/HP, commit-lock tells, nameplates);
  win/lose screens.
  **Done =** a full run works in two local instances.

- [ ] **M7 — Cross-Machine Reality Check** **[size S–L, unknown]**
  Jon + Jeff play a full run online for real. Deliberately its own milestone: NAT/latency
  findings may force networking rework, and that fallout stays isolated here instead of
  contaminating M6's scope.
  **Done =** one completed (or honestly failed-and-diagnosed) real-internet run.

---

## Post-slice parking lot

Not scheduled — pulled in when their moment comes:

- Host round-reset key (v0.5.4) — F5 re-seeds the whole world in place; a disposable wire-session dev
  facility that stands in for M6's real run start/end flow, which replaces it when M6 lands
- Death design — Q1's real answer replaces the M3 spectate placeholder
- Host disconnect policy (Q2): accept run-loss vs. save/resume story
- Origin-tile timing during a glide (Q4) — *(provisional shipped in M2: frees at glide start —
  `origin_frees_at_glide_start` GameConfig toggle; final call awaits playtest)*
- AFK / rest zones (Q5)
- Ranged combat & LoS design pass (Q6) — alongside the build system pass; include whether
  AoO adjacency should respect walls/corners (M2 wires pure 8-adjacency per §2.2.6 — a
  hostile diagonally around a wall corner currently still threatens; GLM review flag,
  2026-07-17)
- Build system design pass (Rogue Fable-legibility bar, DESIGN §2.7)
- Dungeon generation depth (beyond M4's basic rooms-and-corridors)
- Shared-beat coordination mechanic (DESIGN §2.4.2) — only if a concrete need appears
- Resource-editing GUI tool for designers (CLAUDE.md ground rule: design resources as if it
  already exists)
- Dedicated host-port UI field — only if the local-address heuristic (main_menu.host_port,
  currently loopback-only + a visible ignore notice in the log) ever needs to grow
- Client stop-and-go travel (RTT gap between steps, wire-test finding 2026-07-18) — FIXED
  v0.3.4: pipelined next step per DESIGN Part 4 Q7 (Jeff approved 2026-07-18; one
  server-held, committed-on-accept slot, broadcast at the mover's glide boundary).
  Smoothness confirmed on the wire 2026-07-18: Jeff's F3 med 66.7 / p95 83.3ms vs the
  350ms step (M1.5's recorded baseline)
- Stick deadzone tuning — shipped at 0.35 in M2.1; per-axis thresholding means lower values
  widen the stick's diagonal arcs vs cardinals (~0.45 would equalize them) — retune on real
  controller feel
- Octile pathing vs the duration multiplier — click-to-move paths weight a diagonal √2 but
  the server charges `diagonal_step_multiplier` (2.0 default, where diagonal and L-shape tie);
  if the multiplier moves off 2.0, paths become mildly time-suboptimal — revisit A* weights
  then (M2.1)
- Rhythm-experiment reversions (v0.6.0, all single-value edits): speed-tier variation
  (three .tres values), diagonal multiplier off 1.0, AoO re-enable, click pathing
  re-enable, longer windup telegraph — each waits on Jon+Jeff playtest verdicts.
  *Telegraph readability: answered NO at both 0.25s attempts; the 0.5s retry was
  dodgeable-every-time (voice verdict 2026-07-19) — windup experiment CLOSED v0.7.0
  (instant strike + recovery, DESIGN §2.3.3); any future windup re-test should run WITH
  AoO re-enabled (the config where dodging costs). Client "left."-spam + death-"left."
  bug: FIXED v0.6.3 (departures ride transport truth now)*
- Dedicated audio pass: real SFX to replace the pitch-shifted placeholders, and a
  proper mix (v0.6.2 shipped the placeholder GRAMMAR: silent movement, swing-vs-impact
  pitch separation, blink tell, no windup sound — the real-sample pass is still parked)
- Chat polish: speech bubbles overhead (WoW-style), name colors (escape-then-wrap the
  already-escaped name), timestamps, chat sounds
- ~~Distinct "Server is full." message for capacity-kicked clients~~ — DONE: shipped
  v0.5.0 via the `session_refused` RPC, and v0.5.1 adopted exactly this bullet's
  prescription (`peer_disconnect_later` inside NetworkManager's contract) after the
  code review proved the interim delay-then-kick was a race — this bullet's 2026-07-17
  flush-before-disconnect analysis was right all along.

---

## Working agreement

One milestone per session-or-few. A milestone ends when its **Done =** criterion is
demonstrated, not when the code compiles. Update this file's checkboxes in the milestone's
final commit.

Ending a session mid-milestone? Write `HANDOFF.md`, dated (what's done, what's in progress,
next concrete step, surprises). Delete it in the milestone's final commit — a lingering
HANDOFF.md means unfinished work; the date tells you how stale.
