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


func _ready() -> void:
	# Collect always (hidden included) — see header. Overlay is per-instance; only the local
	# MoveInput emits, so these are this window's own verdicts.
	GameEvents.verdict_latency_measured.connect(_on_latency_measured)
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

func _on_latency_measured(latency_sec: float) -> void:
	_samples.append(latency_sec)
	if _samples.size() > max_samples:
		_samples.pop_front()  # O(n) at n=512 ≈ nothing, a handful of times per second at most


func _compose_stats() -> String:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / fps if fps > 0.0 else 0.0
	var text := "FPS %d  (%.1f ms/frame)" % [int(fps), frame_ms]
	if _samples.is_empty():
		text += "\nmove verdict (ms): no samples yet"
	else:
		text += "\nmove verdict (ms, last %d): last %.1f | med %.1f | p95 %.1f" % [
			_samples.size(), _samples.back() * 1000.0,
			_percentile(0.5) * 1000.0, _percentile(0.95) * 1000.0]
	return text


## Percentile over a sorted copy of the ring (upper-index convention — exact interpolation is
## overkill for a diagnostics readout). p in (0,1]; assumes _samples is non-empty.
func _percentile(p: float) -> float:
	var sorted := _samples.duplicate()
	sorted.sort()
	var idx := clampi(int(floor(sorted.size() * p)), 0, sorted.size() - 1)
	return sorted[idx]
