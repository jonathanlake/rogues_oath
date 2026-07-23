# Research Note — Procedural Generation & Minimaps (M4a / M4b design-pass input)

**Status:** research input, not a design decision. Compiled 2026-07-23 from four web-research
passes + a GLM-5.2 (different-family) cross-check. Feeds the M4a/M4b design passes DESIGN §2.7
calls for; nothing here is committed game design until that pass runs.

**Why this exists:** M4a (Dungeon Generation) replaces `WorldGrid.ROOM_LAYOUT` — a hardcoded
48×28 `Array[String]` map — with procedural room-and-corridor generation; M4b (Seeing the
Dungeon) adds LoS/fog + a teammate-showing minimap in the reserved HUD right column. Both were
still greenfield, so this gathers the outside canon before either is built.

**Constraints every finding below respects (from the codebase, not negotiable):**
- Godot 4.x, GL Compatibility renderer, GDScript only, 2D top-down, 32px tile grid.
- Multiplayer-first + **server-authoritative**; sync discrete commit events, never per-frame.
  `MultiplayerSynchronizer` is banned for gameplay. Dungeon gen must be **deterministic from a
  host-broadcast seed** so every peer builds an identical grid.
- Designer-editable: generation params belong in a `.tres` Resource (`@export`), not in script.
- `world/world_grid.gd`: static `ROOM_LAYOUT`, `TILE_PX=32`, `is_wall/is_walkable/tile_to_world`,
  lazy `AStarGrid2D` (`DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE`, octile). TileMapLayer painted FROM
  this data (presentation only). `MoveReferee._NO_TILE` sentinel requires (0,0) stays wall → every
  generated map keeps a **full solid border**; regen must **rebuild the cached A* grid**.
- Feel target: DCSS / Rogue Fable legibility.

---

## A. Minimaps in traditional roguelikes — design & data model

**The structural insight that drives everything:** a minimap is not a shrunken screenshot — it is
a **second renderer over the same tile + visibility state the main view uses.** Any other build
desyncs.

