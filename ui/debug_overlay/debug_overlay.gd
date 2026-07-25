extends CanvasLayer

## F3 diagnostics overlay, top-right. Hidden by default (visibility IS the toggle; the node is
## always present in main.tscn so it can collect samples from session start). Shows, ~4×/s:
## FPS + frame time, and move-VERDICT latency last/median/p95 — deliberately labeled "move
## verdict", NOT "RTT": the sample is submit→verdict off MoveInput's latch, which includes the
## server's processing time, not pure network round-trip. Stats are computed over the last
## `max_samples` only (recent-window — network conditions drift; an early spike shouldn't
## haunt a whole session's median).
##
## Samples arrive over GameEvents.verdict_latency_measured (local player only) and are
## collected even while hidden, so toggling the overlay mid-session shows history, and the
## _exit_tree stdout summary — the M1.5 latency-baseline record — exists either way.
##
## By design the metric is idle-submit→verdict ONLY: pipelined steps (§2.2.5 amendment — the
## next step sent mid-glide) contribute NO samples, since their verdict is held to the glide
## boundary and would swamp the baseline with the wait time. The first step of each run (submitted
## idle) still samples, so steady pipelined travel is silent here but every run is still measured.

## Ring cap on retained latency samples: the stats window. A multi-hour session stays bounded,
## and median/p95 sorts stay trivial at this size.
@export var max_samples: int = 512

## Seconds between label refreshes (~4×/s). Sampling is not affected — only the redraw.
@export var refresh_interval_sec: float = 0.25

@onready var _label: Label = $StatsLabel

# Latency samples in SECONDS, oldest first, ring-capped at max_samples.
var _samples: Array[float] = []
var _refresh_elapsed: float = 0.0

# LAST AI DECISION per monster (v0.22.0): entity_id -> the `ai_decision` event's data dict (name,
# personality, chosen, scores). Only ever populated while the HOST has `/ai` on — the events simply do not
# exist otherwise, so this stays empty and costs nothing in normal play. Every peer collects them (the
# events broadcast), which is what lets a two-instance tuning session watch the same weights.
# KNOWN LIMIT (accepted, v0.22.0): entries for a monster that has since died or despawned PERSIST until the
# overlay is reset — a decision line is a diagnostic snapshot, not live state, and dropping them would mean
# subscribing this presentation-only node to death/despawn events for no tuning benefit. Turning /ai off and
# on again does not clear them either; a session restart does.
var _ai_decisions: Dictionary = {}


func _ready() -> void:
	# Collect always (hidden included) — see header. Overlay is per-instance; only the local
	# MoveInput emits, so these are this window's own verdicts.
	GameEvents.verdict_latency_measured.connect(_on_latency_measured)
	# The shared event pipe carries the dev-gated `ai_decision` events (v0.22.0). Subscribed always, like the
	# latency samples above: while /ai is off nothing is ever posted, so the handler never runs.
	NetEvents.event_received.connect(_on_net_event)
	# Harness knob: overlay=1 (debug.gd, either role) flips this flag before the scene loads.
	if GameManager.debug_overlay_start_visible:
		visible = true


func _process(delta: float) -> void:
	if not visible:
		return
	_refresh_elapsed += delta
	if _refresh_elapsed < refresh_interval_sec:
		return
	_refresh_elapsed = 0.0
	_label.text = _compose_stats()


