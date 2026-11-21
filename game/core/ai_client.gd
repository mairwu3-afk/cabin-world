extends Node
## In-APK DeepSeek client. The chat bubble (ui/ai_chat.gd) only talks to this autoload.
## No Node bridge: the request goes straight from the APK to {base_url}/chat/completions.
##
## INTERFACE (ui/ai_chat.gd depends on it, do not rename):
##   signal replied(text) / failed(message) / state_changed("idle"|"thinking"|"tool")
##   var config: {api_key, base_url, model}
##   ready() -> bool · save_config() -> bool · say(text) · reset_chat()
##   extra: tool_called(tool, args), history, persona(), is_busy(), state()
## The api_key never goes into a print, a push_error or a signal; only generic Chinese reasons leave this file.

signal replied(text: String)
signal failed(message: String)
signal state_changed(state: String) ## "idle" / "thinking" / "tool"
signal tool_called(tool: String, args: Dictionary)

const AITools := preload("res://core/ai_tools.gd")
const CONFIG_PATH := "user://ai_config.cfg"
const PERSONA_PATH := "res://assets/ai/persona.json"
const HISTORY_KEEP := 20
const MAX_TOOL_ROUNDS := 4
const HTTP_TIMEOUT := 30.0
const DEFAULT_BASE := "https://api.deepseek.com"
const DEFAULT_MODEL := "deepseek-chat"
const FALLBACK_SYSTEM := "你是住在海边小屋的大肥鱼：说话短，1~3 句；有点傲娇，嘴上不饶人但会照顾人；不用客服腔，不编造自己没做过的事。"
const TOOL_NOTE := "你可以用工具做事：去房间、用家具、买东西、吃东西、睡觉、摸头、送礼、钓鱼、看状态。要用就直接调用；工具失败就照实说，一句话带过。回答用中文。"

var config: Dictionary = {"api_key": "", "base_url": DEFAULT_BASE, "model": DEFAULT_MODEL}
var history: Array = [] ## OpenAI-style rows without the system prompt; the chat UI may read it for bubbles.

var _http: HTTPRequest
var _tools
var _persona := {}
var _system := FALLBACK_SYSTEM
var _busy := false
var _requesting := false
var _round := 0
var _state := "idle"


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = HTTP_TIMEOUT
	_http.request_completed.connect(_on_request_completed)
	add_child(_http)
	_tools = AITools.new(self)
	load_config()
	_load_persona()


# ---- Public interface --------------------------------------------------------


func ready() -> bool:
	return str(config["api_key"]).strip_edges() != ""


func load_config() -> void:
	config = {"api_key": "", "base_url": DEFAULT_BASE, "model": DEFAULT_MODEL}
	var file := ConfigFile.new()
	if file.load(CONFIG_PATH) != OK:
		return
	config["api_key"] = str(file.get_value("ai", "api_key", ""))
	config["base_url"] = str(file.get_value("ai", "base_url", DEFAULT_BASE))
	config["model"] = str(file.get_value("ai", "model", DEFAULT_MODEL))
	_normalize()


func save_config() -> bool:
	_normalize()
	var file := ConfigFile.new()
	file.set_value("ai", "api_key", str(config["api_key"]))
	file.set_value("ai", "base_url", str(config["base_url"]))
	file.set_value("ai", "model", str(config["model"]))
	return file.save(CONFIG_PATH) == OK


## Sends one user line and walks the whole turn (tool calls included) asynchronously.
func say(text: String) -> void:
	var clean := text.strip_edges()
	if clean == "":
		return
	if _busy:
		## UI 在 thinking 时本来就禁用发送；这里静默丢弃，别把正在跑的一轮误判成失败
		state_changed.emit("thinking")
		return
	if not ready():
		failed.emit("还没填 API Key，去设置里填")
		return
	history.append({"role": "user", "content": clean})
	_trim()
	_round = 0
	_busy = true
	_send()


func reset_chat() -> void:
	if _http != null:
		_http.cancel_request()
	_requesting = false
	_busy = false
	_round = 0
	history.clear()
	_set_state("idle")


func is_busy() -> bool:
	return _busy


func state() -> String:
	return _state


func persona() -> Dictionary:
	return _persona


# ---- One request -------------------------------------------------------------


func _send() -> void:
	if not ready():
		_finish_fail("还没填 API Key")
		return
	if _requesting:
		return
	var messages: Array = [
		{"role": "system", "content": _system},
		{"role": "system", "content": TOOL_NOTE},
	]
	messages.append_array(history)
	var body := {
		"model": str(config["model"]),
		"messages": messages,
		"stream": false,
		"temperature": 0.8,
	}
	## Four tool rounds is the budget: past that the last request goes out without tools.
	if _round < MAX_TOOL_ROUNDS:
		body["tools"] = _tools.schemas()
		body["tool_choice"] = "auto"
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer " + str(config["api_key"]),
	])
	_set_state("thinking")
	_requesting = true
	var url := str(config["base_url"]) + "/chat/completions"
	var error := _http.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
	if error != OK:
		_requesting = false
		_finish_fail("请求发不出去（错误码 %d）" % error)


