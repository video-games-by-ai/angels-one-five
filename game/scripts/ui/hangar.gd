class_name Hangar
extends Control
## Aircraft selection shown before each sortie: three cards, each with a turning
## 3D model, what the aircraft is good at, its real engine and armament, and
## rating bars. Hovering or pressing 1-3 / arrow keys selects a card and plays
## that aircraft's engine; clicking it or pressing Enter flies it.

signal chosen(id: int)
signal quit_requested
signal map_requested
signal host_requested(id: int)
signal join_requested(id: int)
signal settings_requested

const TEXT: Color = Color("fbf4e6")
const DIM: Color = Color("e6d8bf")
const AMBER: Color = Color("ffc766")
const RATING_NAMES: PackedStringArray = ["SPEED", "AGILITY", "FIREPOWER", "ARMOUR"]

var selected: int = Airframes.Id.MUSTANG
var cards: Array[PanelContainer] = []
var turntables: Array[Node3D] = []
var displays: Array[Aircraft] = []
var stages: Array[SubViewport] = []
var fly_buttons: Array[Button] = []
var normal_style: StyleBoxFlat
var selected_style: StyleBoxFlat
var engine_preview: AudioStreamPlayer
var font_bold: Font
var notice_label: Label


func build(initial: int, map_name: String = "") -> void:
	selected = clampi(initial, 0, Airframes.COUNT - 1)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = PauseMenu._theme()
	font_bold = load("res://assets/fonts/Montserrat-SemiBold.otf")
	normal_style = StyleBoxFlat.new()
	normal_style.bg_color = Color(0.07, 0.06, 0.05, 0.80)
	normal_style.border_color = Color(1.0, 0.84, 0.59, 0.30)
	normal_style.set_border_width_all(1)
	normal_style.set_corner_radius_all(4)
	selected_style = normal_style.duplicate()
	selected_style.bg_color = Color(0.11, 0.09, 0.06, 0.90)
	selected_style.border_color = AMBER
	selected_style.set_border_width_all(2)

	var shade: ColorRect = ColorRect.new()
	shade.color = Color(0.03, 0.03, 0.04, 0.42)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var column: VBoxContainer = VBoxContainer.new()
	column.add_theme_constant_override("separation", 22)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(column)

	column.add_child(_label("CHOOSE YOUR AIRCRAFT", 34, TEXT, true, HORIZONTAL_ALIGNMENT_CENTER))
	notice_label = _label("", 18, AMBER, true, HORIZONTAL_ALIGNMENT_CENTER)
	notice_label.visible = false
	column.add_child(notice_label)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 22)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(row)
	for id in range(Airframes.COUNT):
		row.add_child(_card(id))
	var footer: HBoxContainer = HBoxContainer.new()
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(footer)
	footer.add_theme_constant_override("separation", 14)
	var hint: Label = _label("← →  or  1 2 3  choose      ENTER / click  fly      M  change map      ESC  settings", 15, DIM, false, HORIZONTAL_ALIGNMENT_LEFT)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(hint)
	var map_button: Button = Button.new()
	map_button.text = "Map: %s  ›" % map_name
	map_button.custom_minimum_size = Vector2(250, 42)
	map_button.focus_mode = Control.FOCUS_NONE
	map_button.pressed.connect(func() -> void: map_requested.emit())
	footer.add_child(map_button)
	for entry: Array in [["Host match", true], ["Join match", false]]:
		var online: Button = Button.new()
		online.text = String(entry[0])
		online.custom_minimum_size = Vector2(160, 42)
		online.focus_mode = Control.FOCUS_NONE
		var hosting: bool = entry[1]
		online.pressed.connect(func() -> void:
			if hosting:
				host_requested.emit(selected)
			else:
				join_requested.emit(selected))
		footer.add_child(online)
	var settings_button: Button = Button.new()
	settings_button.text = "Settings"
	settings_button.custom_minimum_size = Vector2(130, 42)
	settings_button.focus_mode = Control.FOCUS_NONE
	settings_button.pressed.connect(func() -> void: settings_requested.emit())
	footer.add_child(settings_button)
	var quit: Button = Button.new()
	quit.text = "Quit to desktop"
	quit.custom_minimum_size = Vector2(180, 42)
	quit.focus_mode = Control.FOCUS_NONE
	quit.pressed.connect(func() -> void: quit_requested.emit())
	footer.add_child(quit)

	engine_preview = AudioStreamPlayer.new()
	engine_preview.volume_db = -11.0
	engine_preview.bus = GameSettings.BUS_ENGINE
	engine_preview.pitch_scale = 0.84
	add_child(engine_preview)
	visible = false


