extends Node

## Host-only slash-command referee (v0.10.0, DESIGN §2.3.4 dev tools), extracted from main.gd (v0.10.1)
## so the ~1700-line session root sheds the whole dev-command surface. A scene Node in main.tscn beside
## the referees; Main activates it host-side with injected container/combat refs and registers its
## `validate` as the NetEvents "dev_command" handler. Inert on clients — activate() runs only inside
## main.gd's is_server() branch, so a client's node never adjudicates (mirrors the referees' contract).
##
## Component pattern (CLAUDE.md): it reads the containers/combat referee Main handed it plus the global
## GameManager config, and posts outcomes on the shared NetEvents pipe; it never reaches up to Main.
##
## ANY peer submits a dev_command {cmd, args} intent (the game_log "/" intercept parses + lowercases the
## tokens). validate() resolves the sender null-safe, then DISPATCHES on a command table: /w (weapon
## tuning), /m (monster tuning), /god (own invulnerability), /class (own class), and the bare-weapon
## alias ("/longsword 5" → /w longsword 5). The command table takes PRECEDENCE over the alias (a weapon
## named like a command is reachable only via /w). Most commands return a host-composed log line the
## generic dev_command event carries to every peer; /class instead broadcasts its own class_changed
## event and defers (no dev_command broadcast). Unknown command / bad field / non-number / out-of-range
## value → reject with a reason (sender-only, like a refused move).

# The Players container + combat referee, handed in by Main via activate() on the HOST only. Players is
# read to resolve the sender's node (name, class); combat owns the /god invulnerability toggle. Never
# reached up from; null on clients (activate never runs there).
var _players: Node2D = null
var _combat = null


## Host-only entry point, called by Main inside its is_server() branch after the referees are wired.
## Never called on clients (their node stays inert).
func activate(players: Node2D, combat: Node) -> void:
	_players = players
	_combat = combat


# ── Public methods ──────────────────────────────────────────────────────────────

## Host-only dev_command handler, registered with NetEvents by Main. Resolves the sender null-safe,
## then dispatches on the command table (table precedence over the bare-weapon alias). See the class
## header for the full contract.
func validate(sender_peer_id: int, data: Dictionary) -> Dictionary:
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	var by := player_node.display_name
	var cmd := str(data.get("cmd", "")).to_lower()
	# Coerce the wire args to a lowercased String array — never trust the wire's element types.
	var args: Array[String] = []
	var raw_args = data.get("args", [])
	if raw_args is Array:
		for a in raw_args:
			args.append(str(a).to_lower())
	match cmd:
		"w":
			return _dev_cmd_weapon(args, by)
		"m":
			return _dev_cmd_monster(args, by)
		"god":
			return _dev_cmd_god(sender_peer_id, by)
		"class":
			return _dev_cmd_class(sender_peer_id, args, by)
		_:
			# Bare-weapon alias: "/longsword 5" arrives as cmd "longsword", args ["5"]. Reachable ONLY when
			# cmd resolves to a real weapon (table precedence is handled by the match above). Re-dispatch as
			# /w by prepending the weapon name onto the args.
			if _resolve_weapon(cmd) != null:
				var aliased: Array[String] = [cmd]
				aliased.append_array(args)
				return _dev_cmd_weapon(aliased, by)
			return { "ok": false, "reason": "unknown command '%s'" % cmd }


# ── Private methods ─────────────────────────────────────────────────────────────

