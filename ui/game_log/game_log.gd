extends CanvasLayer

## Combined chat + combat log, bottom-left of the 640x360 base viewport. Two jobs:
##  1. Render events from NetEvents (chat now; combat-log lines from roll outcomes later).
##  2. Own the chat input box — a self-contained focus flow that never violates the
##     Commitment Rule (chat commits nothing, cancels nothing).
##
## FOCUS RULE (documented here because this file is the reason it exists): movement input IS
## gated on `get_viewport().gui_get_focus_owner()` being a LineEdit/TextEdit — i.e. "is the
## player typing in the chat box?". There is deliberately NO global is_chatting flag; the focused
## control IS the single source of truth. Keep it that way.

## Ring cap on stored log lines. RichTextLabel keeps every paragraph forever otherwise; at
## chat + combat volume across a run that grows unbounded, so we drop the oldest past this.
@export var max_lines: int = 200

## EXPAND (v0.37.0, Jon's legibility ask). TWO multipliers, deliberately different: the BOX grows by
## `expanded_size_scale` and the TEXT by the smaller `expanded_font_scale`, so expanding shows MORE LINES
## rather than the same lines drawn larger. One shared multiplier would just magnify the same three rows.
##
## Exported so the feel is dialable in the inspector without a code edit (the designer-editable ground
## rule); the ratio between them is the thing worth tuning, not either number alone.
@export var expanded_size_scale: float = 2.0
@export var expanded_font_scale: float = 1.5

@onready var _panel: PanelContainer = $Panel
@onready var _log: RichTextLabel = $Panel/VBox/Log
@onready var _input: LineEdit = $Panel/VBox/Input
@onready var _expand_button: Button = $Panel/VBox/Header/Expand

# Expand state + the AUTHORED baseline it scales from, captured once in _ready. Captured rather than
# hardcoded so the .tscn stays the single source of truth for the unexpanded size/fonts — retune the
# scene and both states follow. SESSION-ONLY by Jon's call (no prefs store exists; parked in the plan).
var _expanded: bool = false
var _base_width: float = 0.0
var _base_height: float = 0.0
var _base_log_font: int = 0
var _base_input_font: int = 0
var _base_button_font: int = 0

# The Players container, HANDED IN by main.gd via set_players() (v0.28.0, the HUD's blessed injection
# pattern — see ui/hud/hud.gd: a UI component is GIVEN its containers, it NEVER climbs with get_parent()).
# Read for exactly one thing: OUR OWN player's tile, so the banter arm can gate a bark on earshot. Null
# until injected (and if anything ever instantiates this log without wiring it), which the gate treats as
# "no tile to measure from — print".
var _players: Node2D = null
# Our own peer id, cached at injection like the HUD caches it. Peer ids survive respawn, so this never
# goes stale within a session.
var _own_id: int = 0


func _ready() -> void:
	_input.text_submitted.connect(_on_input_submitted)
	# Cleanup lives on editing_toggled, not an Esc key branch: a focused LineEdit consumes
	# ui_cancel in its own gui_input before _unhandled_input ever sees it (verified in engine
	# source), and unedit() does NOT release focus in 4.x. editing_toggled(false) fires for Esc
	# and send — NOT for a world click: a world click moves GUI focus nowhere on its own (no
	# other Control takes it), which used to wedge the movement gate (gui_get_focus_owner) after
	# typing. The world-click release lives in MoveInput._unhandled_input (gui_release_focus,
	# wire-test fix 2026-07-18); that external release ends editing and lands HERE as
	# editing_toggled(false). Editing-end KEEPS the draft (deliberate — a click that stops or
	# redirects a walk, or an accidental Esc, must never eat a half-written message; refocus with
	# Enter and it's still there). SEND is the only path that clears the text.
	_input.editing_toggled.connect(_on_editing_toggled)
	NetEvents.event_received.connect(_on_event_received)
	# The referee's refusals surface HERE (DESIGN §2.3.4: a rejection must never be silent —
	# the sender sees why their message vanished). Only the sender's instance receives these.
	NetEvents.intent_rejected.connect(_on_intent_rejected)
	# Local click-to-move UX from the bus (§2.2.9 — client-side only, nothing crossed the wire):
	# an unreachable click and a dropped walk both get a line, so neither is ever a silent no-op.
	GameEvents.unreachable_tile_clicked.connect(func(_tile: Vector2i): add_line("Can't reach that."))
	GameEvents.target_walk_stopped.connect(func(): add_line("Stopped walking."))
	# EXPAND (v0.37.0): capture the authored baseline BEFORE anything can scale it, then wire the toggle.
	# The Panel is anchored to the BOTTOM-LEFT (anchor_top/bottom 1, grow_vertical 0), so its size is
	# expressed as offset_right (width from the left edge) and offset_top (NEGATIVE height up from the
	# bottom) — growing the box means pushing those two out, and the corner stays pinned for free.
	_base_width = _panel.offset_right - _panel.offset_left
	# bottom minus top, with both negative (offsets from the bottom edge): -8 − (−80) = 72.
	_base_height = _panel.offset_bottom - _panel.offset_top
	# maxi(…, 1) on every captured font: get_theme_font_size returns 0 when a node has neither an override
	# nor a resolved theme entry, and add_theme_font_size_override(…, 0) does NOT mean "0px" — 0 is the
	# DISABLE sentinel, so the control would silently fall back to the project theme's game-sized type.
	# The .tscn authors all three today (6 / 6 / 8), so this floor is defence against a future scene edit
	# quietly turning the toggle into a no-op rather than a live bug.
	_base_log_font = maxi(_log.get_theme_font_size("normal_font_size"), 1)
	_base_input_font = maxi(_input.get_theme_font_size("font_size"), 1)
	_base_button_font = maxi(_expand_button.get_theme_font_size("font_size"), 1)
	_expand_button.pressed.connect(_toggle_expand)
	_apply_expand()


## Flip the chat window between authored size and expanded (v0.37.0).
##
## THE BUTTON MUST NEVER TAKE FOCUS (focus_mode 0 in the .tscn). This file's header block states the rule
## the whole movement gate rests on: a focused LineEdit/TextEdit IS "the player is typing", and MoveInput
## refuses movement while one exists. A focusable Button here would not trip that gate itself, but it
## would leave GUI focus parked inside this panel after a click, which is exactly the wedge the
## world-click release exists to undo. Not taking focus at all keeps the invariant trivially true.
func _toggle_expand() -> void:
	_expanded = not _expanded
	_apply_expand()


