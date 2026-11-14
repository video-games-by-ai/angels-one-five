class_name Lobby
extends Control
## Online match screens. Hosting: open the port, set the address, copy the
## invite, see who has joined (with Kick) and start. Joining: paste an invite,
## then wait in the lobby for the host to start. All state lives in NetSession;
## this only shows it and passes on what the player asks for.

signal start_requested
signal leave_requested
signal join_requested(invite: Invite)

const TEXT: Color = Color("fbf4e6")
const DIM: Color = Color("e6d8bf")
const AMBER: Color = Color("ffc766")
const WARN: Color = Color("ff9a6b")
const GOOD: Color = Color("9fd98b")

var session: NetSession
var settings: GameSettings
var hosting: bool = false
var result_text: String = ""
var probe: AddressProbe
var probe_text: String = ""
var public_seen: String = ""

var title: Label
var subtitle: Label
var name_edit: LineEdit
var host_box: VBoxContainer
var router_label: Label
var upnp_check: CheckBox
var upnp_status: Label
var address_edit: LineEdit
var address_status: Label
var invite_edit: LineEdit
var copy_button: Button
var new_invite_button: Button
var join_box: VBoxContainer
var paste_edit: LineEdit
var invite_note: Label            ## what the pasted invite is, or what is wrong with it
var last_invite_note: String = ""
var join_button: Button
var status_label: Label
var players_title: Label
var players_box: VBoxContainer
var reach_label: Label
var result_label: Label
var start_button: Button
var leave_button: Button
var copied_time: float = 0.0


