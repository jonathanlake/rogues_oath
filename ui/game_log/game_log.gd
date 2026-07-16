extends CanvasLayer

## Combined chat + combat log, bottom-left of the 640x360 base viewport. Two jobs:
##  1. Render events from NetEvents (chat now; combat-log lines from roll outcomes later).
##  2. Own the chat input box — a self-contained focus flow that never violates the
##     Commitment Rule (chat commits nothing, cancels nothing).
##
## M2 FOCUS RULE (documented here because this file is the reason it exists): once movement
## input lands, it will be gated on `get_viewport().gui_get_focus_owner()` being a
## LineEdit/TextEdit — i.e. "is the player typing in the chat box?". There is deliberately NO
## global is_chatting flag; the focused control IS the single source of truth. Keep it that way.

## Ring cap on stored log lines. RichTextLabel keeps every paragraph forever otherwise; at
## chat + combat volume across a run that grows unbounded, so we drop the oldest past this.
@export var max_lines: int = 200

@onready var _log: RichTextLabel = $Panel/VBox/Log
@onready var _input: LineEdit = $Panel/VBox/Input

# Paragraph count mirror. RichTextLabel exposes get_paragraph_count(), but tracking our own
# counter keeps add_line's trim decision O(1) and independent of how bbcode maps to paragraphs.
var _line_count: int = 0


func _ready() -> void:
	_input.text_submitted.connect(_on_input_submitted)
	NetEvents.event_received.connect(_on_event_received)
	# The referee's refusals surface HERE (DESIGN §2.3.4: a rejection must never be silent —
	# the sender sees why their message vanished). Only the sender's instance receives these.
	NetEvents.intent_rejected.connect(_on_intent_rejected)


# Focus flow lives here, not on the LineEdit, so the log owns "am I typing?" end-to-end.
# Enter while unfocused grabs the input; Esc while focused clears + releases without sending
# (submitting is text_submitted's job, wired in _ready). Handled (not _input) so a focused
# LineEdit consumes its own keys first — we only see Enter when nothing else wanted it.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) and not _input.has_focus():
			_input.grab_focus()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _input.has_focus():
			_input.clear()
			_input.release_focus()
			get_viewport().set_input_as_handled()

# ── Public methods ────────────────────────────────────────────────────────────

## Append one line. append_text is fine at chat volume (comment retained deliberately: if
## combat spam ever chafes on the string rebuilds, revisit — e.g. batch or switch to
## add_text). Enforces the max_lines cap by dropping the oldest paragraph as we grow past it.
func add_line(text: String) -> void:
	_log.append_text(text + "\n")
	_line_count += 1
	if _line_count > max_lines:
		_log.remove_paragraph(0)
		_line_count -= 1

# ── Private methods ───────────────────────────────────────────────────────────

func _on_input_submitted(text: String) -> void:
	# Empty/whitespace: just drop focus, send nothing (no wasted intent, no empty chat event).
	if text.strip_edges().is_empty():
		_input.clear()
		_input.release_focus()
		return
	# The host still re-validates and clamps server-side — this send is a request, not a truth.
	NetEvents.submit_intent("chat", {"text": text})
	_input.clear()
	_input.release_focus()


func _on_event_received(event: Dictionary) -> void:
	if event.get("action", "") != "chat":
		return
	var data: Dictionary = event.get("data", {})
	# Escape BOTH fields BEFORE composing the bbcode line. Future name-coloring wraps color
	# tags around the ESCAPED name (escape-then-wrap), so a name containing "[" can never
	# inject markup into the log.
	var display_name := _escape_bbcode(str(data.get("name", "")))
	var body := _escape_bbcode(str(data.get("text", "")))
	add_line("[b]%s[/b]: %s" % [display_name, body])


func _on_intent_rejected(action: String, reason: String) -> void:
	if action == "chat":
		add_line("(message not sent: %s)" % reason)


# Neutralize user text before it reaches a bbcode_enabled label: only "[" can open a tag, so
# swapping it for the "[lb]" literal-bracket escape is sufficient and lossless on display.
func _escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")