func open() -> void:
	visible = true
	_set_stages_rendering(true)
	select(selected, true)


## A one-line message above the cards, e.g. why an online match ended.
func notice(text: String) -> void:
	notice_label.text = text
	notice_label.visible = text != ""


func close() -> void:
	visible = false
	_set_stages_rendering(false)
	engine_preview.stop()


## The 3D previews cost frame time even while hidden, so they only render here.
func _set_stages_rendering(on: bool) -> void:
	for stage in stages:
		stage.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


func select(id: int, force: bool = false) -> void:
	if id == selected and not force:
		return
	selected = clampi(id, 0, Airframes.COUNT - 1)
	for i in range(cards.size()):
		cards[i].add_theme_stylebox_override("panel", selected_style if i == selected else normal_style)
		fly_buttons[i].modulate = Color(1, 1, 1, 1.0 if i == selected else 0.55)
	engine_preview.stream = Sfx.looped(String(Airframes.spec(selected).engine_sound))
	engine_preview.play()


func _process(delta: float) -> void:
	if not visible:
		return
	for i in range(turntables.size()):
		turntables[i].rotation.y += delta * (0.55 if i == selected else 0.16)
		displays[i].idle(delta * (4.0 if i == selected else 1.0))


func _unhandled_input(event: InputEvent) -> void:
	if not visible or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match (event as InputEventKey).physical_keycode:
		KEY_LEFT, KEY_A:
			select(maxi(selected - 1, 0))
		KEY_RIGHT, KEY_D:
			select(mini(selected + 1, Airframes.COUNT - 1))
		KEY_1:
			select(0)
		KEY_2:
			select(1)
		KEY_3:
			select(2)
		KEY_ENTER, KEY_KP_ENTER, KEY_SPACE:
			chosen.emit(selected)
		KEY_M:
			map_requested.emit()
		_:
			return
	get_viewport().set_input_as_handled()


func _label(text: String, px: int, color: Color, bold: bool, align: HorizontalAlignment) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.horizontal_alignment = align
	label.add_theme_font_size_override("font_size", px)
	label.add_theme_color_override("font_color", color)
	if bold:
		label.add_theme_font_override("font", font_bold)
	return label


func _card(id: int) -> PanelContainer:
	var spec: Dictionary = Airframes.spec(id)
	var card: PanelContainer = PanelContainer.new()
	card.custom_minimum_size = Vector2(560, 0)
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	card.add_theme_stylebox_override("panel", normal_style)
	card.mouse_entered.connect(func() -> void: select(id))
	card.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			chosen.emit(id))
	var margin: MarginContainer = MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	card.add_child(margin)
	var box: VBoxContainer = VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var top: HBoxContainer = HBoxContainer.new()
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var klass: Label = _label(String(spec["class"]), 15, AMBER, true, HORIZONTAL_ALIGNMENT_LEFT)
	klass.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(klass)
	top.add_child(_label(str(id + 1), 15, DIM, true, HORIZONTAL_ALIGNMENT_RIGHT))
	box.add_child(top)

	box.add_child(_display(id))
	box.add_child(_label(String(spec.name), 28, TEXT, true, HORIZONTAL_ALIGNMENT_LEFT))
	box.add_child(_label(String(spec.origin), 14, DIM, false, HORIZONTAL_ALIGNMENT_LEFT))
	var blurb: Label = _label(String(spec.blurb), 16, TEXT, false, HORIZONTAL_ALIGNMENT_LEFT)
	blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	blurb.custom_minimum_size = Vector2(0, 50)
	box.add_child(blurb)

	var ratings: PackedFloat32Array = Airframes.ratings(id)
	for k in range(RATING_NAMES.size()):
		var bar: RatingBar = RatingBar.new()
		bar.label = RATING_NAMES[k]
		bar.value = ratings[k]
		bar.font = font_bold
		bar.custom_minimum_size = Vector2(0, 22)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(bar)

	box.add_child(_label("ENGINE   " + String(spec.engine_label), 14, DIM, false, HORIZONTAL_ALIGNMENT_LEFT))
	box.add_child(_label("GUNS   " + String(spec.guns_label), 14, DIM, false, HORIZONTAL_ALIGNMENT_LEFT))
	var fly: Button = Button.new()
	fly.text = "FLY THE " + String(spec.short)
	fly.custom_minimum_size = Vector2(0, 46)
	fly.focus_mode = Control.FOCUS_NONE
	fly.mouse_entered.connect(func() -> void: select(id))
	fly.pressed.connect(func() -> void: chosen.emit(id))
	box.add_child(fly)
	fly_buttons.append(fly)
	cards.append(card)
	return card