func build(game_settings: GameSettings) -> void:
	settings = game_settings
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	theme = PauseMenu._theme()
	var shade: ColorRect = ColorRect.new()
	shade.color = Color(0.03, 0.03, 0.04, 0.5)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(shade)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel: PanelContainer = PanelContainer.new()
	panel.custom_minimum_size = Vector2(860, 0)
	center.add_child(panel)
	var margin: MarginContainer = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 28)
	panel.add_child(margin)
	var box: VBoxContainer = VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)

	title = _label("", 26, TEXT)
	box.add_child(title)
	subtitle = _label("", 15, DIM)
	box.add_child(subtitle)
	var name_row: HBoxContainer = _row(box, "Your name")
	name_edit = LineEdit.new()
	name_edit.max_length = NetProtocol.NAME_MAX
	name_edit.custom_minimum_size = Vector2(300, 40)
	name_edit.text_changed.connect(func(t: String) -> void:
		settings.player_name = NetProtocol.clean_text(t, NetProtocol.NAME_MAX)
		settings.save()
		if hosting and session != null and is_instance_valid(session):
			session.rename_host(settings.player_name))
	name_row.add_child(name_edit)

	# Hosting steps.
	host_box = VBoxContainer.new()
	host_box.add_theme_constant_override("separation", 8)
	box.add_child(host_box)
	host_box.add_child(_heading("1   OPEN THE PORT"))
	router_label = _label("", 15, DIM, true)
	host_box.add_child(router_label)
	var upnp_row: HBoxContainer = HBoxContainer.new()
	upnp_check = CheckBox.new()
	upnp_check.text = "Open port automatically (UPnP)"
	upnp_check.toggled.connect(func(on: bool) -> void:
		settings.auto_port = on
		settings.save()
		if session != null:
			session.set_auto_port(on))
	upnp_row.add_child(upnp_check)
	upnp_status = _label("", 14, DIM, true)
	upnp_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upnp_row.add_child(upnp_status)
	host_box.add_child(upnp_row)
	host_box.add_child(_label("Firewall: when your computer asks whether Airflight may use the network, allow it.", 15, DIM, true))

	host_box.add_child(_heading("2   YOUR INTERNET ADDRESS"))
	var address_row: HBoxContainer = HBoxContainer.new()
	address_row.add_theme_constant_override("separation", 10)
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "public IP address or dynamic DNS name"
	address_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	address_edit.custom_minimum_size = Vector2(0, 40)
	address_edit.text_changed.connect(func(t: String) -> void:
		var clean: String = _clean_address(t)
		settings.host_address = clean
		settings.save()
		if session != null:
			session.set_address(clean))
	address_row.add_child(address_edit)
	var detect: Button = Button.new()
	detect.text = "Detect"
	detect.custom_minimum_size = Vector2(120, 40)
	detect.pressed.connect(_detect_address)
	address_row.add_child(detect)
	host_box.add_child(address_row)
	address_status = _label("", 14, DIM, true)
	host_box.add_child(address_status)

	host_box.add_child(_heading("3   SEND THE INVITE"))
	var invite_row: HBoxContainer = HBoxContainer.new()
	invite_row.add_theme_constant_override("separation", 10)
	invite_edit = LineEdit.new()
	invite_edit.editable = false
	invite_edit.secret = true   # it is a password: keep it off screen shares
	invite_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	invite_edit.custom_minimum_size = Vector2(0, 40)
	invite_row.add_child(invite_edit)
	copy_button = Button.new()
	copy_button.text = "Copy invite"
	copy_button.custom_minimum_size = Vector2(150, 40)
	copy_button.pressed.connect(func() -> void:
		if session != null and session.invite_text() != "":
			DisplayServer.clipboard_set(session.invite_text())
			copied_time = 2.5
			refresh())
	invite_row.add_child(copy_button)
	new_invite_button = Button.new()
	new_invite_button.text = "New invite"
	new_invite_button.custom_minimum_size = Vector2(140, 40)
	new_invite_button.pressed.connect(func() -> void:
		if session != null:
			session.new_invite())
	invite_row.add_child(new_invite_button)
	host_box.add_child(invite_row)
	host_box.add_child(_label("The invite works like a password: anyone who has it can join. Share it only in a private chat. \"New invite\" makes the old one stop working.", 14, DIM, true))

	# Joining.
	join_box = VBoxContainer.new()
	join_box.add_theme_constant_override("separation", 8)
	box.add_child(join_box)
	join_box.add_child(_label("Paste the invite the host sent you.", 15, DIM, true))
	var paste_row: HBoxContainer = HBoxContainer.new()
	paste_row.add_theme_constant_override("separation", 10)
	paste_edit = LineEdit.new()
	paste_edit.secret = true
	paste_edit.placeholder_text = "AF1.…"
	paste_edit.max_length = Invite.MAX_TEXT
	paste_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	paste_edit.custom_minimum_size = Vector2(0, 40)
	paste_edit.text_submitted.connect(func(_t: String) -> void: _try_join())
	paste_edit.text_changed.connect(func(_t: String) -> void: _check_invite())
	paste_row.add_child(paste_edit)
	var paste: Button = Button.new()
	paste.text = "Paste"
	paste.custom_minimum_size = Vector2(110, 40)
	paste.pressed.connect(func() -> void:
		# Straight from the clipboard, so no keyboard has a chance to alter it.
		paste_edit.text = Invite.tidy(DisplayServer.clipboard_get()).substr(0, Invite.MAX_TEXT)
		_check_invite())
	paste_row.add_child(paste)
	var clear: Button = Button.new()
	clear.text = "Clear"
	clear.custom_minimum_size = Vector2(110, 40)
	clear.pressed.connect(func() -> void:
		paste_edit.text = ""
		_check_invite())
	paste_row.add_child(clear)
	join_button = Button.new()
	join_button.text = "Join"
	join_button.custom_minimum_size = Vector2(110, 40)
	join_button.pressed.connect(_try_join)
	paste_row.add_child(join_button)
	join_box.add_child(paste_row)
	invite_note = _label("", 15, DIM, true)
	join_box.add_child(invite_note)

	status_label = _label("", 15, AMBER, true)
	box.add_child(status_label)
	players_title = _heading("PLAYERS")
	box.add_child(players_title)
	players_box = VBoxContainer.new()
	players_box.add_theme_constant_override("separation", 4)
	box.add_child(players_box)
	reach_label = _label("", 14, DIM, true)
	box.add_child(reach_label)
	result_label = _label("", 17, AMBER, true)
	box.add_child(result_label)

	var buttons: HBoxContainer = HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	box.add_child(buttons)
	start_button = Button.new()
	start_button.text = "Start match"
	start_button.custom_minimum_size = Vector2(180, 46)
	start_button.pressed.connect(func() -> void: start_requested.emit())
	buttons.add_child(start_button)
	leave_button = Button.new()
	leave_button.custom_minimum_size = Vector2(180, 46)
	leave_button.pressed.connect(func() -> void: leave_requested.emit())
	buttons.add_child(leave_button)
	probe = AddressProbe.new()
	add_child(probe)
	probe.finished.connect(_on_probe)
	visible = false