## /w <weapon> [field] <value|reset> — weapon tuning (v0.10.0). Resolve the weapon (roster first, then a
## filename load), then hand the rest to the shared tune pipeline. Field defaults to `damage` (so "/w
## longsword 5" works) — normalized here, the one weapon-specific rule — before _dev_tune_resource does
## the reset / field-allowlist / range-clamp / mutate work shared with /m.
func _dev_cmd_weapon(args: Array[String], by: String) -> Dictionary:
	if args.size() < 2:
		return { "ok": false, "reason": "usage: /w <weapon> [field] <value|reset>" }
	var weapon := _resolve_weapon(args[0])
	if weapon == null:
		return { "ok": false, "reason": "unknown weapon '%s'" % args[0] }
	var rest := args.slice(1)
	# Field defaults to damage when a lone value is given ("/w longsword 5"). A lone "reset" is left
	# untouched so the shared pipeline still sees it as a reset.
	if rest.size() == 1 and rest[0] != "reset":
		rest = ["damage", rest[0]] as Array[String]
	return _dev_tune_resource(weapon, GameManager.DEV_WEAPON_FIELDS, GameManager.DEV_WEAPON_INT_FIELDS,
			GameManager.DEV_WEAPON_CLAMPS, rest, by, weapon.display_name)


## /m <monster> <field> <value|reset> — MonsterType tuning (v0.10.0). Resolve the type by a filename load
## (exists-guarded — no roster for monsters, the .tres filename is the token), then hand the rest to the
## shared tune pipeline. No field default (a monster field is always explicit); max_hp carries a note that
## its change affects NEW spawns only (it is seeded at spawn), the one monster-specific rule.
func _dev_cmd_monster(args: Array[String], by: String) -> Dictionary:
	if args.size() < 2:
		return { "ok": false, "reason": "usage: /m <monster> <field> <value|reset>" }
	var monster := _resolve_monster(args[0])
	if monster == null:
		return { "ok": false, "reason": "unknown monster '%s'" % args[0] }
	return _dev_tune_resource(monster, GameManager.DEV_MONSTER_FIELDS, GameManager.DEV_MONSTER_INT_FIELDS,
			GameManager.DEV_MONSTER_CLAMPS, args.slice(1), by, monster.display_name,
			{ "max_hp": "(affects new spawns)" })


## The ONE tune pipeline for /w and /m (v0.10.1 dedup). `args` is the tokens after the resource name:
## a shape whose LAST token is "reset" restores every allowlisted field from disk; otherwise it is
## [field, value]. Validates the field against the allowlist, parses the value as a number, and REJECTS
## (naming the range — never silently clamps) any value outside the field's clamp table before mutating
## the SHARED loaded resource host-side (adjudication reads it live at the next stamp). A field in
## `int_fields` is stored as an int, else as a float. `notes` maps a field to a suffix appended to the
## success line (e.g. max_hp → "(affects new spawns)"). Returns the host-composed verdict dict.
func _dev_tune_resource(res: Resource, fields: Array, int_fields: Array, clamps: Dictionary,
		args: Array, by: String, label: String, notes: Dictionary = {}) -> Dictionary:
	# reset: any shape whose LAST token is "reset" restores every allowlisted field from disk.
	if not args.is_empty() and args[args.size() - 1] == "reset":
		_dev_reset_resource(res, fields)
		return { "ok": true, "data": { "line": "%s reset the %s." % [by, label] } }
	if args.size() < 2:
		return { "ok": false, "reason": "usage: <field> <value|reset>" }
	# Explicit String types — indexing a typed Array returns Variant at parse time, so := can't infer.
	var field: String = args[0]
	var value_token: String = args[1]
	if not (field in fields):
		return { "ok": false, "reason": "unknown field '%s'" % field }
	if not value_token.is_valid_float():
		return { "ok": false, "reason": "'%s' is not a number" % value_token }
	var num := value_token.to_float()
	# Range clamp (v0.10.1 review fix 1): a per-field sane range enforced HERE, at the one validator, so
	# a fat-fingered "/w longsword -5" or "/m goblin max_hp 1e9" is refused with the allowed range named
	# rather than poisoning the shared resource. clamps[field] is [min, max].
	var lo = clamps[field][0]
	var hi = clamps[field][1]
	if num < float(lo) or num > float(hi):
		return { "ok": false, "reason": "%s must be between %s and %s" % [field, str(lo), str(hi)] }
	if field in int_fields:
		res.set(field, int(num))
	else:
		res.set(field, num)
	var line := "%s set %s %s to %s." % [by, label, field, value_token]
	if notes.has(field):
		line += " " + str(notes[field])
	return { "ok": true, "data": { "line": line } }


