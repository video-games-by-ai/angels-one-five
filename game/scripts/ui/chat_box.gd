class_name ChatBox
extends Control
## Online chat at the bottom left: a few small see-through lines that fade
## after eight seconds, and one input line. ENTER opens it, ENTER sends, ESC
## cancels. The lines live in NetSession.chat_log, so they survive the scene
## reload a joiner does to load the host's map. While the line is open the keys
## write text and the mouse still steers and fires (PlayerInput.typing).
## Sketches: docs/sketches/chat-overview.svg and docs/sketches/chat-states.svg.

const TEXT: Color = Color("fbf4e6")
const DIM: Color = Color("e6d8bf")
const AMBER: Color = Color("ffc766")       ## your own name
const OTHER: Color = Color("ff7a4d")       ## everyone else's name
const PANEL: Color = Color(0.09, 0.07, 0.05, 0.58)
const EDGE: Color = Color(1.0, 0.84, 0.59, 0.42)
const BACKING: Color = Color(0.055, 0.047, 0.035)
const SHOW_SECONDS: float = 8.0            ## a line stays fully visible this long…
const FADE_SECONDS: float = 1.0            ## …then fades out over this long
const MAX_ROWS: int = 5
const ROWS_PER_LINE: int = 3               ## a long message wraps onto at most this many rows
const OPEN_ALPHA: float = 0.85             ## recent lines shown again while typing
# Sizes in pixels at 1080p; everything scales with the window height.
const LEFT: float = 28.0
const BOTTOM: float = 89.0                 ## input line bottom, above the instrument bar
const WIDTH: float = 460.0
const INPUT_HEIGHT: float = 29.0
const ROW: float = 24.0
const MESSAGE_PX: float = 15.0
const NAME_PX: float = 13.0
const SMALL_PX: float = 11.5

var session: NetSession
var can_type: bool = false                 ## set by the game: online, in the lobby or a match, no menu open
var font: Font
var font_bold: Font
var edit: LineEdit
var ui_scale: float = 1.0
var _open: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	font = load("res://assets/fonts/Montserrat-Regular.otf")
	font_bold = load("res://assets/fonts/Montserrat-SemiBold.otf")
	edit = LineEdit.new()
	edit.max_length = NetProtocol.CHAT_MAX
	edit.context_menu_enabled = false        # the right mouse button belongs to the game
	edit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	edit.select_all_on_focus = false
	edit.caret_blink = true
	edit.add_theme_font_override("font", font)
	edit.add_theme_color_override("font_color", TEXT)
	edit.add_theme_color_override("caret_color", AMBER)
	edit.add_theme_color_override("selection_color", Color(AMBER, 0.35))
	edit.add_theme_constant_override("caret_width", 2)
	for style: String in ["normal", "focus", "read_only"]:
		var empty: StyleBoxEmpty = StyleBoxEmpty.new()
		edit.add_theme_stylebox_override(style, empty)
	edit.text_submitted.connect(_submit)
	edit.visible = false
	add_child(edit)


func is_open() -> bool:
	return _open


## True while the box shows anything, so the HUD can tuck its hints away.
func busy() -> bool:
	return _open or not _rows().is_empty()


func open_input() -> void:
	if _open:
		return
	_open = true
	edit.text = ""
	edit.visible = true
	_layout()
	edit.grab_focus()
	edit.edit()


func close_input() -> void:
	if not _open:
		return
	_open = false
	edit.unedit()
	edit.release_focus()
	edit.visible = false


func _live() -> bool:
	return session != null and is_instance_valid(session) and session.role != NetSession.Role.NONE


func _submit(text: String) -> void:
	if _live():
		session.say(text)
	close_input()


func _input(event: InputEvent) -> void:
	var key_event: InputEventKey = event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return
	var enter: bool = key_event.keycode == KEY_ENTER or key_event.keycode == KEY_KP_ENTER
	if _open:
		if key_event.keycode == KEY_ESCAPE:
			close_input()   # and the pause menu stays shut
			get_viewport().set_input_as_handled()
		elif enter and not edit.has_focus():
			_submit(edit.text)
			get_viewport().set_input_as_handled()
		return
	if enter and can_type and _live():
		var focus: Control = get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			return   # ENTER belongs to the field being typed in (lobby name, invite)
		open_input()
		get_viewport().set_input_as_handled()   # also keeps a focused lobby button from firing


func _process(_delta: float) -> void:
	if _open and (not can_type or not _live()):
		close_input()
	_layout()
	queue_redraw()


func _input_rect() -> Rect2:
	var s: float = ui_scale
	return Rect2(LEFT * s, size.y - (BOTTOM + INPUT_HEIGHT) * s, WIDTH * s, INPUT_HEIGHT * s)


func _layout() -> void:
	ui_scale = clampf(size.y / 1080.0, 0.7, 2.0)
	var box: Rect2 = _input_rect()
	edit.position = box.position + Vector2(48.0 * ui_scale, 0.0)
	edit.size = Vector2(box.size.x - 56.0 * ui_scale, box.size.y)
	edit.add_theme_font_size_override("font_size", int(round(MESSAGE_PX * ui_scale)))


## How visible a line `age` seconds old is when the input line is closed.
static func line_alpha(age: float) -> float:
	if age < 0.0:
		return 1.0
	return clampf(1.0 - (age - SHOW_SECONDS) / FADE_SECONDS, 0.0, 1.0)