## Show the lobby for a session (hosting or joined), or the join screen if null.
func open(for_session: NetSession, as_host: bool, last_result: String = "") -> void:
	if session != null and session != for_session and is_instance_valid(session) and session.changed.is_connected(refresh):
		session.changed.disconnect(refresh)
	session = for_session
	hosting = as_host
	result_text = last_result
	name_edit.text = settings.player_name
	address_edit.text = settings.host_address if session == null or session.address == "" else session.address
	upnp_check.set_pressed_no_signal(session != null and session.port_mapper != null)
	if session != null and not session.changed.is_connected(refresh):
		session.changed.connect(refresh)
	visible = true
	refresh()


func close() -> void:
	visible = false


func _process(delta: float) -> void:
	if copied_time > 0.0:
		copied_time -= delta
		if copied_time <= 0.0:
			refresh()


func refresh() -> void:
	if not visible:
		return
	var live: bool = session != null and is_instance_valid(session) and session.role != NetSession.Role.NONE
	host_box.visible = hosting
	join_box.visible = not hosting and not (live and session.players.size() > 0)
	name_edit.editable = hosting or not live
	players_title.visible = live
	reach_label.visible = hosting
	start_button.visible = hosting
	result_label.text = result_text
	result_label.visible = result_text != ""
	if hosting:
		title.text = "HOST A MATCH"
		subtitle.text = "Map: %s  ·  UDP port %d  ·  up to %d players, first to %d kills wins" % [
			TerrainData.MAPS[TerrainData.map_index(session.map_id)].name if live else "", session.port if live else 0,
			session.max_players if live else NetProtocol.MAX_PLAYERS, settings.score_limit]
		router_label.text = "Router: forward UDP %d to this computer, once. Or let the game ask the router:" % (session.port if live else NetSession.DEFAULT_PORT)
		leave_button.text = "Stop hosting"
	elif live and session.players.size() > 0:
		title.text = "ONLINE LOBBY"
		subtitle.text = "Connected to %s's match." % (String(session.players[0].name) if int(session.players[0].peer) == 1 else "a dedicated server")
		name_edit.text = session.local_name
		leave_button.text = "Leave"
	else:
		title.text = "JOIN A MATCH"
		subtitle.text = "You need an invite from the host."
		leave_button.text = "Leave" if live else "Back"
	if not live:
		status_label.text = session.status if session != null and is_instance_valid(session) else ""
		players_box.visible = false
		_check_invite()
		return
	players_box.visible = true
	join_button.disabled = true
	status_label.text = session.status
	if hosting:
		var invite: String = session.invite_text()
		invite_edit.text = invite
		invite_edit.placeholder_text = "enter your address above to make an invite"
		copy_button.disabled = invite == ""
		copy_button.text = "Copied" if copied_time > 0.0 else "Copy invite"
		new_invite_button.disabled = invite == ""
		upnp_status.text = session.port_mapper.text if session.port_mapper != null else ""
		_update_address_status()
		reach_label.text = "Someone has reached you from the internet: the port works." if session.reached_from_outside \
			else "Nobody has reached you yet. A friend joining is the real test of the port."
		start_button.disabled = session.players.size() < 2 or session.in_match
		if not session.in_match:
			status_label.text = "Waiting for players. Start when everyone is in." if session.players.size() < 2 else "Ready. Start the match when everyone is in."
	elif session.players.size() > 0:
		status_label.text = "A match is in progress. You will fly in the next one." if session.in_match else "In the lobby. Waiting for the host to start the match."
	players_title.text = "PLAYERS  %d / %d" % [session.players.size(), session.max_players]
	for child in players_box.get_children():
		child.queue_free()
	for p: Dictionary in session.players:
		var row: HBoxContainer = HBoxContainer.new()
		var who: String = String(p.name)
		if int(p.peer) == session.my_id():
			who += "  (you)"
		elif int(p.peer) == 1:
			who += "  (host)"
		var label: Label = _label("%s   ·   %s" % [who, String(Airframes.spec(int(p.frame)).name)], 17, TEXT)
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		if hosting and int(p.peer) != 1:
			var kick: Button = Button.new()
			kick.text = "Kick"
			kick.custom_minimum_size = Vector2(90, 34)
			var peer: int = int(p.peer)
			kick.pressed.connect(func() -> void: session.kick(peer))
			row.add_child(kick)
		players_box.add_child(row)


