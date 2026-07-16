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

- [ ] **M1 — Plumbing** *(unblocked — next up)* **[size M]**
  Extract MWF networking per the CLAUDE.md reuse boundary: `network_manager.gd`
  near-verbatim; GameManager config pattern; host/join menu; dev console; session flow
  reimplemented (not copied) with the four preserved behaviors.
  **Done =** two local instances host + join into an empty 2D scene, AND all four
  session-flow behaviors demonstrated: over-capacity join is kicked back to the menu; host
  quit shows the host-left flow on the client; a client disconnect despawns them on the
  host; a duplicate `peer_ready` doesn't double-spawn.

- [ ] **M2 — Grid & Glide** **[BLOCKED: Q3 diagonals — awaiting Jeff]** **[size M]**
  Tile grid; commit/glide movement with speed tiers; tile reservation; server verdicts;
  "commit sent" ack + rejection bonk (DESIGN §2.2.8); attack-of-opportunity trigger wiring
  (no combat yet — just the free-attack event; the adjacency definition arrives with Q3's
  answer).
  **Done =** two players glide around one room; commitment is *felt* — no canceling
  mid-glide.

- [ ] **M3 — First Blood** *(soft-blocked: Q1 death handling)* **[size M]**
  One monster type as a `.tres` resource; telegraphed wind-up attack; two-step hit/miss
  resolution with distinct per-outcome feedback + combat log (DESIGN §2.3); HP; death.
  Death placeholder = spectate, **explicitly disposable** — Q1's real answer replaces it;
  build nothing on top of it.
  **Done =** a party fights and can lose someone.

- [ ] **M4 — The Dungeon** **[size L]**
  Room-and-corridor generation (its own design pass first, per DESIGN §2.7); LoS/fog;
  minimap with teammates; a goal/stairs placeholder (hardcoded scene is fine — disposable;
  M5's resource pipeline doesn't govern it).
  **Done =** a start-to-goal run exists.

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