## Split `text` into rows no wider than `width`, breaking between words where it
## can and inside a word only when the word alone is too wide.
static func wrap_rows(text: String, text_font: Font, px: int, width: float) -> PackedStringArray:
	var rows: PackedStringArray = PackedStringArray()
	var row: String = ""
	for word: String in text.split(" ", false):
		var trial: String = word if row == "" else row + " " + word
		if text_font.get_string_size(trial, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x <= width:
			row = trial
			continue
		if row != "":
			rows.append(row)
		row = ""
		for ch in word:
			if row != "" and text_font.get_string_size(row + ch, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x > width:
				rows.append(row)
				row = ""
			row += ch
	if row != "":
		rows.append(row)
	return rows


## The rows to draw, newest first: {name, colour, text, alpha, name_width}.
## `name` is "" on a message's continuation rows. A message is shown whole or
## not at all.
func _rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _live() or font == null:
		return out
	var s: float = ui_scale
	var name_px: int = int(round(NAME_PX * s))
	var message_px: int = int(round(MESSAGE_PX * s))
	var now: int = Time.get_ticks_msec()
	var me: int = session.my_id()
	for i in range(session.chat_log.size() - 1, -1, -1):
		var line: Dictionary = session.chat_log[i]
		var alpha: float = line_alpha((now - int(line.at)) / 1000.0)
		if _open:
			alpha = maxf(alpha, OPEN_ALPHA)
		if alpha <= 0.0:
			break   # older lines have faded too
		var who: String = String(line.name).to_upper()
		var name_width: float = font_bold.get_string_size(who, HORIZONTAL_ALIGNMENT_LEFT, -1, name_px).x
		var room: float = WIDTH * s - (9.0 + 9.0 + 16.0) * s - name_width
		var parts: PackedStringArray = wrap_rows(String(line.text), font, message_px, room)
		if parts.size() > ROWS_PER_LINE:
			parts = parts.slice(0, ROWS_PER_LINE)
		if out.size() + parts.size() > MAX_ROWS:
			break
		var colour: Color = AMBER if int(line.peer) == me else OTHER
		for k in range(parts.size() - 1, -1, -1):
			out.append({"name": who if k == 0 else "", "colour": colour, "text": parts[k], "alpha": alpha, "name_width": name_width})
	return out


func _draw() -> void:
	var s: float = ui_scale
	var box: Rect2 = _input_rect()
	if _open:
		draw_style_box(_panel_style(s), box)
		draw_string(font_bold, box.position + Vector2(11.0 * s, box.size.y * 0.5 + 4.0 * s), "SAY",
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(round(SMALL_PX * s)), AMBER)
		if edit.text == "":
			draw_string(font, Vector2(box.position.x, box.position.y + box.size.y * 0.5 + 4.0 * s), "ENTER send  ·  ESC cancel",
				HORIZONTAL_ALIGNMENT_RIGHT, box.size.x - 12.0 * s, int(round(SMALL_PX * s)), Color(DIM, 0.7))
	var rows: Array[Dictionary] = _rows()
	var name_px: int = int(round(NAME_PX * s))
	var message_px: int = int(round(MESSAGE_PX * s))
	var outline: int = maxi(int(round(3.0 * s)), 2)
	for r in range(rows.size()):
		var row: Dictionary = rows[r]
		var a: float = float(row.alpha)
		var baseline: float = box.position.y - 11.0 * s - r * ROW * s
		var text_x: float = box.position.x + (9.0 + 9.0) * s + float(row.name_width)
		var text_width: float = font.get_string_size(String(row.text), HORIZONTAL_ALIGNMENT_LEFT, -1, message_px).x
		_backing(Rect2(box.position.x, baseline - 16.0 * s, minf(text_x - box.position.x + text_width + 30.0 * s, WIDTH * s), 21.0 * s), a)
		if String(row.name) != "":
			var name_at: Vector2 = Vector2(box.position.x + 9.0 * s, baseline - 0.5 * s)
			draw_string_outline(font_bold, name_at, String(row.name), HORIZONTAL_ALIGNMENT_LEFT, -1, name_px, outline, Color(BACKING, 0.6 * a))
			draw_string(font_bold, name_at, String(row.name), HORIZONTAL_ALIGNMENT_LEFT, -1, name_px, Color(row.colour, a))
		var at: Vector2 = Vector2(text_x, baseline)
		draw_string_outline(font, at, String(row.text), HORIZONTAL_ALIGNMENT_LEFT, -1, message_px, outline, Color(BACKING, 0.6 * a))
		draw_string(font, at, String(row.text), HORIZONTAL_ALIGNMENT_LEFT, -1, message_px, Color(TEXT, a))


## A soft dark band behind one row that fades out to the right, so the text
## reads over snow and bright sky without a frame around the chat.
func _backing(rect: Rect2, alpha: float) -> void:
	var x0: float = rect.position.x
	var x1: float = x0 + rect.size.x * 0.8
	var x2: float = rect.end.x
	var y0: float = rect.position.y
	var y1: float = rect.end.y
	var strong: Color = Color(BACKING, 0.54 * alpha)
	var mid: Color = Color(BACKING, 0.48 * alpha)
	var faint: Color = Color(BACKING, 0.06 * alpha)
	draw_polygon(PackedVector2Array([Vector2(x0, y0), Vector2(x1, y0), Vector2(x1, y1), Vector2(x0, y1)]),
		PackedColorArray([strong, mid, mid, strong]))
	draw_polygon(PackedVector2Array([Vector2(x1, y0), Vector2(x2, y0), Vector2(x2, y1), Vector2(x1, y1)]),
		PackedColorArray([mid, faint, faint, mid]))


func _panel_style(s: float) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = PANEL
	style.border_color = EDGE
	style.set_border_width_all(1)
	style.set_corner_radius_all(int(round(3.0 * s)))
	style.anti_aliasing = true
	return style