## Apply the current expand state to the box and the three font overrides. Written as an idempotent
## APPLY (rather than a toggle that mutates in place) so it can be called from _ready for the initial
## paint and from the toggle, with no drift between the two paths and no compounding on repeated calls —
## every value is derived from the captured baseline, never from the current one.
func _apply_expand() -> void:
	var size_scale := expanded_size_scale if _expanded else 1.0
	var font_scale := expanded_font_scale if _expanded else 1.0
	# Grow right and UP from the pinned bottom-left corner (see the anchor note in _ready).
	_panel.offset_right = _panel.offset_left + _base_width * size_scale
	_panel.offset_top = _panel.offset_bottom - _base_height * size_scale
	_panel.custom_minimum_size = Vector2(_base_width * size_scale, _base_height * size_scale)
	# RichTextLabel carries TWO sizes (bbcode bolds the speaker's name in a chat line) — both must move or
	# an expanded log would draw its names at the old size.
	_log.add_theme_font_size_override("normal_font_size", int(round(_base_log_font * font_scale)))
	_log.add_theme_font_size_override("bold_font_size", int(round(_base_log_font * font_scale)))
	_input.add_theme_font_size_override("font_size", int(round(_base_input_font * font_scale)))
	# The button rides the FONT scale, not the size scale: it is text, and at 2x it would crowd the header
	# row it shares with nothing else.
	_expand_button.add_theme_font_size_override("font_size", int(round(_base_button_font * font_scale)))
	# States what a PRESS WILL DO, not what the current state is — a button that names its own state reads
	# as a status readout you cannot act on.
	_expand_button.text = "-" if _expanded else "+"


# Focus flow lives here, not on the LineEdit, so the log owns "am I typing?" end-to-end.
# Enter while unfocused grabs the input; the send/cancel side is handled by text_submitted and
# editing_toggled (wired in _ready). Handled (not _input) so a focused LineEdit consumes its
# own keys first — we only see Enter when nothing else wanted it.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and not _input.has_focus():
			# In the HUD's tiny-dev-window fallback the docked log Panel is HIDDEN; grabbing focus on a
			# hidden LineEdit silently SUCCEEDS and wedges movement (the gate then sees a focused LineEdit
			# forever — empirically verified). Skip entirely when not visible — and do NOT consume the
			# Enter either, so it stays available to whatever else might want it.
			if not _input.is_visible_in_tree():
				return
			_input.grab_focus()
			get_viewport().set_input_as_handled()

# ── Public methods ────────────────────────────────────────────────────────────