- **Canonical data model = two sticky boolean grids** the size of the map:
  - `visible[x][y]` — in field-of-view *this* action (recomputed every move).
  - `explored[x][y]` — has *ever* been visible; sticky (`explored |= visible` each FOV pass).
  Each tile type renders with **three appearances**, selected `visible ? light : explored ? dark : black`.
  The `dark` state is **"remembered terrain"** — you keep seeing discovered walls/stairs out of LoS.
  ([Roguelike Tutorial pt.4](https://rogueliketutorials.com/tutorials/tcod/v2/part-4/))
- **Terrain is remembered; actors are not.** Monsters/items draw only on currently-visible tiles;
  terrain persists in `explored` (so the remembered map can be usefully stale).
- **DCSS is the reference minimap:** a *semantic recolor* — one flat color per tile *category*
  (floor/wall/door/stairs/water), bright reserved colors for player/hostile/ally/stairs, a
  **distinct color for remembered-vs-seen** walls, all user-editable (the color-blindness escape
  hatch). ([DCSS options_guide](https://crawl.akrasiac.org/docs/options_guide.txt))
- **Level size decides whether you need one at all.** Rogue/NetHack/Brogue levels are screen-sized
  → the main view *is* the overview (no minimap). DCSS/Cogmind/Qud have large levels → reduced-color
  minimap or zoom-out overmap. If a level fits one screen, a full-screen "view map" mode is the
  cheaper high-value feature; a corner minimap is the always-on convenience.
- **Multiplayer (thin roguelike canon; principle-level):** core choice is **shared team `explored`**
  (simplest, fits a tight co-op party) vs **per-player** memory. Teammate **position dots can be
  drawn over fog without revealing terrain** — position-sharing is separate from terrain revelation,
  and the dots come free off the movement events already on the wire. Optional lightweight
  **map pings/markers** (each player a fixed color) as a coordination layer.
- **Pitfalls:** recolor, don't shrink sprites; keep remembered-vs-current visibly distinct; don't
  rely on hue alone; **one source of truth** (never a parallel "what the minimap thinks is there"
  copy); cache the texture, update only changed tiles. Cogmind's zoom-out lessons if ever added:
  never let the player token leave view, add **edge markers for off-screen threats/allies**,
  auto-recenter on danger.

Sources: DCSS options; [Roguelike Tutorial pt.4](https://rogueliketutorials.com/tutorials/tcod/v2/part-4/);
Cogmind [overmap](https://www.gridsagegames.com/blog/2020/11/exploring-concept-terminal-roguelike-overmap/)
& [map-zoom QoL](https://www.gridsagegames.com/blog/2024/02/adventures-in-map-zooming-part-5-qol/);
[Hexworks vision/fog](https://hexworks.org/posts/tutorials/2019/04/27/how-to-make-a-roguelike-vision-and-fog-of-war.html).

---

## B. Minimap implementation in Godot 4 — ranked for our case

Our case flips the usual tutorial ranking: **small grid (whole map fits the panel),
data-model-driven, GL Compatibility, event-sync not per-frame.**

1. **Custom `_draw()` Control driven by the logical grid — BEST FIT.** One node in the reserved HUD
   slot; iterate the wall/floor array, `draw_rect(tile * cell_px, color)`. **Redraw only via
   `queue_redraw()` on `GameEvents` commit signals** — never per-frame. Coord conversion is a plain
   `tile * cell_px` (no camera projection). Pure 2D canvas API → renderer-agnostic, **safe on GL
   Compatibility**. Reads authoritative grid → can't desync.
2. **ImageTexture, 1 pixel per tile, nearest-neighbor `TextureRect`** — near-tied, *preferable if
   fog is first-class* because **the `Image` doubles as the fog buffer** (`set_pixel` +
   `texture.update(img)` on explore events). Also GL-safe.
3. **Concrete build = hybrid:** static map via #1 or #2 (rarely changes) + **moving markers as
   lightweight child nodes** with per-teammate `modulate` — isolates frequent marker moves from map
   redraws. (Pick ONE mechanism per concern: markers positioned as child nodes on movement events;
   the canvas `_draw` redraws only on terrain/fog change — don't drive markers through both.)
4. **SubViewport + second Camera2D — LAST for us.** Most-tutorialized, but a **second render target
   every frame** (throttle `render_target_update_mode = UPDATE_WHEN_VISIBLE`) + icon-layer
   bookkeeping; its wins (scrolling/rotating a large world, free sprite fidelity) don't apply when
   the whole small map is always visible.

**Stale-API flags:** older tutorials use `set_cellv()` (Godot 3) → Godot 4 is
`TileMapLayer.set_cell(coords, source_id, atlas_coords)`; some KidsCanCode/GDQuest dungeon tutorials
are Godot 3 (OpenSimplexNoise, old TileMap). Set `texture_filter = TEXTURE_FILTER_NEAREST` on any
scaled minimap texture.

Sources: [KidsCanCode minimap 4.x](https://kidscancode.org/godot_recipes/4.x/ui/minimap/index.html);
[Godot custom drawing in 2D](https://docs.godotengine.org/en/stable/tutorials/2d/custom_drawing_in_2d.html);
[abitawake fog-of-war minimap](https://abitawake.com/news/articles/create-a-2d-minimap-with-fog-of-war-in-godot)
(concept valid, `set_cellv` stale); [renderers doc](https://docs.godotengine.org/en/4.4/tutorials/rendering/renderers.html).

---

## C. Procedural dungeon-generation algorithm canon

Nystrom's framing: everything is **room-first** (scatter rooms, then connect) or **space-first**
(fill with structure, then carve). Families ranked by the property that matters most here —
**connectivity guarantee**:

| Family | Feel | Connectivity | Notes |
|---|---|---|---|
| **Chained tunneling** (Rogue) | built, rectangular | **by construction** (connect room *i*→*i−1*) | tiniest code; tree/no loops |
| **BSP rooms + corridors** | even, gap-free | **by construction** (tree) | canonical; tree is a hook for biomes/vaults |
| **Cellular-automata caves** (4–5 rule) | organic caverns | **NOT guaranteed** → flood-fill + cull/connect | great as a *biome/post-process* |
| **Drunkard's walk** | winding tunnels | connected *iff* single origin | good hybrid filler |
| **TinyKeep** (Delaunay + MST + loops) | organic, non-gridded | structural (MST) | **physics separation = FP determinism hazard** |
| **Template/prefab vaults** (DCSS) | curated set-pieces | must validate door reachability | *layout authored, contents randomized* |
| **Brogue accretion + machines** | varied shapes + puzzles | structural (accretion tree) | gold-standard interestingness; big investment |
| **Mazes** (recursive backtracker) | twisty dead-ends | perfect maze = connected | needs dead-end prune + loop-add to be fun |

**Load-bearing cross-cutting findings:**
- **Guarantee-by-construction >> generate-then-validate.** By-construction families need *no*
  validation pass and *no* nondeterministic "discard and regenerate" — exactly what a deterministic
  networked generator wants. Reserve flood-fill culling for CA caves only.
- **Place stairs at the BFS/Dijkstra-farthest tile from spawn** (or a random room in the top
  distance band) → maximizes traversal, guarantees solvability.
  ([Wolverson ch.27](https://bfnightly.bracketproductions.com/chapter_27.html),
  [Red Blob BFS dungeons](https://www.redblobgames.com/x/2043-bfs-dungeons/))
  **Weight the BFS by real move durations, not tile count** — see the diagonal-cost note in §E.
- **Loops beat trees — worth double for co-op.** Pure MST/maze/plain-BSP forces single-path
  backtracking; a few extra edges create alternate routes, flanking, regroup paths. (TinyKeep,
  Nystrom's loop chance, Dormans' cyclic-dungeon-generation.) State the count as
  **max(1–2 edges, 15% of tree edges)** so small maps don't collapse to a pure tree.
- **Determinism hazards named:** unseeded/shared RNG streams; iteration order over hash sets/dicts;
  floating point (TinyKeep physics separation is the poster child). Fix via seed-splitting, iterate
  only ordered structures, integer math, and/or host-generate-and-replicate.

Sources: [Nystrom Rooms & Mazes](https://journal.stuffwithstuff.com/2014/12/21/rooms-and-mazes/);
[Wolverson map builders](https://bfnightly.bracketproductions.com/);
[TinyKeep writeup](https://www.gamedeveloper.com/programming/procedural-dungeon-generation-algorithm);
[Brogue reconstruction](http://anderoonies.github.io/2020/03/17/brogue-generation.html) +
[Walker talk](https://www.youtube.com/watch?v=Uo9-IcHhq_w);
[DCSS vaults](http://crawl.akrasiac.org/docs/develop/levels/introduction.txt);
[PCG Book](http://pcgbook.com/); [RoguelikeDevResources](https://github.com/marukrap/RoguelikeDevResources).

---

## D. Godot 4 procgen + deterministic networked generation

- **THE determinism trap:** `Array.shuffle()` uses the **global** RNG, not your seeded instance
  (no `RandomNumberGenerator.shuffle()` in stable). A single stray `shuffle()` or unseeded `randi()`
  **works single-player and silently desyncs only over the wire.** Fix: one `RandomNumberGenerator`
  threaded through *every* draw; hand-rolled Fisher-Yates on that instance; **prefer `randi_range`
  (integer)** for coords/counts to dodge float determinism. Godot 4 auto-randomizes the global seed
  at startup (no `randomize()`). Same-build peers + same seed + integer math = identical output (no
  cross-*version* guarantee).
  ([RandomNumberGenerator](https://docs.godotengine.org/en/stable/classes/class_randomnumbergenerator.html),
  [determinism forum](https://forum.godotengine.org/t/best-way-to-make-a-deterministic-algorithm-in-godot/123754),
  [shuffle proposal #11853](https://github.com/godotengine/godot-proposals/issues/11853))
- **Networked reproducibility — seed vs full map:** broadcast the **seed** (~8 bytes, a natural
  reliable `call_local` commit event, all peers regen identically) *or* broadcast the finished grid
  as a `PackedByteArray` (zero determinism risk, clients just paint). Seed-broadcast is the indie
  default and fits our event model; full-map is the bulletproof fallback. Gate gameplay start behind
  a `world_ready` ack mirroring the existing `peer_ready` pattern.
- **Painting + pathfinding from one pass:** `TileMapLayer.set_cell` (or `set_cells_terrain_connect`
  for autotiled walls); TileMap updates **batch at frame end** so thousands of `set_cell` calls cost
  one rebuild (don't force `update_internals()`); `clear()` between regens. Rebuild `AStarGrid2D`:
  set `region`/`cell_size`/`diagonal_mode` → **`update()` (clears all points)** → *then*
  `set_point_solid`/`fill_solid_region` (no second `update()`). Drive logical grid + TileMapLayer +
  A* from the **same generated array in one pass** so they can't disagree.
  ([TileMapLayer](https://docs.godotengine.org/en/stable/classes/class_tilemaplayer.html),
  [AStarGrid2D](https://docs.godotengine.org/en/stable/classes/class_astargrid2d.html))
- **Params as a Resource:** `DungeonGenConfig extends Resource` with `@export_range` tunables (room
  count/size, corridor width, map size, atlas coords), shipped in the build so all peers share
  identical params. **Seed stays OUT of the `.tres`** (host rolls per-run + broadcasts; optional
  fixed test-override). Satisfies "add a `.tres`, not code."
- **Closest existing reference:**
  [slashskill BSP dungeon in Godot 4 (TileMapLayer)](https://www.slashskill.com/procedural-dungeon-generation-in-godot-4-bsp-trees-rooms-and-corridors/)
  matches our architecture but **shows no seeding** (relies on global RNG) — inject our own `rng`.
  Also [Ziva's 5 patterns](https://ziva.sh/blogs/godot-procedural-generation).

---

## E. GLM-5.2 cross-check adjudication

A different-family model red-teamed the findings. It **confirmed the core technical claims**
(`Array.shuffle()` global RNG; `set_cellv()` is Godot 3; no `RandomNumberGenerator.shuffle()`; the
approaches are sound) and pushed the generic research to collide with this game's specifics.

**Accepted — fold into the design pass:**
- **Determinism needs a runtime detector, not just a test.** Broadcast seed **+ a hash of the final
  grid**; on host/client mismatch, auto-fall-back to the `PackedByteArray` full-map. The harness
  assert alone can't catch a *runtime* desync.
- **The `world_ready` ack must gate *tile-dependent commits*, not just "gameplay start."** Verify
  whether the existing `peer_ready` gate blocks all tile-dependent RPCs or only the start signal.
- **FOV-vs-commitment timing is the real hard question** (not "which FOV algorithm"): recompute
  visibility at **commit boundaries (glide-arrival events)**, never mid-glide — consistent with the
  event-sync-only rule.
- **Stairs = farthest by *weighted* BFS.** CONFIRMED in code: `game_config.gd` `diagonal_step_multiplier
  = 2.0`, so diagonals cost 2×, not octile's √2 — weight the BFS by MoveReferee's real per-direction
  durations.
- **Seed-echo for designers:** on generation, log/emit the run seed to the dev channel (`/w`,`/m`,
  F5-reseed framework) so a buggy layout can be pinned into a fixed-seed test.
- **Loop count as `max(1–2 edges, 15%)`** — a bare percentage rounds to zero loops on a ~5-room tree.
- **Name the shared-`explored` rule explicitly:** "unioned on commit, never partitioned"; decide the
  death/disconnect behavior (permadeath + spectate exist — does a downed/DC'd player's solo-explored
  area stay shared?). One-way ratchet, not a trivial default.
- **Pick ONE marker mechanism** (see §B.3).

**Settled against the code (no change needed):**
- **A* `update()` ordering** — CONFIRMED: `world_grid.gd._build_astar()` already does
  `region → update() → set_point_solid loop`; the recommended regen order matches existing code.
- **Movement corner-cutting** is already guarded (`DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE` +
  MoveReferee's corner rule). GLM's corner-cut worry is a *sight/LoS* issue (M4b) — `line_tiles()`
  is already documented not-LoS-correct pending that pass.

**Partially accepted — scoping note:** "BSP is over-engineered for 48×28" is fair *only if* the map
stays 48×28 — but `map_size` is a `DungeonGenConfig` `@export` (the current grid is a disposable
fixture; the research example used 80×80). BSP's payoff scales with map size, so **target map size +
room count + min-leaf size are the first decisions of the M4a design pass**; BSP-vs-chained is a
coin-flip at small N, and **chained tunneling stays the recommended one-day spike** to prove the
deterministic broadcast pipeline over the wire before committing to BSP.

---

## F. Recommended direction (research conclusion, not a locked decision)

**M4a — Dungeon Generation (first):**
- **BSP rooms + L-corridors + a loop-adding pass (max(1–2, 15%)) + stairs at the weighted-BFS-farthest
  room.** Connectivity guaranteed by construction (no nondeterministic retry); naturally
  deterministic with one seeded integer RNG; the BSP tree is a hook for later biomes/vault slots;
  loops matter double for co-op. *Chained tunneling is the one-day pipeline spike.*
- **Networking: broadcast seed + grid-hash** via reliable `call_local` RPC + one seeded
  `RandomNumberGenerator`; harness-assert host grid == client grid for a fixed seed; auto-fall-back to
  **full-map `PackedByteArray`** on hash mismatch (and as the mods/cross-version escape hatch).
- **Params:** `DungeonGenConfig extends Resource` (`.tres`, `@export_range`), seed excluded (with a
  seed-echo to the dev channel).
- **Respect existing invariants:** full solid border ((0,0) wall), rebuild A* on regen (`update()`
  before solids), one build pass drives logical grid + `TileMapLayer` + A*; reuse `world_grid.gd`'s
  `is_wall/is_walkable/tile_to_world` — the generator *replaces* `ROOM_LAYOUT` as the data source.
- **Determinism code-review gate:** no `Array.shuffle()`, no unseeded `randi()`/`randf()`, iterate
  only ordered structures, integer coord draws.

**M4b — Seeing the Dungeon (after M4a):**
- **Minimap: custom `_draw()` (or 1px ImageTexture if fog is first-class) in the reserved HUD right
  column, redrawn only on `GameEvents` commit signals; markers as overlay child nodes with
  per-teammate `modulate`.** GL-safe, one source of truth, no per-frame cost.
- **Fog/LoS: two boolean grids** (`visible` + `explored`), three-state render
  (light / dim-remembered / black); terrain remembered, actors only when visible, teammate dots over
  fog; **shared team `explored`** to start ("unioned, never partitioned"); FOV via recursive
  shadowcasting recomputed at **commit boundaries** — the venue where the **LoS-proper corner rule**
  (`line_tiles` is not LoS-correct) finally lands.
- **Palette in `@export` config** (color-blindness escape hatch); reserve bright colors for
  player/teammates/hostiles/stairs; distinct dim color for remembered.

**One open decision for the design pass:** seed-broadcast+hash (recommended) vs full-map broadcast as
the *primary* transport for M4a. The recommendation is seed+hash with full-map as auto-fallback.

*Round 2 (below) revisits that transport call, adds the floor-timing/persistence decision, and folds in
the Zorbus deep-dive — see §G. It's framed as a decision brief because Jon's call (2026-07-23) is that
these identity-level choices get made **with Jeff**, not pre-decided.*

---

## G. Round 2 — deeper research + decision brief (for the Jeff session)

Procgen is the game's primary randomness source (DESIGN §2.7), so Round 2 went deep on the three
questions Jon raised — multiplayer-over-the-wire, *when* floors are generated, and the Zorbus dev's
public design writing — and it **revised two of Round 1's leans**. Options + tradeoffs below, framed for
a designer discussion, not pre-decided.

### G.1 Algorithm — now a THREE-way choice (area-accretion joined the race)

Round 1 recommended BSP. The Zorbus deep-dive surfaced a strong third by-construction option:

- **Area-accretion ("grow through existing walls").** Zorbus AND Brogue both use it (Mike Anderson /
  *Tyrant* "Dungeon-Building Algorithm"). Start with one room; repeatedly attach a new feature (room,
  corridor, cave, circle, prefab vault) through an open connection point ("mark") on the existing
  dungeon. **Connectivity guaranteed by construction** (no repair pass). A separate FINALIZE pass prunes
  dead-ends and adds loops. Dev's stated reasons: *"very simple, ensures every area is reachable, easy to
  control the mix of area types (esp. corridor density)."*
- Why attractive for us: (1) same by-construction guarantee as BSP/chained, no nondeterministic retry;
  (2) **prefab SHAPE decoupled from CONTENT** — author a room *template* (`.tres`/scene), roll its
  *contents* (monsters/loot/theme) at gen time (Zorbus: 1151 prefabs, contents rolled per-run) = our
  "add a `.tres`, not code" rule realized; (3) one spawn-weight per area type = clean designer knobs;
  (4) it's the Brogue lineage Round 1 already called the gold standard.
- The three real candidates, all by-construction: **chained tunneling** (tiniest — the pipeline spike);
  **BSP** (even/gap-free, tree hooks biomes); **area-accretion** (most varied, prefab-content decoupling,
  best ceiling — a bit more to build). *Updated lean for the eventual target: area-accretion, with
  chained-tunneling still the spike to prove the wire pipeline first.*

### G.2 Multiplayer transport — REVISED: full-map-primary is now a serious option

Round 1 leaned seed+hash+fallback. Round 2 (real co-op war stories) reframes it: **we are NOT lockstep**
— generation is one-shot at level start, same build, same OS — so the determinism horror stories
(Factorio/Nuclear Throne) mostly don't apply. What shipped co-op roguelikes actually do:
- **Host-authoritative seed-broadcast + a collective "level ready" ack-gate** is the norm (Barony, Streets
  of Rogue, Diablo's seed-derived maps, the Enter-the-Gungeon co-op mods all seed-sync).
- BUT for a *tile grid* (a few KB compressed, sent once) the "full map" payload is itself tiny. Since we'd
  build the full-map serializer anyway as the fallback, one honest option is to **make full-map the PRIMARY
  transport and drop the seed** — deleting the whole determinism-discipline burden + the version caveat +
  the hash, for a few KB. (Vorixo's "streaming the world is a terrible idea" is about full ACTOR worlds,
  not a tile grid.)
- **Two defensible endpoints for Jeff to choose between:**
  - **(A) Seed-primary** (+ hash tripwire, + optional full-map fallback): smallest wire footprint; costs
    lifelong gen discipline (dedicated seeded RNG instance, integer-only, ordered iteration — no
    `Array.shuffle`/global `randi()`).
  - **(B) Full-map-primary** (host generates, broadcasts the compressed grid, clients paint): zero
    determinism risk, no discipline, no hash; costs a few KB per floor. *Newly the lean* — a tile grid is
    so cheap that this buys out an entire bug class.
- **Non-negotiable either way (Round 1 under-specified this):** a **collective readiness gate** — nobody,
  including a slow builder, starts until the server has every peer's "floor ready" ack — plus a
  **join-in-progress** story (resend seed/map to a late joiner). These bite shipped co-op games more than
  seed-vs-map does.
- **Godot specifics:** reliable RPCs are ordered PER CHANNEL → put the level/handshake on its own channel
  so it can't head-of-line-block behind gameplay commits; `RandomNumberGenerator` is deterministic
  same-build (fine for us) but never rely on global `randi()`/`randomize()`.

### G.3 When to generate + persistence — up-front is OUT; live call is one-way vs persistent

Round 2 answered "designed at run start?" decisively:
- **Kill "generate the whole dungeon up front."** DOMINATED — nobody in the tradition does it; it buys
  nothing that deterministic **lazy per-floor** seed-derivation (`floor_seed = hash(run_seed, floor_index)`)
  doesn't already give, and it wastes work on floors a ~1hr permadeath run often never reaches (many runs
  wipe partway down). Generate each floor when the party first reaches it.
- Persistence is the majority default (NetHack/DCSS/Brogue/ADOM/Qud persist visited floors); Angband's
  regenerate-on-return is the deliberate minority ("level as inexhaustible resource," anti-hoarding, one
  floor alive at a time).
- **Co-op crux:** every comparator biases toward keeping the party TOGETHER on one floor. Barony *allows*
  split floors but warns it causes "mismatched saves"; Never Split the Party enforces togetherness by
  design. Free split-party play multiplies simulation + camera + sync surface — exactly what our event
  model minimizes.
- **Three options (C deferred):**

  | Option | Persistence | Party model | Cost | Best when |
  |---|---|---|---|---|
  | **A. One-way descent** | none (floor discarded behind you) | all-on-stairs → descend together; one active floor | lowest state/sync; no backtrack/stash | max simplicity; decisions are spatially FINAL (reinforces permadeath/commitment identity) |
  | **B. Persistent** | keep visited floors | same descend-together gate; party can climb back up together | modest (a few KB/floor); enables retreat/stash/revisit | you want tactical retreat + stashing without split-floor complexity |
  | **C. Free split party** | keep all floors live | players roam different floors | highest (per-floor sim, separated cameras, most sync) | ONLY if emergent split-up is a wanted feature — **defer to its own milestone** |

- **The descend gate fits the Commitment Rule** (DESIGN §2.1): "all on the stairs → commit → the party
  glides down together" is a *group* committed action, adjudicated server-side. On-theme.
- *Lean:* start with **A** (one-way; spatial finality reinforces identity), **B** as an easy upgrade if
  playtests show players want to fall back to a cleared floor. Kill up-front; defer C.

### G.4 Bonus — a dev-tooling roadmap from Zorbus (separate thread)

Zorbus's "Behind the Scenes" is a model for small-team roguelike tooling; several map onto things we
already gravitate toward. Candidates (→ ROADMAP parking-lot bullets, NOT part of M4a):
- **AUTOPLAY** — AI plays runs over and over, logging errors. Our overnight harness taken further; catches
  commit-rule/networking edge cases at volume.
- **Seed-echo + full log** — log the run/floor seed so any bad/desynced map is reproducible (essential if
  we go seed-primary).
- **Debug minimap showing invisible state** — area IDs, entity positions, a targeted entity's pathfind
  path. Doubles as a **network-sync visualizer** (server-truth vs client-view) and de-risks M4a itself.
- **COMPLETE-LEVEL / COMPLETE-UNTIL** + **FORCE-CONTENT** — skip-ahead + inject-a-set-piece for balancing/
  testing; natural extensions of the `/w /m /god /class /item` dev-command set.
- **Step-mode generation** — build the dungeon one area at a time, visualized; a generator-debugging aid.

### G.5 The decision list to put in front of Jeff

1. **Algorithm:** chained-tunneling (spike) → then which target — BSP or area-accretion (Zorbus/Brogue)?
   *(lean: accretion for the ceiling; spike first regardless.)*
2. **Transport:** seed-primary (+hash) vs full-map-primary? *(lean: full-map-primary — a tile grid is cheap
   and it deletes the determinism-discipline burden.)*
3. **Floors:** confirm lazy per-floor (kill up-front). One-way descent (A) vs persistent (B)? *(lean: A now,
   B as an easy upgrade.)* Party-descends-together gate as a committed group action — agreed?
4. **Split party (C):** defer to its own milestone unless it's a wanted feature — agreed?
5. **Dev tooling:** which Zorbus-style facilities (autoplay, seed-echo, debug minimap, complete/force) do we
   want as parking-lot items?

*Round-2 sources: Zorbus [generator docs](https://dungeon.zorbus.net/Dungeon_Generator.txt) +
[Behind the Scenes](https://www.zorbus.net/bts/); [Anderson dungeon-building algorithm](https://www.roguebasin.com/index.php?title=Dungeon-Building_Algorithm);
MP — [Vorixo seed+ack handshake](https://vorixo.github.io/devtricks/procgen/), [Barony co-op](https://www.baronywiki.online/multiplayer/barony-online-multiplayer),
[Factorio desync](https://wiki.factorio.com/Desynchronization), [Godot RNG cross-version](https://github.com/godotengine/godot/issues/27856);
persistence — [NetHack persistent level](https://nethackwiki.com/wiki/Persistent_level),
[Ascii Dreams on persistence](http://roguelikedeveloper.blogspot.com/2007/11/unangband-dungeon-generation-part-four.html),
[Never Split the Party](https://store.steampowered.com/app/711810/Never_Split_the_Party/),
[Dead Cells level design](https://deepnight.net/tutorial/the-level-design-of-dead-cells-a-hybrid-approach/).*
