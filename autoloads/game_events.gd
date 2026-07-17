extends Node

## Global signal bus (CLAUDE.md "Conventions"): cross-system communication goes through
## GameEvents signals — components expose signals/methods, the parent wires them, and
## anything that must reach across the tree does it here instead of polling nodes.
##
## No signals yet. As systems land (commit events, roll outcomes, feedback cues) they add
## their past-tense snake_case signals here, each with a one-line comment on who emits it
## and who listens. Keep this file the single place to answer "what events exist?".
##
## M2 note: movement considered routing its glide signals through this bus and skipped it — there
## is no cross-system consumer yet (main.gd wires the referee ↔ players directly, the chat pattern),
## so a bus hop would add indirection with no second listener. Revisit when a second system needs it.