func _on_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_requesting = false
	if not _busy: ## cancelled by reset_chat() while the request was in flight
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_finish_fail(_network_reason(result))
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		_finish_fail("服务器返回看不懂的内容")
		return
	if response_code != 200:
		_finish_fail(_http_reason(response_code, parsed))
		return
	var choices = parsed.get("choices")
	if not (choices is Array) or choices.is_empty() or not (choices[0] is Dictionary):
		_finish_fail("模型没返回结果")
		return
	var message = choices[0].get("message")
	if not (message is Dictionary):
		_finish_fail("模型返回格式不对")
		return
	var calls = message.get("tool_calls")
	if calls is Array and not calls.is_empty() and _round < MAX_TOOL_ROUNDS:
		_run_tools(message, calls)
		return
	var raw_content = message.get("content")
	var content := str(raw_content).strip_edges() if raw_content is String else ""
	if content == "":
		_finish_fail("模型这次没说话")
		return
	history.append({"role": "assistant", "content": content})
	_trim()
	_finish_ok(content)


# ---- Tool rounds -------------------------------------------------------------


func _run_tools(message: Dictionary, calls: Array) -> void:
	## 先把合法的 call 过滤出来：assistant 里写进去的每个 tool_call 都必须有一条 tool 回填，
	## 否则下一轮请求会 400，整个会话就废了。
	var valid: Array = []
	for call in calls:
		if call is Dictionary and str(call.get("id", "")) != "":
			valid.append(call)
	if valid.is_empty():
		_finish_fail("模型返回的 tool_call 不完整")
		return
	_set_state("tool")
	var raw_content = message.get("content")
	var assistant := {"role": "assistant", "content": str(raw_content) if raw_content is String else ""}
	assistant["tool_calls"] = valid
	history.append(assistant)
	for call in valid:
		var call_id := str(call.get("id", ""))
		var name := ""
		var args: Dictionary = {}
		var fn = call.get("function")
		if fn is Dictionary:
			name = str(fn.get("name", ""))
			var raw = fn.get("arguments", "{}")
			var parsed = raw if raw is Dictionary else JSON.parse_string(str(raw))
			if parsed is Dictionary:
				args = parsed
		var outcome = _tools.call_tool(name, args)
		if not (outcome is Dictionary):
			outcome = {"ok": false, "error": "动作没执行成功"}
		tool_called.emit(name, args)
		history.append({"role": "tool", "tool_call_id": call_id, "content": JSON.stringify(outcome)})
	_round += 1
	_trim()
	_send()


## Keeps the last HISTORY_KEEP rows and never lets the window start with a tool row
## or with an assistant row whose tool answers were dropped.
func _trim() -> void:
	while history.size() > HISTORY_KEEP:
		history.remove_at(0)
	while not history.is_empty():
		var row = history[0]
		if not (row is Dictionary):
			history.remove_at(0)
			continue
		if str(row.get("role", "")) == "tool" or row.has("tool_calls"):
			history.remove_at(0)
			continue
		break


# ---- End of turn -------------------------------------------------------------


func _finish_ok(text: String) -> void:
	_busy = false
	_round = 0
	_set_state("idle")
	replied.emit(text)


func _finish_fail(message: String) -> void:
	_busy = false
	_round = 0
	_rollback_incomplete()
	_set_state("idle")
	failed.emit(message)


## 中断时把「有 tool_calls 却没收齐 tool 回复」的尾巴剪掉，避免下一次请求 400。
func _rollback_incomplete() -> void:
	while not history.is_empty():
		var row = history[history.size() - 1]
		if row is Dictionary and str(row.get("role", "")) == "tool":
			history.pop_back()
			continue
		if row is Dictionary and row.has("tool_calls"):
			history.pop_back()
			continue
		break


func _set_state(value: String) -> void:
	if _state == value:
		return
	_state = value
	state_changed.emit(_state)


# ---- Persona and config helpers ---------------------------------------------


func _load_persona() -> void:
	_persona = {}
	_system = FALLBACK_SYSTEM
	if not FileAccess.file_exists(PERSONA_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(PERSONA_PATH))
	if not (parsed is Dictionary):
		return
	_persona = parsed
	var text := str(parsed.get("system_prompt", "")).strip_edges()
	if text != "":
		_system = text


func _normalize() -> void:
	config["api_key"] = str(config["api_key"]).strip_edges()
	var base_url := str(config["base_url"]).strip_edges()
	if base_url == "":
		base_url = DEFAULT_BASE
	config["base_url"] = base_url.rstrip("/")
	var model := str(config["model"]).strip_edges()
	config["model"] = model if model != "" else DEFAULT_MODEL


# ---- Failures are reported in plain Chinese, never with the key -------------


func _network_reason(result: int) -> String:
	match result:
		HTTPRequest.RESULT_CANT_RESOLVE:
			return "连不上服务器（域名解析失败）"
		HTTPRequest.RESULT_CANT_CONNECT:
			return "连不上服务器（网络不可用）"
		HTTPRequest.RESULT_CONNECTION_ERROR:
			return "连接断了，等一下再试"
		HTTPRequest.RESULT_TIMEOUT:
			return "请求超时（30 秒）"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "HTTPS 握手失败"
	return "网络请求失败（%d）" % result


func _http_reason(code: int, data: Dictionary) -> String:
	if code == 401:
		return "API Key 不对（401）"
	if code == 402:
		return "DeepSeek 余额不足（402）"
	if code == 429:
		return "请求太频繁，等一会儿（429）"
	if code >= 500:
		return "DeepSeek 服务器出问题（%d）" % code
	var detail := ""
	var error = data.get("error")
	if error is Dictionary:
		detail = str(error.get("message", "")).strip_edges()
		if detail.length() > 80:
			detail = detail.left(80)
	if detail != "":
		return "服务器返回 %d：%s" % [code, detail]
	return "服务器返回 %d" % code
