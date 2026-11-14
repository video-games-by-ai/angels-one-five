class_name PauseMenu
extends Control
## Settings panel: the Escape menu in flight, and the Settings screen from the
## hangar. Changes apply immediately and persist to user://settings.cfg.

signal resumed
signal settings_changed
signal quit_requested
signal hangar_requested

const TEXT: Color = Color("fbf4e6")

var settings: GameSettings
var panel: PanelContainer
var title: Label
var resume: Button
var hangar: Button
var tilt: CheckBox    ## on a touch screen only


func build(game_settings: GameSettings) -> void:
	settings = game_settings
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	process_mode = Node.PROCESS_MODE_ALWAYS
	theme = _theme()
	var shade: ColorRect = ColorRect.new()
	shade.color = Color(0.03, 0.03, 0.04, 0.45)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	panel = PanelContainer.new()
	panel.custom_minimum_size = Vector2(600, 0)
	center.add_child(panel)
	var margin: MarginContainer = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	title = Label.new()
	title.text = "PAUSED"
	title.add_theme_font_size_override("font_size", 26)
	box.add_child(title)

	var by_touch: bool = TouchControls.wanted()
	if by_touch:
		tilt = _check(box, "Tilt steering: lean the phone to fly", settings.tilt_steering, func(v: bool) -> void: settings.tilt_steering = v)
	_slider(box, "Steering sensitivity" if by_touch else "Mouse sensitivity", 0.3, 2.5, 0.05, settings.mouse_sensitivity, func(v: float) -> void: settings.mouse_sensitivity = v)
	_check(box, "Invert up and down" if by_touch else "Invert vertical mouse", settings.invert_y, func(v: bool) -> void: settings.invert_y = v)
	_check(box, "Assisted levelling", settings.level_assist, func(v: bool) -> void: settings.level_assist = v)
	_slider(box, "Camera shake", 0.0, 1.5, 0.05, settings.camera_shake, func(v: float) -> void: settings.camera_shake = v)
	_slider(box, "Master volume", 0.0, 1.0, 0.05, settings.master_volume, func(v: float) -> void: settings.master_volume = v, true)
	_slider(box, "Engine & wind volume", 0.0, 1.0, 0.05, settings.engine_volume, func(v: float) -> void: settings.engine_volume = v, true)
	_slider(box, "Guns & effects volume", 0.0, 1.0, 0.05, settings.effects_volume, func(v: float) -> void: settings.effects_volume = v, true)
	var quality_row: HBoxContainer = _row(box, "Graphics quality")
	var quality: OptionButton = OptionButton.new()
	for name in GameSettings.QUALITY_NAMES:
		quality.add_item(name)
	quality.selected = settings.quality
	quality.custom_minimum_size = Vector2(170, 44)
	quality.item_selected.connect(func(i: int) -> void:
		settings.quality = i as GameSettings.Quality
		_changed())
	quality_row.add_child(quality)
	_check(box, "Fullscreen", settings.fullscreen, func(v: bool) -> void: settings.fullscreen = v)
	_check(box, "Snow showers (weather test, F4)", settings.snow_showers, func(v: bool) -> void: settings.snow_showers = v)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	box.add_child(buttons)
	resume = Button.new()
	resume.text = "Resume"
	resume.custom_minimum_size = Vector2(150, 46)
	resume.pressed.connect(func() -> void: resumed.emit())
	buttons.add_child(resume)
	hangar = Button.new()
	hangar.text = "Change aircraft"
	hangar.custom_minimum_size = Vector2(180, 46)
	hangar.pressed.connect(func() -> void: hangar_requested.emit())
	buttons.add_child(hangar)
	var quit: Button = Button.new()
	quit.text = "Quit to desktop"
	quit.custom_minimum_size = Vector2(180, 46)
	quit.pressed.connect(func() -> void: quit_requested.emit())
	buttons.add_child(quit)
	visible = false


## Show the panel: as the pause menu in flight, or opened from the hangar,
## where it only offers a way back.
func open(from_hangar: bool) -> void:
	title.text = "SETTINGS" if from_hangar else "PAUSED"
	resume.text = "Back" if from_hangar else "Resume"
	hangar.visible = not from_hangar
	if tilt != null:
		tilt.set_pressed_no_signal(settings.tilt_steering)   # the TILT button in flight changes it too
	visible = true


func _changed() -> void:
	settings.save()
	settings_changed.emit()


func _row(box: VBoxContainer, label_text: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	var label: Label = Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	box.add_child(row)
	return row


func _slider(box: VBoxContainer, label_text: String, lo: float, hi: float, step: float, value: float, apply: Callable, percent: bool = false) -> void:
	var row: HBoxContainer = _row(box, label_text)
	var slider: HSlider = HSlider.new()
	slider.min_value = lo
	slider.max_value = hi
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(200, 32)
	var readout: Label = Label.new()
	readout.custom_minimum_size = Vector2(52, 0)
	readout.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var shown: Callable = func(v: float) -> String: return ("%d%%" % roundi(v * 100.0)) if percent else ("%.2f" % v)
	readout.text = shown.call(value)
	slider.value_changed.connect(func(v: float) -> void:
		apply.call(v)
		readout.text = shown.call(v)
		_changed())
	row.add_child(slider)
	row.add_child(readout)


func _check(box: VBoxContainer, label_text: String, value: bool, apply: Callable) -> CheckBox:
	var row: HBoxContainer = _row(box, label_text)
	var check: CheckBox = CheckBox.new()
	check.button_pressed = value
	check.custom_minimum_size = Vector2(44, 44)
	check.toggled.connect(func(v: bool) -> void:
		apply.call(v)
		_changed())
	row.add_child(check)
	return check


static func _theme() -> Theme:
	var t: Theme = Theme.new()
	t.default_font = load("res://assets/fonts/Montserrat-Regular.otf")
	t.default_font_size = 17
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.07, 0.06, 0.88)
	panel_style.border_color = Color(1.0, 0.84, 0.59, 0.45)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(3)
	t.set_stylebox("panel", "PanelContainer", panel_style)
	var normal: StyleBoxFlat = StyleBoxFlat.new()
	normal.bg_color = Color(1, 1, 1, 0.05)
	normal.border_color = Color(1.0, 0.92, 0.8, 0.45)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(3)
	normal.content_margin_left = 14
	normal.content_margin_right = 14
	var hover: StyleBoxFlat = normal.duplicate()
	hover.bg_color = Color(1.0, 0.78, 0.4, 0.22)
	var pressed: StyleBoxFlat = normal.duplicate()
	pressed.bg_color = Color(1.0, 0.78, 0.4, 0.4)
	for kind in ["Button", "OptionButton"]:
		t.set_stylebox("normal", kind, normal)
		t.set_stylebox("hover", kind, hover)
		t.set_stylebox("pressed", kind, pressed)
		t.set_stylebox("focus", kind, hover)
		t.set_color("font_color", kind, TEXT)
	t.set_color("font_color", "Label", TEXT)
	t.set_color("font_color", "CheckBox", TEXT)
	return t