## /god — toggle the SENDER's invulnerability (v0.10.0). Flips the combat referee's godded entry for the
## sender's own entity id and returns the log line from the NEW state. Host-authoritative (the godded dict
## lives host-side); a godded target's hits then resolve as visible no-ops in CombatReferee.apply_damage.
func _dev_cmd_god(sender_peer_id: int, by: String) -> Dictionary:
	var now_godded: bool = _combat.toggle_godded(sender_peer_id)
	var line := ("%s is invulnerable." % by) if now_godded else ("%s is mortal again." % by)
	return { "ok": true, "data": { "line": line } }


## /class <name> — set the SENDER's class (v0.10.0). Resolve the class through the roster, apply it
## host-side to the sender's player (set_class), then BROADCAST a class_changed event (mirror of
## swap_weapon) every peer adopts + logs, and return a DEFERRED verdict so NetEvents does NOT also
## broadcast a generic dev_command event (the class_changed event is the whole outcome — no double log).
## Late-join is handled separately (sync_player_field "class" in peer_ready).
func _dev_cmd_class(sender_peer_id: int, args: Array[String], by: String) -> Dictionary:
	if args.is_empty():
		return { "ok": false, "reason": "usage: /class <name>" }
	var player_class := GameManager.config.class_by_name(args[0])
	if player_class == null:
		return { "ok": false, "reason": "unknown class '%s'" % args[0] }
	var player_node := _players.get_node_or_null(str(sender_peer_id)) as Player
	if player_node == null:
		return { "ok": false, "reason": "not in session" }
	# Apply host-side FIRST (authoritative), then broadcast — mirrors _validate_swap_weapon. set_class
	# repaints the host's own sprite at validator time too; the call_local re-apply stays idempotent.
	player_node.set_class(player_class)
	NetEvents.post_event("class_changed", {
		"entity_id": sender_peer_id,
		"class": player_class.display_name,
		"by": by,
	})
	# Deferred: the class_changed broadcast IS the outcome — suppress the generic dev_command broadcast
	# (ok:true so it isn't a reject; deferred:true so NetEvents skips the broadcast + seq).
	return { "ok": true, "deferred": true }


## Resolve a weapon by lowercase name (v0.10.0 /w): GameConfig.weapon_by_name FIRST (roster display_name),
## else a filename load guarded by ResourceLoader.exists — so the claw (not in the roster) is reachable by
## its filename (= its display_name). Null if neither resolves. Host-side only.
func _resolve_weapon(name: String) -> WeaponType:
	var w := GameManager.config.weapon_by_name(name)
	if w != null:
		return w
	var path := "res://resources/weapons/%s.tres" % name
	if ResourceLoader.exists(path):
		return load(path) as WeaponType
	return null


## Resolve a MonsterType by lowercase name via a filename load, exists-guarded (v0.10.0 /m). No roster for
## monsters — the .tres filename is the token ("goblin" → goblin.tres). Null if the file is absent.
func _resolve_monster(name: String) -> MonsterType:
	var path := "res://resources/monsters/%s.tres" % name
	if ResourceLoader.exists(path):
		return load(path) as MonsterType
	return null


## Restore `fields` on a shared resource from a FRESH disk copy (v0.10.0 /w & /m reset). Loads the same
## .tres with CACHE_MODE_IGNORE (Godot 4.7's cache_mode param) so it reads the authored on-disk values
## regardless of the live mutated cached instance, then copies each allowlisted field onto the shared
## resource. The resource's own resource_path is the source — a roster-resolved weapon carries it just like
## a filename-loaded one, so both reset paths share this.
func _dev_reset_resource(res: Resource, fields: Array) -> void:
	var fresh := ResourceLoader.load(res.resource_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if fresh == null:
		return
	for f in fields:
		res.set(f, fresh.get(f))