## Nudge the F3 stats label to sit inside the WorldFrame's top-right (v0.12.0 HUD), not the canvas
## top-right — which under stretch/aspect="expand" now falls inside the right HUD column. Wired by
## main.gd off the HUD's world_frame_changed (and seeded once). This CanvasLayer is identity-transformed,
## so the rect (base px) positions the label directly.
func set_world_frame_rect(rect: Rect2) -> void:
	_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var label_w := 216.0
	_label.position = Vector2(rect.end.x - label_w - 4.0, rect.position.y + 4.0)
	_label.size = Vector2(label_w, 36.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug_overlay"):
		visible = not visible
		# Consume the event so F3 can never double-trigger if the action gains a second
		# consumer later — the toggle is this overlay's alone.
		get_viewport().set_input_as_handled()


## Session end (scene change or quit): print the recent-window latency summary to stdout —
## this line is the M1.5 latency-baseline record for a wire-test session's logs.
func _exit_tree() -> void:
	if _samples.is_empty():
		print("[Overlay] move verdict: no samples this session")
		return
	print("[Overlay] move verdict (ms, last %d samples): last %.1f | median %.1f | p95 %.1f" % [
		_samples.size(), _samples.back() * 1000.0,
		_percentile(0.5) * 1000.0, _percentile(0.95) * 1000.0])


# ── Private methods ───────────────────────────────────────────────────────────

## Keep the LAST utility-AI decision per monster (v0.22.0). Every other action on the pipe is ignored here —
## this overlay is a diagnostics surface, not a game-state consumer (main.gd and game_log own playback).
## F5 round reset (v0.23.2, Jon): the dev_reset_round broadcast reaches every peer, so CLEAR the table —
## the old round's monsters despawned and their ids will be reused by the fresh spawns; without the clear
## the panel kept showing last round's decisions beside this round's (observed in testing).
func _on_net_event(event: Dictionary) -> void:
	var action := str(event.get("action", ""))
	if action == "dev_reset_round":
		_ai_decisions.clear()
		return
	if action != "ai_decision":
		return
	var data: Dictionary = event.get("data", {})
	_ai_decisions[int(data.get("entity_id", 0))] = data


func _on_latency_measured(latency_sec: float) -> void:
	_samples.append(latency_sec)
	if _samples.size() > max_samples:
		_samples.pop_front()  # O(n) at n=512 ≈ nothing, a handful of times per second at most


func _compose_stats() -> String:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / fps if fps > 0.0 else 0.0
	var text := "FPS %d · %.1f ms" % [int(fps), frame_ms]
	# The live-tempo line is deliberately gone (v0.9.4): it duplicated the always-on TempoDisplay bar
	# exactly, so the overlay keeps only what that bar does NOT show — FPS and verdict latency.
	if _samples.is_empty():
		text += "\nverdict ms last/med/p95: no samples yet"
	else:
		text += "\nverdict ms last/med/p95: %.1f / %.1f / %.1f (n=%d)" % [
			_samples.back() * 1000.0, _percentile(0.5) * 1000.0,
			_percentile(0.95) * 1000.0, _samples.size()]
	# One line per utility-AI monster that has decided something since `/ai` was turned on. Absent entirely
	# in normal play (nothing is ever posted with the toggle off), so the overlay's usual two lines stand.
	for entity_id in _ai_decisions:
		text += "\n" + _compose_ai_line(int(entity_id), _ai_decisions[entity_id])
	return text


## Render one AI decision: "Goblin Shaman -6 [supportive]: HEAL 72.0* smite 41.0 melee 0.0". The CHOSEN action
## is upper-cased and starred so the decision reads at a glance against the also-rans (the zero-score entries
## are deliberately shown — why it did NOT do a thing is half of what a tuner needs). Scores arrive in
## post-sort order (chosen first), so the line already reads best-to-worst.
func _compose_ai_line(entity_id: int, data: Dictionary) -> String:
	var chosen := str(data.get("chosen", ""))
	var line := "%s %d [%s]:" % [
		str(data.get("name", "?")), entity_id, str(data.get("personality", "neutral"))]
	var scores: Dictionary = data.get("scores", {})
	for action in scores:
		# action_name, not `name`: a bare `name` local would shadow Node.name on this CanvasLayer.
		var action_name := str(action)
		if action_name == chosen:
			line += " %s %.1f*" % [action_name.to_upper(), float(scores[action])]
		else:
			line += " %s %.1f" % [action_name, float(scores[action])]
	if chosen.is_empty():
		line += " (idle)"
	return line


## Percentile over a sorted copy of the ring (upper-index convention — exact interpolation is
## overkill for a diagnostics readout). p in (0,1]; assumes _samples is non-empty.
func _percentile(p: float) -> float:
	var sorted := _samples.duplicate()
	sorted.sort()
	var idx := clampi(int(floor(sorted.size() * p)), 0, sorted.size() - 1)
	return sorted[idx]
