class_name AIChat
extends CanvasLayer
## 大肥鱼聊天面板：聊天气泡 + DeepSeek 直连配置。
## 网络、上下文和工具调用都在 core/ai_client.gd（autoload AI）里，这里只管人和 AI 的对话界面。
## 打开时挂 ui_modal 组：room_camera / home_editor / map_editor 的 _input 看到这个组就不抢触摸，
## 所以 open()/close() 必须和 visible 同步，别从别处直接改 visible。

const FONT_SIZE := 20
const BUBBLE_MAX := 620.0
const SHEET_HALF_W := 620.0
const SHEET_HALF_H := 460.0
const DEFAULT_BASE := "https://api.deepseek.com"
const DEFAULT_MODEL := "deepseek-chat"
const KEY_SAVED := "已保存在手机上"

var _root: Control
var _sheet: PanelContainer
var _scroll: ScrollContainer
var _bubbles: VBoxContainer
var _input: LineEdit
var _send: Button
var _status: Label
var _config: VBoxContainer
var _config_button: Button
var _key_field: LineEdit
var _base_field: LineEdit
var _model_field: LineEdit
var _config_note: Label
var _ai: Node
var _bound_to: Node
var _state := "idle"


func _ready() -> void:
	layer = 30
	visible = false
	_root = Control.new()
	_root.name = "AIChatRoot"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var shade := ColorRect.new()
	shade.color = Color(0.05, 0.08, 0.15, 0.65)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_STOP
	shade.gui_input.connect(_on_shade_input)
	_root.add_child(shade)
	_sheet = PanelContainer.new()
	_sheet.set_anchors_preset(Control.PRESET_CENTER)
	_sheet.add_theme_stylebox_override("panel", _box(Hud.PAPER, Hud.WOOD, 4, 18))
	_root.add_child(_sheet)
	_sheet.theme = _theme()
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	_sheet.add_child(column)
	_build_head(column)
	_build_log(column)
	_build_config(column)
	_build_input(column)
	_fit()
	get_viewport().size_changed.connect(_fit)


## 面板能开能关，组跟随 visible 走；world 的触摸守卫靠这个组。
func open() -> void:
	if not is_inside_tree():
		return
	_bind_ai()
	_fit()
	_load_config_fields()
	visible = true
	if not is_in_group("ui_modal"):
		add_to_group("ui_modal")
	if _bubbles.get_child_count() == 0:
		_add_bubble("……站着干嘛，坐啊。", false)
	_scroll_to_bottom()


func close() -> void:
	visible = false
	if is_in_group("ui_modal"):
		remove_from_group("ui_modal")
	_input.release_focus()


func is_open() -> bool:
	return visible


func _unhandled_key_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func _on_shade_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		close()


func _build_head(column: VBoxContainer) -> void:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	column.add_child(head)
	var emblem := Control.new()
	emblem.custom_minimum_size = Vector2(40, 40)
	emblem.mouse_filter = Control.MOUSE_FILTER_IGNORE
	emblem.draw.connect(func(): _draw_emblem(emblem))
	head.add_child(emblem)
	var title := Label.new()
	title.text = "大肥鱼"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_font_override("font", _bold_font())
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", 18)
	_status.add_theme_color_override("font_color", Hud.INK2)
	head.add_child(_status)
	_config_button = _button("设置", func(): _show_config(not _config.visible), head)
	_button("重开", _reset_chat, head)
	_button("关闭", close, head)


func _build_log(column: VBoxContainer) -> void:
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	column.add_child(_scroll)
	_bubbles = VBoxContainer.new()
	_bubbles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bubbles.add_theme_constant_override("separation", 10)
	_scroll.add_child(_bubbles)


func _build_config(column: VBoxContainer) -> void:
	_config = VBoxContainer.new()
	_config.visible = false
	_config.add_theme_constant_override("separation", 8)
	column.add_child(_config)
	var hint := Label.new()
	hint.text = "直连 DeepSeek：Key 只存在这台手机的 user://ai_config.cfg。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Hud.INK2)
	_config.add_child(hint)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 10)
	_config.add_child(grid)
	_key_field = _config_field(grid, "API Key", true)
	_base_field = _config_field(grid, "接口地址", false)
	_model_field = _config_field(grid, "模型", false)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	_config.add_child(row)
	_button("保存配置", _save_config, row)
	_config_note = Label.new()
	_config_note.add_theme_font_size_override("font_size", 16)
	_config_note.add_theme_color_override("font_color", Hud.GREEN)
	row.add_child(_config_note)


