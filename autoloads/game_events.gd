extends Node

## Global signal bus (CLAUDE.md "Conventions"): cross-system communication goes through
## GameEvents signals — components expose signals/methods, the parent wires them, and
## anything that must reach across the tree does it here instead of polling nodes.
##
## As systems land (commit events, roll outcomes, feedback cues) they add their past-tense
## snake_case signals here, each with a one-line comment on who emits it and who listens.
## Keep this file the single place to answer "what events exist?".
##
## M2 note: movement considered routing its glide signals through this bus and skipped it — there
## is no cross-system consumer yet (main.gd wires the referee ↔ players directly, the chat pattern),
## so a bus hop would add indirection with no second listener. Revisit when a second system needs it.

## The local player clicked a tile no path reaches (wall, out of bounds, or fully sealed off).
## Emitted by the local player's MoveInput; the game log listens ("Can't reach that.").
## LOCAL-ONLY — pure client-side UX; nothing here ever crosses the wire.
signal unreachable_tile_clicked(tile: Vector2i)

## The local player's click-to-move walk was dropped after consecutive step rejects.
## Emitted by the local player's MoveInput; the game log listens ("Stopped walking.").
## LOCAL-ONLY — the server never knew a walk existed (DESIGN §2.2.9).
signal target_walk_stopped
