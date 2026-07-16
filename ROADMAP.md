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

- [ ] **M1.2 — Session Hardening** **[size S]**
  Over-capacity join kicked back to menu; `peer_ready` dedup guard (the name-IS-peer-id
  race); host-left overlay polish; clean NetworkManager reset so a second host/join in
  one app run works.

- [ ] **M1.3 — Event Pipe** **[size S]**
  The referee plumbing all gameplay will use: client intent RPC → host validates + stamps
  `{peer, action, duration, outcome, server_time}` → broadcast → all instances react.
  Demo via one dev-console command visible on both instances. Dev console (MWF lift)
  arrives here.

- [ ] **M1.5 — Wire Check** **[size S — needs Jeff ~20 min, schedule opportunistically]**
  Event round-trips between Jon's and Jeff's machines over the real internet; log median
  RTT/jitter as a latency baseline. Validates NAT/reachability. Does not block M2.

- [ ] **M2 — Grid & Glide** **[size M]** *(unblocked — Q3 answered: 8-way, diagonal
  duration penalty, default 2.0×, DESIGN §2.2.7)*
  Tile grid; commit/glide movement with speed tiers (diagonal steps cost the multiplier);
  tile reservation incl. the diagonal corner/squeeze rule (must be defined here);
  server verdicts; "commit sent" ack + rejection bonk (DESIGN §2.2.8);
  attack-of-opportunity trigger wiring (no combat yet — just the free-attack event over
  8-neighbor adjacency).
  **Done =** two players glide around one room; commitment is *felt* — no canceling
  mid-glide.

- [ ] **M3 — First Blood** *(soft-blocked: Q1 death handling)* **[size M]**
  One monster type as a `.tres` resource; telegraphed wind-up attack; two-step hit/miss
  resolution with distinct per-outcome feedback + combat log (DESIGN §2.3); HP; death.
  Death placeholder = spectate, **explicitly disposable** — Q1's real answer replaces it;
  build nothing on top of it.
  **Done =** a party fights and can lose someone.

- [ ] **M4a — Dungeon Generation** **[size M]**
  Room-and-corridor generation (its own design pass first, per DESIGN §2.7); a goal/stairs
  placeholder (hardcoded scene is fine — disposable; M5's resource pipeline doesn't
  govern it).
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

- Death design — Q1's real answer replaces the M3 spectate placeholder
- Host disconnect policy (Q2): accept run-loss vs. save/resume story
- Origin-tile timing during a glide (Q4)
- AFK / rest zones (Q5)
- Ranged combat & LoS design pass (Q6) — alongside the build system pass
- Build system design pass (Rogue Fable-legibility bar, DESIGN §2.7)
- Dungeon generation depth (beyond M4's basic rooms-and-corridors)
- Shared-beat coordination mechanic (DESIGN §2.4.2) — only if a concrete need appears
- Resource-editing GUI tool for designers (CLAUDE.md ground rule: design resources as if it
  already exists)

---

## Working agreement

One milestone per session-or-few. A milestone ends when its **Done =** criterion is
demonstrated, not when the code compiles. Update this file's checkboxes in the milestone's
final commit.