func _update_address_status() -> void:
	var wan: String = session.port_mapper.external_address if session.port_mapper != null else ""
	var warning: String = NetSession.address_warning(wan, public_seen)
	if warning != "":
		address_status.text = warning
		address_status.add_theme_color_override("font_color", WARN)
	elif session.address == "":
		address_status.text = "Friends connect to this address. Press Detect, or type it (a dynamic DNS name keeps working when your address changes)."
		address_status.add_theme_color_override("font_color", DIM)
	else:
		address_status.text = probe_text if probe_text != "" else "Invites point to %s:%d." % [session.address, session.port]
		address_status.add_theme_color_override("font_color", DIM)


func _detect_address() -> void:
	probe_text = "Asking a public address service…"
	refresh()
	probe.detect()


func _on_probe(found: String, error: String) -> void:
	if found != "":
		public_seen = found
		probe_text = "Detected %s. Invites point there." % found
		address_edit.text = found
		settings.host_address = found
		settings.save()
		if session != null:
			session.set_address(found)
	else:
		probe_text = error
	refresh()


## Check the pasted invite at once, before any connection is tried: say what it
## is or what is wrong with it, and allow Join only for a sound one.
func _check_invite() -> Invite:
	var error: Array = []
	var text: String = paste_edit.text
	var invite: Invite = null if text == "" else Invite.decode(text, error)
	if text == "":
		invite_note.text = "Copy the invite where the host sent it, then press Paste."
		invite_note.add_theme_color_override("font_color", DIM)
	elif invite == null:
		invite_note.text = String(error[0]) if not error.is_empty() else "That invite is not valid."
		invite_note.add_theme_color_override("font_color", WARN)
	else:
		invite_note.text = "Invite checked: %s, port %d. Press Join." % [invite.address, invite.port]
		invite_note.add_theme_color_override("font_color", GOOD)
	if invite_note.text != last_invite_note:
		last_invite_note = invite_note.text
		DeviceDiag.mark("invite check, %d characters: %s" % [Invite.tidy(text).length(), "sound" if invite != null else invite_note.text])
	join_button.disabled = invite == null
	return invite


func _try_join() -> void:
	var invite: Invite = _check_invite()
	if invite != null:
		join_requested.emit(invite)


static func _clean_address(text: String) -> String:
	var out: String = ""
	for i in range(text.length()):
		if Invite.ADDRESS_CHARS.find(text[i]) >= 0:
			out += text[i]
	return out.substr(0, Invite.MAX_ADDRESS)


func _label(text: String, px: int, color: Color, wrap: bool = false) -> Label:
	var label: Label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", px)
	label.add_theme_color_override("font_color", color)
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


func _heading(text: String) -> Label:
	var label: Label = _label(text, 15, AMBER)
	label.add_theme_font_override("font", load("res://assets/fonts/Montserrat-SemiBold.otf"))
	return label


func _row(box: VBoxContainer, label_text: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	var label: Label = _label(label_text, 17, TEXT)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	box.add_child(row)
	return row