## Reparent this log's Panel into the given HUD slot (v0.12.0, called once at HUD init by main.gd). The
## GameLog CanvasLayer stays the script/signal holder; only its Panel Control moves to DRAW inside the
## HUD's left column. Full-rect in the slot, min-size cleared so it can't overflow the narrow column.
## After this the Panel lives UNDER THE HUD, not this CanvasLayer — the @onready refs into it (_panel,
## _log, _input) resolved in _ready before the move, so they survive the reparent.
func dock_into(slot: Control) -> void:
	_panel.reparent(slot, false)
	_panel.custom_minimum_size = Vector2.ZERO
	_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Hand the log the $Players container (v0.28.0, called once by main.gd right after it instantiates this
## node). Mirrors HUD.set_players exactly: the component is GIVEN the node and caches our own peer id — it
## never climbs the tree to find either. Used only to resolve OUR OWN player's tile for the banter earshot
## gate; no membership signals are needed, because the gate reads the node fresh at each bark.
func set_players(players: Node2D) -> void:
	_players = players
	_own_id = multiplayer.get_unique_id()


## Append one PLAIN-TEXT line — the input is escaped here at the sink, so callers never worry
## about a name or reason containing bbcode. Every system line (join/left/reject) flows through
## here. The chat renderer is the one exception: it composes markup and uses _append_markup.
func add_line(text: String) -> void:
	_append_markup(_escape_bbcode(text))

# ── Private methods ───────────────────────────────────────────────────────────

# Append an already-composed markup line (bbcode intended to render) and enforce the ring cap.
# The ONLY caller that legitimately passes live markup is the chat renderer, which escapes each
# field first and wraps the escaped pieces (escape-then-wrap) — plain-text callers go through
# add_line, which escapes for them. append_text is fine at chat volume (if combat spam ever
# chafes on the string rebuilds, revisit — e.g. batch or switch to add_text).
func _append_markup(line: String) -> void:
	_log.append_text(line + "\n")
	# Trim straight off get_paragraph_count() — no mirrored counter to drift. The +1 accounts
	# for the trailing empty paragraph the final "\n" leaves. no_invalidate=true is safe because
	# every line is self-contained (no wraps spanning removed paragraphs), making this O(1).
	while _log.get_paragraph_count() > max_lines + 1:
		_log.remove_paragraph(0, true)


func _on_input_submitted(text: String) -> void:
	var trimmed := text.strip_edges()
	# Empty/whitespace: just drop focus, send nothing (no wasted intent, no empty chat event).
	if trimmed.is_empty():
		_input.clear()
		_input.release_focus()
		return
	# Slash-command interception (v0.10.0 dev commands). The ONE clean client entry point (this file
	# already owns "am I typing?"): a leading "/" is a dev command, NEVER chat — parse it locally and
	# either render /help here or submit a dev_command intent the host adjudicates + broadcasts. It clears
	# + releases focus exactly like a sent message, so the focus/movement-gate flow is unchanged; only the
	# wire payload differs (an intent, not a chat event). A slash never reaches submit_intent("chat", ...).
	if trimmed.begins_with("/"):
		_handle_slash_command(trimmed)
		_input.clear()
		_input.release_focus()
		return
	# The host still re-validates and clamps server-side — this send is a request, not a truth.
	NetEvents.submit_intent("chat", {"text": text})
	_input.clear()
	_input.release_focus()


## Parse a "/..." dev command and dispatch it (v0.10.0). Strip the leading "/", split on whitespace, and
## LOWERCASE every token (so weapon/field/class names and the command itself are case-insensitive — the
## host command table then takes precedence over the bare-weapon alias, e.g. "/w" beats a weapon literally
## named "w"). First token = command, the rest = args. "/help" renders locally (the command list is client
## knowledge — no wire); everything else submits a dev_command intent {cmd, args} the host validates,
## adjudicates, and broadcasts a host-composed log line for. An empty command (a bare "/") is ignored.
func _handle_slash_command(text: String) -> void:
	var tokens := text.substr(1).split(" ", false)
	if tokens.is_empty():
		return
	var lowered: Array[String] = []
	for t in tokens:
		lowered.append(t.to_lower())
	var cmd: String = lowered[0]  # indexing a typed Array returns Variant at parse time — annotate
	var args := lowered.slice(1)
	if cmd == "help":
		_render_help()
		return
	NetEvents.submit_intent("dev_command", { "cmd": cmd, "args": args })


## Render the /help command list LOCALLY (v0.10.0) — it never crosses the wire, so it appears only in the
## asker's own log. DERIVES from data (v0.10.1): the /w and /m field lists come from the shared GameManager
## allowlist consts (the same ones the DevCommands validator enforces), and the class list from
## GameConfig.class_roster display_names — so the help can never drift from what the host actually accepts.
func _render_help() -> void:
	add_line("Dev commands (any peer):")
	add_line("  /w <weapon> [%s] <value|reset>" % "|".join(PackedStringArray(GameManager.DEV_WEAPON_FIELDS)))
	add_line("  /<weapon> <value>  — sets damage_min AND damage_max (collapses the band to fixed damage)")
	add_line("  /m <monster> <%s> <value|reset>" % "|".join(PackedStringArray(GameManager.DEV_MONSTER_FIELDS)))
	add_line("  /god  — toggle your own invulnerability")
	add_line("  /class <%s>" % "|".join(_dev_class_names()))
	add_line("  /config <%s>  — apply a preset test loadout" % "|".join(PackedStringArray(GameManager.CONFIG_PRESETS.keys())))
	add_line("  /ab <ability> <field> <value|reset>  — tune an ability .tres (v0.27.0; slug names: shield_bash)")
	add_line("  /stun [me|<monster>] [beats]  — apply a stun (default 3 beats)")
	add_line("  /root [me|<monster>] [beats]  — apply the ROOTED condition: no movement, attacks still work (default 30)")
	add_line("  /ai  — toggle utility-AI score debug in the F3 overlay")
	add_line("  /stamina  — toggle the stamina experiment (v0.24.1; /mp still works)")
	add_line("  /winded  — toggle 0-stamina hard stop vs slow crawl (both sides, v0.24.6)")
	add_line("  /mi <id> <field|hp|stamina|stun|kill|reset> [v]  — tune ONE monster instance (v0.25.0)")
	add_line("  /snapshot  — broadcast the tuning-truth snapshot (the ` panel's refresh)")
	add_line("  press ` (backtick) — the DEBUG TUNING PANEL: all of the above as a GUI")
	add_line("  /help  — this list")


## The class-name list for /help, derived from GameConfig.class_roster display_names at render time (never
## a hand-synced literal), so a class added/removed/renamed in the roster .tres shows correctly with no code edit.
func _dev_class_names() -> PackedStringArray:
	var names := PackedStringArray()
	for c in GameManager.config.class_roster:
		if c != null:
			names.append(c.display_name)
	return names


# Editing ended (Esc, or the external world-click release from MoveInput). Release focus so the
# movement gate (gui_get_focus_owner) sees no focused LineEdit — but KEEP the draft: the only
# way to stop/redirect a standing walk is a click, and that click must never destroy a
# mid-composition message (GLM review, 2026-07-18). Send (_on_input_submitted) is the only
# clear. See _ready for why this lives here rather than on an Esc key branch.
func _on_editing_toggled(toggled_on: bool) -> void:
	if not toggled_on:
		_input.release_focus()


func _on_event_received(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	match str(event.get("action", "")):
		"chat":
			# Escape BOTH fields BEFORE composing the bbcode line. Future name-coloring wraps color
			# tags around the ESCAPED name (escape-then-wrap), so a name containing "[" can never
			# inject markup into the log.
			var display_name := _escape_bbcode(str(data.get("name", "")))
			var body := _escape_bbcode(str(data.get("text", "")))
			_append_markup("[b]%s[/b]: %s" % [display_name, body])
		"attack":
			# One combat-log line per landed/whiffed attack (§2.3.4 — every distinct outcome its own
			# line). The free-attack (attack-of-opportunity) case folds in here as kind "free". Names
			# are server-resolved but STILL go through add_line's sink escape — the file's rule is
			# escape-at-render regardless of source, no "trusted" bypass.
			_log_attack(data)
		# (v0.28.0: the "windup" arm is GONE — Jeff's third batch: "nothing needs to be written in
		# the combat log when someone winds up or is about to attack." Its one line ("X winds up...")
		# fired on every melee telegraph, every ability-strike telegraph AND every bow draw — the shoot
		# path posts the same `windup` event (combat_referee._validate_shoot) — so at fight volume it was
		# most of the log.
		#
		# ONLY THE LOG ARM WENT. The `windup` EVENT IS ALIVE and load-bearing: main.gd's windup handler
		# drives the coil + white flash + telegraph sound, the weapon rig's raised pose rides it (and is
		# handed over BY the later play_swing), and the whole ranged path telegraphs its DRAW through it.
		# Do NOT "clean up" the event believing it dead — its surviving tells are visual and audible,
		# which is exactly why the text could go.
		#
		# Four cases lose their line: the monster melee telegraph, the player's own melee windup, the
		# ability-strike telegraph, and the bow draw. The bow draw is the likeliest to come back — and MORE
		# so since v0.39.0, which removed its sound at Jon's request: its only remaining tell is now the
		# rig's skyward raise, so a draw you cannot see is a draw you get no warning of at all. The cheap
		# restore is a player-initiated-ONLY variant of the line, not this whole arm.
		"died":
			# Death line (§2.3.4). The dying entity's OWN client gets a second-person line so a
			# player knows it was them (their node is already gone — this is the spectate placeholder,
			# Q1). entity_id is the peer/monster id; a positive one matching us is our own player.
			if int(data.get("entity_id", 0)) == multiplayer.get_unique_id():
				add_line("You died.")
			else:
				add_line("%s dies." % str(data.get("name", "")))
		"dev_reset_round":
			# The dev round-reset outcome (v0.9.4 — was the anonymous host-authored "round_reset"; now
			# rides the intent pipe so a CLIENT F5 resets too, and NAMES the presser). One distinct line on
			# BOTH peers' logs — the ONE reset marker (feedback rule §2.3.4) — never confusable with the
			# "X joined." spam the respawn also produces. Name goes through add_line's sink escape.
			add_line("— Round reset (%s) —" % str(data.get("name", "Someone")))
		"set_tempo":
			# The host's tempo referee outcome (§2.8.3): an accepted set_tempo intent broadcasts under
			# its own action name (like "chat"). One line naming who changed it, on every peer, so a live
			# tempo change is legible in the log alongside the always-on readout. Names go through
			# add_line's sink escape like every other system line.
			var beat := float(data.get("beat_sec", GameManager.explore_beat_sec))
			add_line("Tempo: %s — set by %s." % [GameManager.tempo_log_text(beat), str(data.get("by", "someone"))])
		"set_tactical_tempo":
			# The tactical dial's twin of set_tempo (v0.9.2 groundwork): one line naming who changed it,
			# on every peer, so the second dial is legible in the log alongside the always-on readout.
			var tactical := float(data.get("beat_sec", GameManager.tactical_beat_sec))
			add_line("Tactical: %s — set by %s." % [GameManager.tempo_log_text(tactical), str(data.get("by", "someone"))])
		"dev_spawn_goblin":
			# The F6 dev-summon outcome (v0.9.2): one line on every peer naming who summoned, so the spawn
			# is legible in the log (feedback rule §2.3.4). Name goes through add_line's sink escape.
			add_line("%s summoned a goblin." % str(data.get("name", "Someone")))
		"swap_weapon":
			# The weapon-swap referee outcome (M3.7, §2.3.7): one line naming who drew which weapon, on
			# every peer, so a live swap is legible in the log. Names go through add_line's sink escape.
			add_line("%s draws the %s." % [str(data.get("by", "Someone")), str(data.get("weapon", "weapon"))])
		"dev_command":
			# A host-adjudicated dev command's outcome (v0.10.0, /w & /m & /god). The HOST composed the
			# whole line (who + what changed) — the client never trusts its own parse for the log — and every
			# peer renders it, so a live tuning/god change is legible party-wide (like set_tempo/swap_weapon).
			# The line goes through add_line's sink escape like every other system line.
			add_line(str(data.get("line", "")))
		"class_changed":
			# The /class referee outcome (v0.10.0): one line naming who became which class, on every peer, so
			# a live class change is legible in the log — the mirror of swap_weapon (state adopted by main.gd's
			# handler from this same event). Names/classes go through add_line's sink escape.
			# weapon_skipped (v0.17.1 review #5): the class switched but its loadout equip was SKIPPED because
			# the player was mid-commit — append a distinct clause so the "success" line doesn't mislead (the
			# equip is recoverable: Tab to equip). Present-only flag, so a normal switch reads exactly as before.
			var class_line := "%s becomes a %s." % [str(data.get("by", "Someone")), str(data.get("class", "class"))]
			if bool(data.get("weapon_skipped", false)):
				class_line += " (weapon not equipped — busy; Tab to equip.)"
			# gear_skipped (v0.27.0): the same clause for the class's STARTING BODY ARMOR, which the /class
			# validator reconciles beside the weapon and skips for its own reasons. Its own flag and its own
			# clause, because the two can skip independently and a merged "gear not equipped" would not tell
			# you WHICH — and unlike the weapon there is no Tab shortcut to recover it.
			# v0.27.1: distinct skips, distinct sentences (§2.3.4). v0.28.1 dropped the fourth, "bag full":
			# /class no longer puts the old piece in your bag (it is discarded), so no bag can refuse the swap
			# and the reason is unproducible. The default arm still catches any unknown string.
			if bool(data.get("gear_skipped", false)):
				match str(data.get("gear_skip_reason", "busy")):
					"stunned":
						class_line += " (armor not equipped — stunned; re-run /class once it wears off.)"
					"dead":
						class_line += " (armor not equipped — you're dead.)"
					_:
						class_line += " (armor not equipped — busy; re-run /class when free.)"
			add_line(class_line)
		"banter":
			# Goblin banter (v0.24.4): the spoken line also lands in the log, quoted, so a bark you
			# missed on screen survives in the record. Host-authored text, escaped anyway (belt).
			# EARSHOT GATE (v0.28.0, Jon: "gate ALL barks by distance, not just idle"): skip the line when the
			# speaker is further than GameConfig.banter_earshot_tiles from our own player. The OVERHEAD label
			# is deliberately NOT gated (main.gd) — it floats over the speaker, so distance already hides it.
			if not _bark_within_earshot(data):
				return
			add_line("%s: \"%s\"" % [_escape_bbcode(str(data.get("name", "Goblin"))),
					_escape_bbcode(str(data.get("text", "")))])
		# (v0.27.0: the "stamina" arm is GONE. Its one line — "Exhausted — you can barely move." — fired on
		# every pool empty, i.e. on EVERY tactical step now that the pool is a single point, so it spammed the
		# log with a sentence the body's own cues already tell (the recovery bar, the transparency, the drip or
		# the distinct "winded" reject). Jeff's second playtest verdict. The `stamina` EVENT itself is untouched
		# — main.gd still drives the HUD pips from it; only this log line went away.)
		"pace_changed":
			# The pace-flip cue (Tactical Zones v1, §2.8.7). A TWO-SIGNAL cue — tempo-bar emphasis + this
			# log line — and deliberately NO sound: pace flips are a two-signal cue by audio-grammar choice
			# (v0.6.2, "hit + swing are the only combat noises"), so §2.3.4's SOUND prong applies to combat
			# OUTCOMES, not to a pace-mode change. SEED events (a spawn / respawn / join re-seeding the bar)
			# carry seed:true and get NO line here — a spawn is not a mode change, so this marker stays
			# reserved for genuine FLIPS (hysteresis keeps those infrequent — a real mode change, not churn).
			# OWN-player only — a flip for someone else isn't our line (mirrors the "You died." self-filter).
			if bool(data.get("seed", false)):
				return
			if int(data.get("entity_id", 0)) == multiplayer.get_unique_id():
				var tactical := str(data.get("pace", "explore")) == "tactical"
				add_line("— Tactical pace —" if tactical else "— Explore pace —")
		"projectile_ended":
			# The arrow's terminal outcome (v0.17.0, §2.3.4 — a distinct line per outcome). A HIT is already
			# logged by the `attack` event (kind "arrow"), so only block/spent surface here. A "spent" shot
			# that grazed a skipped ally names them (the referee stamps target_name) so the near-miss reads.
			match str(data.get("outcome", "")):
				"blocked":
					add_line("The arrow shatters on the wall.")
				"spent":
					if data.has("target_name"):
						add_line("The arrow sails past %s." % str(data.get("target_name", "")))
					else:
						add_line("The arrow flies wide.")
		"item_picked_up":
			# A completed walk-over pickup (v0.18.0 chunk B, §2.3.4 — a distinct line per outcome). Party-wide:
			# everyone sees who grabbed what. Name + item flow through add_line's sink escape like every line.
			add_line("%s picks up the %s." % [str(data.get("name", "Someone")), str(data.get("item", "item"))])
		"item_pickup_full":
			# A pickup BLOCKED by a full bag (v0.18.0 chunk B, §2.3.4 — never a silent swallow). SENDER-ONLY:
			# only the mover's OWN instance renders it (the "You died." self-filter precedent) — a teammate's
			# full bag isn't our line, and v1 has no unicast pipe, so the broadcast event self-filters here.
			if int(data.get("entity_id", 0)) == multiplayer.get_unique_id():
				add_line("(your bag is full)")
		"item_pickup_available":
			# A non-potion ground item the mover just STEPPED ON but did not auto-collect (v0.21.0, §2.3.4 —
			# never a silent swallow). Only potions autopickup now; everything else is left lying there, so this
			# line is both the outcome feedback AND the discoverability affordance for the G key. SENDER-ONLY,
			# the same self-filter as item_pickup_full above (a teammate's ground find isn't our line, and v1 has
			# no unicast pipe, so the broadcast event filters here). Deliberately worded NOTHING like the bag-full
			# line — that one refuses, this one invites — so the two outcomes are never confusable. Item name
			# flows through add_line's sink escape like every line.
			if int(data.get("entity_id", 0)) == multiplayer.get_unique_id():
				add_line("a %s lies here — press G to pick up" % str(data.get("item", "item")))
		"item_used":
			# A committed item use (v0.18.0 chunk C, §2.3.4 — the telegraph line). Party-wide: everyone sees
			# who drank what, at COMMIT (the heal, if any, lands on its own `heal` event when the window ends —
			# a distinct outcome, distinct line). The "..." mirrors the windup "draws the..." telegraph shape.
			# Name + item flow through add_line's sink escape like every line.
			add_line("%s drinks the %s..." % [str(data.get("name", "Someone")), str(data.get("item", "item"))])
		"blink":
			# FIZZLED BLINKS ONLY (v0.42.0). A SUCCESSFUL blink is the most legible event in the game — a body
			# vanishes and reappears somewhere else — so narrating it would be noise, and Shadow Step has
			# deliberately shipped without a log line since v0.26.0. This arm exists for the one blink outcome
			# that is INVISIBLE: a blink potion drunk with nowhere legal to land. §2.3.4's rule is that a
			# distinct outcome gets a distinct line, and "the potion did nothing" is exactly the outcome that
			# would otherwise be indistinguishable from a bug. Gating on `fizzled` is what keeps Shadow Step's
			# logging byte-identical to before.
			if bool(data.get("fizzled", false)):
				add_line("The %s fizzles — nowhere to go." % str(data.get("item", "potion")))
		"equip_item":
			# A committed weapon / body-armor equip (v0.19.x loot, §2.3.4 — a distinct line). Party-wide:
			# everyone sees who armed themselves with what. Names flow through add_line's sink escape. On the
			# BAG path the swapped-out thing is not named (it went back into the freed slot, not lost — keep
			# the line terse).
			# v0.27.1 — TWO more shapes, both from /class's loadout reconcile, each read distinctly:
			#  STRIP:     an EMPTY `equipped` means the new class wears nothing, so the slot was cleared.
			#             "equips the ." was the alternative, which is not a sentence.
			#  DISCARDED: a present `discarded` names the piece the class swap DESTROYED (v0.28.1, Jon's
			#             ruling) — it replaced v0.27.1's bag stow, and keeps that line's PARENTHETICAL
			#             SAME-LINE structure so every equip outcome still reads with one uniform shape.
			#             §2.3.4: the loss is deliberate but must never be SILENT, so the log names it.
			#             MUTUALLY EXCLUSIVE with `returned` BY CONSTRUCTION: /class is the only producer
			#             of `discarded` and no longer sets `returned` at all, while the bag-equip path
			#             (InventoryReferee._validate_equip_item / _equip_body) sets `returned` and never
			#             `discarded` — so this branch cannot label a recoverable bag return as a
			#             destruction. A future path emitting BOTH would be a contradiction, not a shape
			#             to quietly support here.
			var who := str(data.get("name", "Someone"))
			var equipped_thing := str(data.get("equipped", ""))
			var gear_line := ("%s takes off their armor." % who) if equipped_thing.is_empty() \
					else ("%s equips the %s." % [who, equipped_thing])
			var discarded_thing := str(data.get("discarded", ""))
			if not discarded_thing.is_empty():
				gear_line += " (The %s is discarded.)" % discarded_thing
			add_line(gear_line)
		"heal":
			# A resolved heal (v0.18.0 chunk C, §2.3.4 — a distinct recovery line with the running HP readout,
			# the twin of an `attack` line's "for N (hp/max)"). Party-wide so recovery is legible in the log.
			# Name goes through add_line's sink escape.
			add_line("%s recovers %d HP (%d/%d)." % [
				str(data.get("name", "Someone")), int(data.get("amount", 0)),
				int(data.get("hp_after", 0)), int(data.get("target_max", 0))])
		"heal_cast":
			# A monster's heal CHANNEL starting (§2.3.4, v0.19.4 — a distinct telegraph line, the healer's twin
			# of "winds up..."). The LAND is the `heal` line above. Names flow through add_line's sink escape.
			add_line("%s channels a heal toward %s..." % [
				str(data.get("caster_name", "Someone")), str(data.get("target_name", "an ally"))])
		"status_applied":
			# A status effect landed (§2.3.4, v0.20.0 — stun). A distinct line so "it's stunned" is legible in the
			# log, not only the overhead icon. Name is server-resolved; still escaped at the add_line sink.
			# v0.26.0: "block" joins it — a raised guard is a party-visible commitment, so it gets its own line
			# (worded as a stance, never as a hit, so it can't be mistaken for the later "blocks ...'s blow!").
			match str(data.get("status", "")):
				"stun":
					add_line("%s is stunned!" % str(data.get("name", "Someone")))
				"block":
					add_line("%s raises a guard." % str(data.get("name", "Someone")))
				"rooted":
					# v0.34.0 conditions. Its own sentence, party-wide: a hard 30-beat movement lock is
					# exactly as legible-worthy as a stun, and the overhead tendrils alone would leave a
					# player wondering why the goblin stopped chasing.
					add_line("%s is rooted!" % str(data.get("name", "Someone")))
				"plagued":
					# v0.40.0. Its own sentence for the same reason the root has one: the damage arrives
					# later and on its own clock, so without a line naming the moment it started, a player
					# watching HP tick down has nothing to attribute it to.
					add_line("%s is swarmed by insects!" % str(data.get("name", "Someone")))
		"smite_cast":
			# A monster's SMITE channel starting (§2.3.4, v0.19.10 — the offensive twin of the heal channel). The
			# RED danger tile is the real telegraph; this line names whoever's standing on it at cast start (empty
			# = bare ground). The LAND is the "smites" attack line; a dodge is the "fizzles" whiff line. Escaped at sink.
			var smite_victim := str(data.get("target_name", ""))
			if smite_victim != "":
				add_line("%s begins to smite %s..." % [str(data.get("caster_name", "Someone")), smite_victim])
			else:
				add_line("%s begins channeling a smite..." % str(data.get("caster_name", "Someone")))
		"status_expired":
			# NEW ARM (v0.34.0). status_expired has broadcast since v0.20.0 with no log voice at all,
			# deliberately: a stun's end and a spent guard are ICON-ONLY endings — the icon vanishing IS the
			# tell, and a line per expiry would swell the log during a fight. That stays true; only ROOTED
			# speaks, because its end is a TACTICAL fact the party plans around ("the thing we locked down is
			# loose"), and because a root can end EARLY (break-on-damage, a blink out) in a way a watching
			# player would otherwise have to infer from the enemy simply starting to move again. Every other
			# status falls through to nothing, exactly as before.
			match str(data.get("status", "")):
				"rooted":
					add_line("The roots release %s." % str(data.get("name", "Someone")))
				"plagued":
					add_line("The swarm around %s disperses." % str(data.get("name", "Someone")))
		"targeted_cast":
			# A player's ENTANGLING-ROOTS channel starting (§2.3.4, v0.34.0 — the control twin of the smite
			# channel, phrased so it can never be read as damage). The GREEN ground tile is the real
			# telegraph; this line names whoever stands on it at cast start (empty = bare ground, which is a
			# legal and sometimes deliberate cast — you can root the tile someone is fleeing toward). The
			# LAND is the "X is rooted!" line; a dodge is the generic whiff line.
			# v0.40.0: the channel carries TWO spells now, so the sentence is chosen by the ability the
			# referee named. A generic "begins casting" for both would throw away the one line that tells
			# the party WHICH thing is about to land on whom — and roots and plague call for completely
			# different reactions. An unknown ability falls back to a neutral cast line rather than
			# mislabelling itself as roots.
			# Branch on `effect` (host-derived from the ability's payload), never on the display name — a
			# renamed spell must not silently start narrating itself as the other one. The NAME is still
			# what a future line would print; the EFFECT is what it is safe to switch on.
			var cast_victim := str(data.get("target_name", ""))
			var caster_name := str(data.get("caster_name", "Someone"))
			match str(data.get("effect", "")):
				"plague":
					if cast_victim != "":
						add_line("%s calls a swarm down on %s..." % [caster_name, cast_victim])
					else:
						add_line("%s calls a swarm — the air starts to hum..." % caster_name)
				"root":
					if cast_victim != "":
						add_line("%s begins entangling %s..." % [caster_name, cast_victim])
					else:
						add_line("%s calls the roots — the ground writhes..." % caster_name)
				_:
					if cast_victim != "":
						add_line("%s begins casting at %s..." % [caster_name, cast_victim])
					else:
						add_line("%s begins casting..." % caster_name)


## Compose the combat-log line for one `attack` event, one distinct phrasing per outcome (§2.3.4):
## a whiff ("hits nothing"), a free attack (AoO flavor), or a normal landed hit with the running HP
## readout. All names/numbers flow through add_line, which escapes at the sink.
func _log_attack(data: Dictionary) -> void:
	var attacker_name := str(data.get("attacker_name", ""))
	if bool(data.get("whiff", false)):
		# THE PAID TAIL, quoted (v0.35.0). `duration_sec` on a whiff event is exactly what
		# CombatReferee._whiff_tail_sec decided this miss owes — the one observable the
		# `whiff_recovery_beats` dial has. Without it the dial was invisible in play: Jon set it to 14,
		# saw no change, and reasonably concluded it was broken — when in fact the dial CAPS at the
		# weapon's own tail (it may only ever shorten a committed window), so any value at or above the
		# weapon's recovery is identical to the default. Naming the seconds makes "this is already the
		# full tail" and "this was cut short" different sentences instead of the same silence.
		# Suffix only, so the outcome phrasing every peer already reads is untouched.
		var tail := " (recovers %.1fs)" % float(data.get("duration_sec", 0.0))
		# A dodged SMITE (v0.19.10) gets its own line — the player stepped off the red tile in time (§2.3.4).
		if str(data.get("kind", "")) == "smite":
			add_line("%s's smite fizzles — dodged!%s" % [attacker_name, tail])
		# ESCAPED (v0.38.0): a CREATURE-targeted cast whose living target outran the caster's reach. Its own
		# sentence, because "hits nothing" would blame the caster for a miss they did not make — the target
		# won a footrace, which is the counterplay working exactly as designed and should read that way.
		elif bool(data.get("escaped", false)):
			add_line("%s gets out of reach — %s's spell fizzles.%s" % [
					str(data.get("target_name", "The target")), attacker_name, tail])
		else:
			add_line("%s's attack hits nothing.%s" % [attacker_name, tail])
		return
	var target_name := str(data.get("target_name", ""))
	# SHIELD BLOCK (v0.26.0 instants experiment): the blow connected and was turned aside. FIRST of the
	# damage-0 branches and phrased from the DEFENDER's side — the defender is who did something here (they
	# spent a guard), which is also what keeps it unconfusable with a whiff ("hits nothing") or a god no-op
	# ("no effect"). §2.3.4: three different zeroes, three different sentences.
	if bool(data.get("blocked", false)):
		add_line("%s blocks %s's blow!" % [target_name, attacker_name])
		return
	# God-mode no-op (v0.10.0): a hit that landed on an invulnerable target. A DISTINCT line (§2.3.4 —
	# never confusable with a real hit or a whiff), before the free/normal branches; the event carries
	# damage 0 + hp unchanged, so this reads "connected, no damage" not "missed".
	if bool(data.get("godded", false)):
		add_line("%s hits %s — no effect (god)." % [attacker_name, target_name])
		return
	var damage := int(data.get("damage", 0))
	var kind := str(data.get("kind", ""))
	# ZERO-DAMAGE LANDED HIT (v0.27.1): the verb line WITHOUT the "for N (hp/max)" clause. A hit that deals
	# nothing is a shipped outcome since v0.27.0 — kick authors damage 0 as a pure stun setup — and
	# "Rogue kicks Goblin for 0 (10/10)." reads as a broken hit, which is exactly the confusable feedback
	# §2.3.4 forbids. It stays a LINE (contact happened, and the stun that IS the outcome gets its own
	# "X is stunned!" line off status_applied) — it just stops reporting a number that isn't the point.
	# Placed AFTER the blocked/godded branches, which own their own distinct zeroes, and BEFORE the sneak
	# branch, because a DOUBLED zero is not a sneak attack (main.gd suppresses the popup's "!" identically).
	if damage == 0:
		_log_zero_damage_attack(data, attacker_name, target_name, kind)
		return
	# ARMOR ABSORPTION (v0.27.1, §2.3.8 + §2.3.4): the host tags a hit whose number its mitigation seam
	# actually changed and stamps the points ABSORBED. Folded into the running-HP parenthetical rather than
	# given a branch of its own, so it composes with EVERY verb below (a shaved sneak attack, a shaved
	# arrow) instead of hiding one — one line per outcome, and mitigation is finally visible in the log at
	# all. Absent on an unmitigated hit, so those lines are byte-identical to before.
	var readout := "%d/%d" % [int(data.get("hp_after", 0)), int(data.get("target_max", 0))]
	var armor_clause := ""
	if (data.get("tags", []) as Array).has("armor"):
		armor_clause = " (armor absorbs %d)" % int(data.get("absorbed", 0))
		readout += ", armor absorbs %d" % int(data.get("absorbed", 0))
	# SNEAK ATTACK (v0.11.0 as "backstab", redesigned + retagged v0.27.0): a DISTINCT line before the
	# free/normal branches (§2.3.4 — never confusable with a plain hit), driven by the "sneak" tag the
	# referee stamped when the rogue's dagger caught a FLANKED or STUNNED target. Same running-HP readout as
	# a normal hit, with "sneak-attacks" + a "!" carrying the distinct outcome. On every peer (the tag rides
	# the event).
	if (data.get("tags", []) as Array).has("sneak"):
		# A free (AoO) sneak attack keeps its free-ness visible — both outcomes are distinct cues (§2.3.4),
		# so neither may swallow the other.
		var free_prefix := "free-attack " if kind == "free" else ""
		add_line("%s %ssneak-attacks %s for %d! (%s)." % [
			attacker_name, free_prefix, target_name, damage, readout])
		return
	if kind == "free":
		# The AoO line is the one shape with no running-HP parenthetical, so the armor clause rides on its own.
		add_line("%s gets a free attack on %s — %d damage%s." % [
			attacker_name, target_name, damage, armor_clause])
		return
	if kind == "arrow":
		# A landed arrow shot (v0.17.0): a DISTINCT verb ("shoots") from a melee hit (§2.3.4), same running-HP readout.
		add_line("%s shoots %s for %d (%s)." % [attacker_name, target_name, damage, readout])
		return
	if kind == "kick":
		# A point-blank KICK (v0.17.1): a ranged weapon's wielder bumped an adjacent hostile — no melee
		# swing, so a DISTINCT verb ("kicks") from a shot or a slash (§2.3.4), same running-HP readout.
		add_line("%s kicks %s for %d (%s)." % [attacker_name, target_name, damage, readout])
		return
	if kind == "smite":
		# A landed SMITE (v0.19.10): a ranged spell hit — a DISTINCT verb ("smites"), same running-HP readout.
		add_line("%s smites %s for %d (%s)." % [attacker_name, target_name, damage, readout])
		return
	if kind == "ability":
		# A landed ACTIVE ABILITY (v0.20.0): the class-authored verb ("bashes"/"kicks"), same running-HP readout.
		# The stun (if any) is its own "X is stunned!" line off the status_applied event.
		add_line("%s %s %s for %d (%s)." % [
			attacker_name, str(data.get("verb", "hits")), target_name, damage, readout])
		return
	# A landed bump or wind-up hit, with the target's running HP after the blow.
	add_line("%s hits %s for %d (%s)." % [attacker_name, target_name, damage, readout])


## The combat-log line for a landed hit that dealt NOTHING (v0.27.1) — the verb, the target, full stop. One
## sentence per kind so the zero keeps each kind's distinct voice (§2.3.4), mirroring the branches above;
## the "free" AoO shape has no "for N" clause to drop, so it names the nothing explicitly instead. Reached
## only for a real landed hit (blocked / godded / whiff each returned with their own line already).
func _log_zero_damage_attack(data: Dictionary, attacker_name: String, target_name: String, kind: String) -> void:
	match kind:
		"free":
			add_line("%s gets a free attack on %s — no damage." % [attacker_name, target_name])
		"arrow":
			add_line("%s shoots %s." % [attacker_name, target_name])
		"kick":
			add_line("%s kicks %s." % [attacker_name, target_name])
		"smite":
			add_line("%s smites %s." % [attacker_name, target_name])
		"ability":
			add_line("%s %s %s." % [attacker_name, str(data.get("verb", "hits")), target_name])
		_:
			add_line("%s hits %s." % [attacker_name, target_name])


func _on_intent_rejected(action: String, reason: String) -> void:
	if action == "chat":
		add_line("(message not sent: %s)" % reason)
	elif action == "glide_to":
		_log_glide_reject(reason)
	elif action == "dev_command":
		# A rejected dev command (v0.10.0): unknown command, bad field, or non-number value. Surface the
		# host's reason to the SENDER only (rejects reach only the sender) so a typo is never a silent
		# no-op (§2.3.4). Distinct wording from a rejected chat/move so the three don't blur.
		add_line("(command failed: %s)" % reason)
	elif action == "shoot":
		_log_shoot_reject(reason)
	elif action == "use_item":
		_log_use_reject(reason)
	elif action == "use_ability":
		_log_ability_reject(reason)
	elif action == "equip_item":
		_log_equip_reject(reason)
	elif action == "pickup_item":
		_log_pickup_reject(reason)


# A refused move must never be silent when the cause is the world (§2.3.4): a wall/corner/occupied
# bonk gets a plain-language line here to sit alongside the sound + flash. "already moving" is the
# ONE suppressed case — it now covers BOTH mashing during a committed glide AND a third intent
# while one glides + one is held in the pipeline slot (§2.2.5 amendment): same semantic ("not
# now, you're already committed"), not a world refusal; the bonk sound/flash (fired via main.gd)
# already says so without log spam. v0.32.0 adds "busy" (a move during an IN-PLACE commitment) as the
# second suppressed case, for exactly that reason — see its arm below.
func _log_glide_reject(reason: String) -> void:
	match reason:
		"blocked":
			add_line("Blocked — a wall is in the way.")
		"corner":
			add_line("Blocked — can't squeeze through that corner.")
		"occupied":
			add_line("Blocked — someone's there.")
		"occupied_hostile":
			# Mid-commitment glide into a hostile it couldn't bump yet (pipelined, 1a v0.10.2). No line:
			# with input held the next from-idle submit becomes the bump attack, so "someone's there" would
			# misread. Silent, matching the suppressed bonk cue — the raw reason must never surface to players.
			pass
		"already moving":
			pass
		"busy":
			# v0.32.0: a move submitted DURING an in-place commitment (attack windup/recovery, cast, drink,
			# bow draw) — the referee refuses every one of them now, queued or otherwise. Suppressed for the
			# same reason "already moving" is: it is not a world refusal, it is "not now, you're already
			# committed", and the bonk sound + flash (fired via main.gd) already say so without log spam.
			# Held input re-lands the step the instant the window ends, so a line per mashed key is noise.
			pass
		"recovering":
			# v0.28.0 recovery lockout (GameConfig.recovery_locks_actions): a BUMP ATTACK refused because the
			# attacker is at 0 stamina in tactical pace. Its OWN token, never folded into "winded" — winded is
			# "you cannot MOVE", this is "you cannot ACT", and the two dials are independent (§2.3.4: one
			# sentence per outcome). Names the recovery BAR, which is the thing on screen you are waiting on.
			add_line("Still recovering — wait for the bar.")
		"rooted":
			# v0.34.0 conditions: the roots hold your feet. A WORLD refusal, so it speaks (unlike "busy" /
			# "already moving", which are your own commitment talking) — and it names the ONE thing that is
			# blocked, because everything else still works: you can still swing, shoot, cast and drink while
			# rooted, and a player who reads this as "I can't act" would stand there doing nothing.
			add_line("Rooted — you can't move!")
		"winded":
			# Hard-stop mode only (v0.24.6, /winded toggle): out of stamina AND movement is blocked.
			# Distinct from the crawl (which accepts the step slowly and never rejects) — §2.3.4.
			add_line("Winded — can't move. Stand still to recover.")
		"dead":
			# The mover was killed by an attack of opportunity mid-adjudication (decision 4, Q1
			# placeholder). Suppress the reject line — the `died` event already logged "You died.",
			# and "Move rejected (dead)" would be confusing noise on top of it.
			pass
		_:
			add_line("Move rejected (%s)." % reason)


## A refused shot (v0.17.0): the host's reasons are already player-facing sentences ("Out of range.",
## "Nothing to draw with.", "Can't shoot your own tile."), so surface them verbatim — except "busy" / "dead",
## suppressed like a move's (you're committed / gone; the bonk sound already says it, no log spam).
func _log_shoot_reject(reason: String) -> void:
	match reason:
		"busy", "dead":
			pass
		"recovering":
			# v0.28.0 recovery lockout — a raw token, not a sentence, so it gets its own arm rather than
			# falling through the verbatim catch-all below. Same wording on every pipe (§2.3.4: one cause,
			# one sentence — the reason you cannot shoot is the reason you cannot drink).
			add_line("Still recovering — wait for the bar.")
		_:
			add_line(reason)


## A refused item use (v0.18.0 chunk C) — the exact mirror of _log_shoot_reject. The host's world-facing
## reasons ("nothing in that slot", "can't use that", "unknown item") are already player-legible sentences, so
## surface them verbatim — except "busy" / "dead", suppressed like a move's/shot's (you're committed / gone; the
## bonk sound already says it, and the `died` line already covers death, so a reject line there would be noise).
func _log_use_reject(reason: String) -> void:
	match reason:
		"busy", "dead":
			pass
		"recovering":
			# v0.28.0 recovery lockout — same arm, same sentence as the shoot pipe above.
			add_line("Still recovering — wait for the bar.")
		_:
			add_line(reason)


## A refused EQUIP (v0.27.1). The `equip_item` pipe had no arm at all, so every refusal was silently
## swallowed — tolerable while the only reasons were slot-shape noise, and NOT tolerable now that a real
## rule refuses through it: an EQUIPMENT item bound for a socket that does not exist yet ("no slot for that
## yet", the §2.10 tripwire for the off-hand shield) would otherwise look like a dropped click, which
## §2.2.8/§2.3.4 forbid. Shape copied from _log_use_reject, with `stunned` suppressed too — the stun icon
## and the bonk already say it, exactly as on the ability pipe.
func _log_equip_reject(reason: String) -> void:
	match reason:
		"busy", "dead", "stunned":
			pass
		"recovering":
			# v0.28.0 recovery lockout — same arm, same sentence as the shoot/use pipes above.
			add_line("Still recovering — wait for the bar.")
		"no slot for that yet":
			add_line("There's nowhere to wear that yet.")
		_:
			add_line(reason)


## A refused PICKUP (v0.28.0). The `pickup_item` pipe had NO arm at all and was absent from main.gd's bonk
## allowlist too — i.e. a refused G press was silent on BOTH §2.3.4 channels, which is the one case that
## genuinely needed closing (a reason that already has a line but deliberately no bonk stays that way; the
## two channels are independent by design). Shape copied from _log_use_reject: the host's remaining reasons
## ("nothing to pick up") are already player-legible sentences, so they surface verbatim, while
## busy / dead / stunned stay suppressed exactly as on every other pipe.
func _log_pickup_reject(reason: String) -> void:
	match reason:
		"busy", "dead", "stunned":
			pass
		"recovering":
			add_line("Still recovering — wait for the bar.")
		_:
			add_line(reason)


## A refused ABILITY press (v0.20.0 pipe, first given a log voice in v0.26.0 with the instants experiment).
## Until now `use_ability` had no branch at all, so every refusal — no target, empty slot, and now the four
## instant-only ones — was silently swallowed, which §2.2.8/§2.3.4 forbid. Each reason gets its OWN sentence so
## none of them can be confused with another (or with a dropped keypress); `busy`/`dead`/`stunned` stay
## suppressed like every other pipe's (you're committed / gone / disrupted — the bonk and the stun icon already
## say it, and the `died` line already covers death).
func _log_ability_reject(reason: String) -> void:
	# Host-composed and carries a NUMBER ("on cooldown (12.3s)") — surface it as a sentence rather than
	# matching, so the remaining seconds reach the player (§2.3.4: distinct feedback, with the actual value).
	if reason.begins_with("on cooldown"):
		add_line("Not ready yet — %s." % reason)
		return
	match reason:
		"busy", "dead", "stunned":
			pass
		"recovering":
			# v0.28.0 recovery lockout — same sentence as every other pipe. Reached by STRIKE abilities AND by
			# the instants (Shield Block / Shadow Step): the gate sits with the stun gate, above the instant
			# dispatch, so "recovering" blocks them exactly as a stun does.
			add_line("Still recovering — wait for the bar.")
		"no target":
			add_line("Nothing in reach.")
		"no such ability":
			add_line("Nothing bound to that slot.")
		"instant abilities are disabled":
			# The experiment toggle is off. Named plainly, because in a playtest this IS the answer to
			# "why did nothing happen?" — never a generic refusal.
			add_line("Instant abilities are switched off.")
		"already blocking":
			add_line("Your guard is already up.")
		"blocked":
			# Shadow Step with a wall or a body directly behind. No cooldown was burned — say so, so the
			# player knows to turn and press again rather than assume they wasted the ability.
			add_line("No room to step back — something's behind you.")
		"no direction":
			# A never-moved body faces nowhere, so "backwards" has no meaning yet (MoveReferee.facing_of ZERO).
			add_line("Take a step first — you have no direction to step back from.")
		_:
			# MANA (v0.43.0) — a PREFIX test, exactly like the cooldown arm at the top of this function and
			# for the same reason: the host stamps the real numbers into the reason string ("not enough mana
			# (3/1)"), and reprinting them here from a client-side guess would be a second source of truth
			# that can disagree. So the host's figures are surfaced verbatim and only the sentence around
			# them is local. Handled in the fallthrough rather than as its own `match` arm because the arm
			# would have to be a literal, and the string carries data.
			if reason.begins_with("not enough mana"):
				add_line("Not enough mana %s." % reason.trim_prefix("not enough mana "))
				return
			add_line("Ability refused (%s)." % reason)


## Should a bark's LINE be printed in THIS peer's log (v0.28.0)? True when our own player is within
## GameConfig.banter_earshot_tiles (Chebyshev — the same metric and the same dial the host-side mourner and
## help-me picks use, so "12 tiles" is one shape everywhere) of the speaker's tile.
##
## THREE CASES PRINT PAST THE GATE, each deliberate:
##  1. NO OWN PLAYER (dead, or not spawned yet) — an earshot-less SPECTATOR prints EVERYTHING. A dead
##     player has no tile, so there is no honest radius to clamp to, and losing the log while watching the
##     fight you just died in is worse than overhearing a distant goblin. (A TRADEOFF Jeff can veto: a
##     spectator in a busy session hears every bark, which is the opposite of "quieter log". If he dislikes
##     it, the fix is gating from the tile you died on.)
##  2. NO / MALFORMED SPEAKER TILE — a bark from before this event carried one, or a wire value that isn't
##     a Vector2i.
##  3. WALL-SENTINEL tile on either side — tile_of_entity answers (0,0) for an untracked entity, and a
##     sentinel must NEVER silently swallow a line. (Every bark trigger today hangs off engagement / death /
##     a think beat, i.e. long after spawn, so this should be unreachable; the branch stays regardless.)
##
## The radius is read LIVE off GameManager.config, never cached at init, so `/config banter_earshot_tiles`
## is felt immediately. NOTE it is a PRESENTATION read of a client's own config copy — no adjudication
## depends on it (§2.5 is about verdicts), so a client whose host retuned the dial live may gate at the
## shipped value until it restarts. Deliberately not worth a new wire field.
func _bark_within_earshot(data: Dictionary) -> bool:
	if _players == null:
		return true
	var me := _players.get_node_or_null(str(_own_id)) as Entity
	if me == null:
		return true
	var tile_raw = data.get("tile")
	if typeof(tile_raw) != TYPE_VECTOR2I:
		return true
	var speaker_tile: Vector2i = tile_raw
	if WorldGrid.is_wall(speaker_tile) or WorldGrid.is_wall(me.tile):
		return true
	var earshot: int = GameManager.config.banter_earshot_tiles
	return maxi(absi(speaker_tile.x - me.tile.x), absi(speaker_tile.y - me.tile.y)) <= earshot


# Neutralize user text before it reaches a bbcode_enabled label: only "[" can open a tag, so
# swapping it for the "[lb]" literal-bracket escape is sufficient and lossless on display.
func _escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")