func _build_input(column: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	column.add_child(row)
	_input = LineEdit.new()
	_input.placeholder_text = "和大肥鱼说点什么…"
	_input.custom_minimum_size = Vector2(0, 52)
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.add_theme_font_size_override("font_size", FONT_SIZE)
	_input.text_submitted.connect(func(_text: String): _send_message())
	row.add_child(_input)
	_send = Button.new()
	_send.text = "发送"
	_send.custom_minimum_size = Vector2(120, 52)
	_send.add_theme_font_size_override("font_size", FONT_SIZE)
	_send.pressed.connect(_send_message)
	row.add_child(_send)


func _fit() -> void:
	var view := get_viewport().get_visible_rect().size
	var half_w := minf(SHEET_HALF_W, view.x * 0.46)
	var half_h := minf(SHEET_HALF_H, view.y * 0.44)
	_sheet.offset_left = -half_w
	_sheet.offset_right = half_w
	_sheet.offset_top = -half_h
	_sheet.offset_bottom = half_h


func _send_message() -> void:
	if _state != "idle":
		return
	var text := _input.text.strip_edges()
	if text == "":
		return
	_bind_ai()
	var ai := _ai_node()
	var ready := ai != null and ai.has_method("ready") and bool(ai.call("ready"))
	if not ready:
		_add_bubble("先去设置里填 API Key，我还连不上。", false, "error")
		_show_config(true)
		return
	_input.text = ""
	_add_bubble(text, true)
	_set_state("thinking")
	ai.call("say", text)


func _show_config(on: bool) -> void:
	_config.visible = on
	_config_button.text = "收起设置" if on else "设置"
	if on:
		_load_config_fields()


func _load_config_fields() -> void:
	var ai := _ai_node()
	var raw: Variant = ai.get("config") if ai != null else null
	var config: Dictionary = raw if raw is Dictionary else {}
	# 已保存的 Key 不回显，只留占位提示；要换就整条重填。
	if _key_field.text == "":
		_key_field.text = ""
		_key_field.placeholder_text = KEY_SAVED if str(config.get("api_key", "")).strip_edges() != "" else ""
	if _base_field.text == "":
		_base_field.text = str(config.get("base_url", DEFAULT_BASE))
	if _model_field.text == "":
		_model_field.text = str(config.get("model", DEFAULT_MODEL))


func _save_config() -> void:
	_bind_ai()
	var ai := _ai_node()
	if ai == null:
		_config_note.text = "AI 客户端还没挂上"
		_config_note.add_theme_color_override("font_color", Hud.RED)
		return
	var raw: Variant = ai.get("config")
	if not (raw is Dictionary):
		_config_note.text = "AI 契约不一致：没有 config 字典"
		_config_note.add_theme_color_override("font_color", Hud.RED)
		return
	var config: Dictionary = raw
	var key := _key_field.text.strip_edges()
	var existing := str(config.get("api_key", "")).strip_edges()
	if key == "" and existing == "":
		_config_note.text = "Key 不能为空"
		_config_note.add_theme_color_override("font_color", Hud.RED)
		return
	var base := _base_field.text.strip_edges()
	var model := _model_field.text.strip_edges()
	if key != "":
		config["api_key"] = key
	config["base_url"] = base if base != "" else DEFAULT_BASE
	config["model"] = model if model != "" else DEFAULT_MODEL
	var ok := false
	if ai.has_method("save_config"):
		ok = bool(ai.call("save_config"))
	if not ok:
		_config_note.text = "保存失败，检查存储权限"
		_config_note.add_theme_color_override("font_color", Hud.RED)
		return
	_config_note.text = "已保存"
	_config_note.add_theme_color_override("font_color", Hud.GREEN)
	# 保存后不回显 Key，只留占位提示；日志里也不出现。
	_key_field.text = ""
	_key_field.placeholder_text = KEY_SAVED


func _reset_chat() -> void:
	var ai := _ai_node()
	if ai != null and ai.has_method("reset_chat"):
		ai.call("reset_chat")
	for child in _bubbles.get_children():
		child.queue_free()
	_set_state("idle")
	_add_bubble("……站着干嘛，坐啊。", false)


func _set_state(value: String) -> void:
	_state = value
	match value:
		"thinking":
			_status.text = "大肥鱼在想…"
			_send.disabled = true
		"tool":
			_status.text = "在做事…"
			_send.disabled = true
		_:
			_status.text = ""
			_send.disabled = false


func _add_bubble(text: String, mine: bool, tone := "") -> void:
	if text.strip_edges() == "":
		return
	var row := HBoxContainer.new()
	_bubbles.add_child(row)
	if mine:
		var left := Control.new()
		left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(left)
	var bubble := PanelContainer.new()
	bubble.size_flags_horizontal = Control.SIZE_SHRINK_END if mine else Control.SIZE_SHRINK_BEGIN
	var bg := Color("d9e9ff") if mine else Hud.PAPER_H
	var edge := Color("9dbde0") if mine else Hud.WOOD_L
	if tone == "error":
		bg = Color("fbe3dc")
		edge = Hud.RED
	elif tone == "hint":
		bg = Hud.PAPER_D
	bubble.add_theme_stylebox_override("panel", _bubble_box(bg, edge))
	row.add_child(bubble)
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	label.add_theme_color_override("font_color", Hud.RED if tone == "error" else Hud.INK)
	if text.length() > 30:
		label.custom_minimum_size.x = BUBBLE_MAX
	bubble.add_child(label)
	if not mine:
		var right := Control.new()
		right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(right)
	_scroll_to_bottom()


func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	if not is_instance_valid(_scroll):
		return
	var bar := _scroll.get_v_scroll_bar()
	_scroll.scroll_vertical = int(maxf(0.0, bar.max_value - bar.page))


func _ai_node() -> Node:
	if _ai == null or not is_instance_valid(_ai):
		_ai = get_node_or_null("/root/AI")
	return _ai


## AI 是另一个模块写的 autoload；信号只接一次，连不上就等下次 open()。
func _bind_ai() -> void:
	var ai := _ai_node()
	if ai == null or ai == _bound_to:
		return
	_bound_to = ai
	var handlers := [["replied", "_on_replied"], ["failed", "_on_failed"], ["state_changed", "_on_state_changed"]]
	for pair in handlers:
		var signal_name: String = pair[0]
		var handler := Callable(self, pair[1])
		if ai.has_signal(signal_name) and not ai.is_connected(signal_name, handler):
			ai.connect(signal_name, handler)


func _on_replied(text: String) -> void:
	_add_bubble(text, false)
	_set_state("idle")


func _on_failed(message: String) -> void:
	_add_bubble(message if message.strip_edges() != "" else "连不上，等会儿再试。", false, "error")
	_set_state("idle")


func _on_state_changed(state: String) -> void:
	_set_state(state)


func _theme() -> Theme:
	var theme_of := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "SimHei"])
	theme_of.default_font = font
	theme_of.default_font_size = FONT_SIZE
	for type_of in ["Label", "Button", "LineEdit"]:
		for color_of in ["font_color", "font_hover_color", "font_pressed_color"]:
			theme_of.set_color(color_of, type_of, Hud.INK)
	for type_of in ["Button", "LineEdit"]:
		theme_of.set_stylebox("normal", type_of, _box(Hud.PAPER_H, Hud.WOOD_L, 2, 8))
		theme_of.set_stylebox("hover", type_of, _box(Hud.PAPER_D, Hud.WOOD_L, 2, 8))
		theme_of.set_stylebox("pressed", type_of, _box(Hud.PAPER_D, Hud.WOOD, 2, 8))
		theme_of.set_stylebox("disabled", type_of, _box(Hud.PAPER_D, Hud.WOOD_L, 1, 8))
		theme_of.set_color("font_disabled_color", type_of, Hud.INK2)
	theme_of.set_stylebox("focus", "LineEdit", _box(Hud.PAPER_H, Hud.GOLD, 2, 8))
	return theme_of


