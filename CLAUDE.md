# CLAUDE.md — Rogue's Oath

Structure reference for AI-assisted development. Read this before touching any file.

**Doc roles:** `DESIGN.md` is decision-led — vision, system spec, the why-appendix, and the
open questions under discussion with Jeff. This file is structure-led — rules, conventions,
and where things live. If the two conflict, **DESIGN.md is authoritative**; reconcile this
file in the same task.

**Doc policy:** this file stays under ~200 lines, permanently. It is a router, not an
encyclopedia — when a topic needs depth (networking trace, dev workflow, gotchas), it gets its
own file under `docs/` and this file gains one line saying where to look and when. Split,
don't bloat.

In one line: **Rogue's Oath** is a 2–6 player real-time co-op tile-grid roguelike — permadeath,
short runs, no turns — whose hook is the **Commitment Rule** (DESIGN §2.1): decisions are
irrevocable the moment you make them. 2D top-down, Godot 4.x, GL Compatibility renderer.

---

## Git Workflow

- Commit directly to `master`, locally. One commit per completed task, descriptive messages.
- When a GitHub remote exists (i.e. when Jeff joins development), switch to branch-per-task +
  PR-per-feature.

---

## Ground Rules

The short list — only what protects the game's identity. Everything here traces to a DESIGN.md
decision.

- **GDScript only. 2D top-down tiles only.** No C#, no 3D nodes or 3D physics.

- **Multiplayer-first, always.** Every feature is designed for and demonstrated in
  two-instance multiplayer from its first commit. No offline-only code paths, no "we'll
  network it later," no logic that assumes a single local player. If it can't be shown
  working over the wire, it isn't done. (This is why milestone Done= criteria in ROADMAP.md
  are two-instance demos.)

- **The Commitment Rule is a code invariant** (DESIGN §2.1). Every action has a duration and
  plays to completion once started; no system — including UI — may cancel, interrupt-by-input,
  or redirect a committed action. Test every mechanic AND every implementation shortcut
  against: *"does this let a player back out of a decision for free?"* If yes, redesign.

- **Networking: server-authoritative intent → verdict, event-sync only** (DESIGN §2.5).
  Clients send commit requests; the server adjudicates and stamps duration/outcome. Gameplay
  state replicates as discrete commit events (`glide_to`, `attack`, `use_item`) — per-frame
  position or input streaming is **banned**, and `MultiplayerSynchronizer` is not used for
  gameplay state. A local "commit sent" cue acknowledges input receipt ONLY; the commitment
  itself begins at the server's verdict (DESIGN §2.2.8) — the client never predicts the
  outcome in either direction. Gameplay-affecting values are always read server-side from
  shared config; never adjudicate from a client-side value.

- **Designer-editable by default.** Game content and tuning live in **custom Resources with
  @export variables** — monsters, items, actions, speed tiers, drop tables — so a non-coder
  can create and balance without touching code. Adding content should mean "add a `.tres`
  file," not "write a script." A GUI editor for these resources is a future idea (not
  scheduled — don't start building it); design every resource as if it already exists: clean,
  self-describing fields with units, no magic numbers buried in scripts.

- **MWF reuse boundary.** Networking plumbing comes from
  `../Magick With Friends/framework/` (local sibling project):
  - *May lift near-verbatim:* `autoloads/network_manager.gd` (transport contract — it stays
    the ONLY file that touches ENet or any future transport), the GameManager config /
    player-name pattern, the main-menu host/join UI, the dev console (`ui/console/`).
  - *Reimplement, don't copy:* session flow (MWF `main.gd`) — rebuild from the DESIGN spec,
    preserving four behaviors: `peer_ready` RPC with duplicate-spawn guard, capacity
    spawn-gate with kick backstop, host-left UX, peer-disconnect cleanup.
  - ***Banned:*** `player_input_synchronizer_component.gd` and `remote_visual_smoother.gd` —
    both stream continuous per-frame state, which contradicts the event model above. If MWF
    is ever unavailable, the rationale stands on its own: nothing that syncs state every
    frame belongs in this codebase.

- **Feedback rule** (DESIGN §2.3.4 + §2.2.8). Every distinct roll outcome and every rejected
  commit gets a distinct sound + visual + combat-log line. "The roll failed" must never be
  confusable with "my input didn't register."

---

## Conventions

Consistency, not law:

- Component pattern: one responsibility per node; components never reach up to their parent —
  they expose signals/methods, the parent wires them. Cross-system communication goes through
  a `GameEvents` autoload's signals. Autoloads are declared in `project.godot` — check what
  exists before adding one.
- Architecture boundary (v0.5.2): the universal entity contract (id, tile, glide, cues, name)
  lives in the `Entity` base class; behavior that varies or is optional is a component child;
  authoritative state (HP, occupancy) lives in the referees, never on replicated nodes.
- Naming: `snake_case.gd` scripts, `PascalCase` classes/nodes, past-tense `snake_case`
  signals (`glide_committed`), exported vars with units (`glide_beats`, `beat_sec`).
- Script order: `extends` → signals → `@export` → `@onready` → private vars → lifecycle
  (`_ready`/`_input`/`_process`) → public methods → private methods → RPCs grouped at bottom.
- RPC shapes: client→host `@rpc("any_peer", "call_remote", "reliable")` with a
  `get_remote_sender_id()` check; host→all `@rpc("authority", "call_local", "reliable")`.
- Scenes/scripts referenced in code use `preload("uid://...")`, never string paths (brand-new
  scenes may use paths until the editor assigns a uid). Never hand-modify UIDs in `.tscn` /
  `.gd.uid` files.
- For engine behavior, check version-current Godot docs before inventing a workaround —
  a failed "this should be trivial" fix is the trigger to research, not to add complexity.
  Local ground truth: the Godot 4.7-stable class reference lives at `../godot-ref/doc/classes/`
  and `../godot-ref/modules/*/doc_classes/` — grep it whenever unsure about an API.
- Build versioning: `application/config/version` in project.godot is the single source of
  truth (kept in step with the DESIGN changelog version); the menu shows it and startup
  prints it. Exports are `C:/Users/Public/Downloads/rogues_oath_v<version>.exe` — always
  pass the explicit absolute path to `--export-release` (the preset-path form can silently
  no-op) and verify LastWriteTime after. Bump the version in the same commit that adds the
  changelog entry.

---

## Assets

`assets/32rogues/` — 2D roguelike sprite tileset (tiles, monsters, items, rogues, animals,
animated tiles), committed to the repo with its `LICENSE.txt`. Placeholder-to-possibly-final:
use it for all prototyping; re-check the license terms before any public release.

---

## Status

- Current status + the milestone chain live in **`ROADMAP.md`** — read it at session start;
  update its checkboxes in the milestone's final commit.
- If **`HANDOFF.md`** exists, a milestone is mid-flight — read it right after ROADMAP.md.
  It records in-flight state only and is deleted in the milestone's final commit.