## A small 3D stage of its own for one aircraft.
func _display(id: int) -> SubViewportContainer:
	var container: SubViewportContainer = SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = Vector2(520, 250)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var viewport: SubViewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	container.add_child(viewport)
	stages.append(viewport)

	var sky_material: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.30, 0.42, 0.62)
	sky_material.sky_horizon_color = Color(0.95, 0.78, 0.58)
	sky_material.ground_bottom_color = Color(0.16, 0.15, 0.13)
	sky_material.ground_horizon_color = Color(0.70, 0.60, 0.48)
	var sky: Sky = Sky.new()
	sky.sky_material = sky_material
	var environment: Environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.9
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment: WorldEnvironment = WorldEnvironment.new()
	world_environment.environment = environment
	viewport.add_child(world_environment)

	var sun: DirectionalLight3D = DirectionalLight3D.new()
	sun.light_color = Color(1.0, 0.90, 0.76)
	sun.light_energy = 1.7
	sun.rotation = Vector3(deg_to_rad(-42.0), deg_to_rad(38.0), 0.0)
	viewport.add_child(sun)
	var fill: DirectionalLight3D = DirectionalLight3D.new()
	fill.light_color = Color(0.62, 0.74, 1.0)
	fill.light_energy = 0.45
	fill.rotation = Vector3(deg_to_rad(-12.0), deg_to_rad(-140.0), 0.0)
	viewport.add_child(fill)

	var turntable: Node3D = Node3D.new()
	turntable.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	turntable.rotation.y = deg_to_rad(215.0)
	viewport.add_child(turntable)
	var display: Aircraft = Aircraft.new()
	turntable.add_child(display)
	display.build(Airframes.spec(id), 0, false)
	display.rotation.z = deg_to_rad(-7.0)
	display.position.z = 0.4
	# The same camera for all three, so their real difference in size shows.
	var camera: Camera3D = Camera3D.new()
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.fov = 33.0
	viewport.add_child(camera)
	camera.look_at_from_position(Vector3(0.0, 6.2, 15.5), Vector3(0.0, -0.2, 0.0))
	turntables.append(turntable)
	displays.append(display)
	return container


## One labelled rating bar on a card.
class RatingBar:
	extends Control

	var label: String = ""
	var value: float = 0.0
	var font: Font

	func _draw() -> void:
		draw_string(font, Vector2(0, size.y * 0.5 + 5.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("e6d8bf"))
		var bar: Rect2 = Rect2(Vector2(118, size.y * 0.5 - 5.0), Vector2(size.x - 118, 10))
		draw_rect(bar, Color(1, 1, 1, 0.10), true)
		# Ten segments: differences between aircraft read at a glance.
		var filled: int = int(round(clampf(value, 0.0, 1.0) * 10.0))
		var seg: float = bar.size.x / 10.0
		for i in range(filled):
			draw_rect(Rect2(bar.position + Vector2(i * seg + 1.0, 1.0), Vector2(seg - 2.0, bar.size.y - 2.0)), Color("ffc766"), true)