func _bold_font() -> SystemFont:
	var bold := SystemFont.new()
	bold.font_names = PackedStringArray(["Microsoft YaHei UI", "Microsoft YaHei", "SimHei"])
	bold.font_weight = 700
	return bold


func _box(color: Color, border: Color, width: int, pad: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.border_color = border
	box.set_border_width_all(width)
	box.set_content_margin_all(pad)
	box.set_corner_radius_all(6)
	return box


func _bubble_box(color: Color, border: Color) -> StyleBoxFlat:
	var box := _box(color, border, 2, 12)
	box.set_corner_radius_all(10)
	return box


func _label(value: String, parent: Node) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _button(value: String, action: Callable, parent: Node) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size = Vector2(0, 52)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL if parent is GridContainer else Control.SIZE_FILL
	button.add_theme_font_size_override("font_size", FONT_SIZE)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _config_field(parent: Node, label_text: String, secret: bool) -> LineEdit:
	var label := _label(label_text, parent)
	label.custom_minimum_size.x = 110
	label.add_theme_font_size_override("font_size", 18)
	var field := LineEdit.new()
	field.custom_minimum_size.y = 52
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.add_theme_font_size_override("font_size", FONT_SIZE)
	field.secret = secret
	if secret:
		field.placeholder_text = KEY_SAVED
	parent.add_child(field)
	return field


func _draw_emblem(area: Control) -> void:
	area.draw_rect(Rect2(3, 7, 34, 24), Hud.WOOD_D)
	area.draw_rect(Rect2(7, 11, 26, 16), Hud.CREAM)
	area.draw_rect(Rect2(9, 31, 12, 5), Hud.WOOD_D)
	for x in [12.0, 19.0, 26.0]:
		area.draw_rect(Rect2(x, 17, 4, 4), Hud.WOOD_L)
