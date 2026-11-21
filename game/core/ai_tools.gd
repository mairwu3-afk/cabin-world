extends RefCounted
## The nine in-world tools offered to the model, in OpenAI function format.
## Every executor maps onto a code path this project already has (see the comment on each one).
## The APK has no Node bridge, so a tool that needs host-side data work says so
## ({"ok": false, "error": "未接通：..."}) instead of inventing state.
##
## Owner: ai-core. Callers: core/ai_client.gd (autoload AI). Chat UI never touches this file.

const DEFAULT_ACTOR := "xiaojingyu"
const MAX_BUY := 5
## 简称到场景 id 一律以 core/world_data.gd 的 WorldData.SPACE_SCENE 为准（含 xjhome），
## 不再写死一份：上游那份把 home 指到 qianxia-home，本工程里实际是她自己的房间。
const HOME_ALIASES := ["xjhome", "home"]

var host: Node ## the AI autoload, so this RefCounted can reach the SceneTree


func _init(owner_node: Node) -> void:
	host = owner_node


## OpenAI tools array. Pure data, safe to call from anywhere.
static func schemas() -> Array:
	return [
		{"type": "function", "function": {
			"name": "cabin_go",
			"description": "去小屋里的某个房间：公园、小卖部、小鲸鱼家/大肥鱼家、电玩城、汤屋、餐厅。",
			"parameters": {"type": "object", "properties": {
				"scene": {"type": "string", "description": "房间 id 或简称：home/park/shop/arcade/onsen/restaurant，或 qianxia-park 这样的完整 id"},
			}, "required": ["scene"]},
		}},
		{"type": "function", "function": {
			"name": "cabin_use",
			"description": "用一下屋里的家具或物件，比如床、鱼缸、画架、电脑。",
			"parameters": {"type": "object", "properties": {
				"object": {"type": "string", "description": "家具 id 或名字，例如 whale_bed、鱼缸"},
			}, "required": ["object"]},
		}},
		{"type": "function", "function": {
			"name": "cabin_buy",
			"description": "在小卖部买吃的喝的，花零花钱。",
			"parameters": {"type": "object", "properties": {
				"product": {"type": "string", "description": "商品 id，例如 bread、hot_milk、fishcookie"},
				"count": {"type": "integer", "description": "买几个，1~5", "minimum": 1, "maximum": 5},
			}, "required": ["product"]},
		}},
		{"type": "function", "function": {
			"name": "cabin_eat",
			"description": "吃或喝包里已有的东西。",
			"parameters": {"type": "object", "properties": {
				"food": {"type": "string", "description": "食物 id，例如 bread、hot_milk"},
			}, "required": ["food"]},
		}},
		{"type": "function", "function": {
			"name": "cabin_sleep",
			"description": "去床上睡一会儿。",
			"parameters": {"type": "object", "properties": {
				"hours": {"type": "number", "description": "打算睡多久，0.5~24 小时"},
			}, "required": []},
		}},
		{"type": "function", "function": {
			"name": "cabin_pet",
			"description": "摸摸她的头。",
			"parameters": {"type": "object", "properties": {}, "required": []},
		}},
		{"type": "function", "function": {
			"name": "cabin_give",
			"description": "送她一件东西，会放进她的包里。",
			"parameters": {"type": "object", "properties": {
				"item": {"type": "string", "description": "商品 id，例如 fishcookie、choco"},
			}, "required": ["item"]},
		}},
		{"type": "function", "function": {
			"name": "cabin_fish",
			"description": "去河边钓鱼，钓多久。",
			"parameters": {"type": "object", "properties": {
				"minutes": {"type": "integer", "description": "钓多久，1~180 分钟", "minimum": 1, "maximum": 180},
			}, "required": []},
		}},
		{"type": "function", "function": {
			"name": "cabin_status",
			"description": "看自己现在的状态：时间、地点、天气、心情、饱食、口渴、零花钱、好感、钓鱼记录。",
			"parameters": {"type": "object", "properties": {}, "required": []},
		}},
	]


func call_tool(name: String, args: Dictionary) -> Dictionary:
	match name:
		"cabin_go": return cabin_go(args)
		"cabin_use": return cabin_use(args)
		"cabin_buy": return cabin_buy(args)
		"cabin_eat": return cabin_eat(args)
		"cabin_sleep": return cabin_sleep(args)
		"cabin_pet": return cabin_pet(args)
		"cabin_give": return cabin_give(args)
		"cabin_fish": return cabin_fish(args)
		"cabin_status": return cabin_status(args)
	push_warning("AI tool: unknown name " + name)
	return _fail("没有这个动作")


# ---- Tools -------------------------------------------------------------------


## cabin_go → main.gd _show_room() (the same call the top bar uses) and
## Character.walk_order() (the same frame the bridge sends as walk.go), so she really walks over.
func cabin_go(args: Dictionary) -> Dictionary:
	var scene := str(args.get("scene", "")).strip_edges()
	if scene == "":
		return _fail("没说要去的房间")
	var main := _main()
	if main == null:
		return _fail("小屋还没起来")
	var rooms = main.get("rooms")
	if not (rooms is Dictionary):
		return _fail("找不到房间表")
	var wanted := _resolve_scene(scene)
	if wanted == "" or not rooms.has(wanted):
		return _fail("没有这个房间：%s" % scene)
	main.set("follow", -1)
	main.call("_show_room", wanted)
	var character := _character()
	if character != null:
		character.call("walk_order", {"type": "walk.go", "id": "ai-%d" % Time.get_ticks_msec(), "actor": _actor(), "scene": wanted})
	return {"ok": true, "scene": wanted, "note": "去" + _scene_label(wanted)}


## cabin_use → WorldData.objects lookup, then the Economy "use_record" op —
## the same economy.do op the bridge sends after a furniture use. The effect itself is host data work,
## so without the host only the record lands.
func cabin_use(args: Dictionary) -> Dictionary:
	var needle := str(args.get("object", "")).strip_edges()
	if needle == "":
		return _fail("没说要用的家具")
	var row := _object_row(needle)
	if row.is_empty():
		return _fail("没找到这个家具：%s" % needle)
	var object_id := str(row.get("id", ""))
	var product := str(row.get("name", object_id))
	var reply := _economy({"op": "use_record", "objectId": object_id, "use": "use", "label": product})
	if not bool(reply.get("ok", false)):
		return _fail(str(reply.get("error", "用不了")))
	## APK 侧没有宿主，只能落使用记录；照实说「记下了」，别让模型宣称家具已经起了效果
	var out := {"ok": true, "object": object_id, "name": product, "note": "只记下了这次使用，家具本身的效果要靠游戏里点"}
	var description := str(row.get("description", ""))
	if description != "":
		out["description"] = description
	return out


## cabin_buy → the Economy "buy" op, one call per item (Economy.answer() applies and saves it locally).
func cabin_buy(args: Dictionary) -> Dictionary:
	var product := str(args.get("product", "")).strip_edges()
	if product == "":
		return _fail("没说买什么")
	var count := clampi(int(args.get("count", 1)), 1, MAX_BUY)
	var bought := 0
	var coins := -1
	var last_error := ""
	for _i in count:
		var reply := _economy({"op": "buy", "product": product})
		if not bool(reply.get("ok", false)):
			last_error = str(reply.get("error", "买不了"))
			break
		bought += 1
		var state = reply.get("state")
		if state is Dictionary:
			var wallet = state.get("wallet")
			if wallet is Dictionary and wallet.has("coins"):
				coins = int(wallet.get("coins"))
	if bought == 0:
		return _fail(last_error if last_error != "" else "买不了")
	var out := {"ok": true, "product": product, "count": bought}
	if coins >= 0:
		out["note"] = "还剩 %d 块零花钱" % coins
	if last_error != "":
		var note := str(out.get("note", ""))
		out["note"] = (note + "；" if note != "" else "") + last_error
	return out


## cabin_eat → the Economy "consume" op; the game itself runs Life.experience() for the body effect.
func cabin_eat(args: Dictionary) -> Dictionary:
	var food := str(args.get("food", "")).strip_edges()
	if food == "":
		return _fail("没说吃什么")
	var reply := _economy({"op": "consume", "product": food, "kind": "eaten", "space": _space_of_scene(_view_scene())})
	if not bool(reply.get("ok", false)):
		return _fail(str(reply.get("error", "吃不了")))
	var lines = reply.get("lines")
	return {"ok": true, "food": food, "lines": lines if lines is Array else []}


## cabin_sleep → Body.bed_command("sleep"), the same landing point the host's body.sleep flow uses.
## A bed plan needs a synced body, so without the host this stays 未接通.
func cabin_sleep(args: Dictionary) -> Dictionary:
	var actor := _actor()
	if actor == "":
		return _fail("找不到住户")
	if not Body.known(actor):
		return _not_wired("睡觉要身体状态先同步（宿主在线）")
	var hours := clampf(float(args.get("hours", 8)), 0.5, 24.0)
	var ok: bool = Body.of(actor).bed_command("sleep", "ai", SharedFeed.now_ms())
	if not ok:
		return _fail("她已经躺下了，或者没找到床")
	return {"ok": true, "note": "去床上睡了，约 %.1f 小时（世界时钟继续走）" % hours}


## cabin_pet → Character.poke(), the same call clicking her in the room makes.
## 好感记账在宿主侧，离线这里只做即时反应。
func cabin_pet(_args: Dictionary) -> Dictionary:
	var character := _character()
	if character == null:
		return _fail("她不在这个房间")
	character.call("poke")
	return {"ok": true, "note": "伸手摸了摸她的头", "mood": str(character.get("mood_word"))}


## cabin_give → the Economy "gift_in" op (a product id landing in her bag).
## 社交记录与好感由宿主生成；离线只落包。
func cabin_give(args: Dictionary) -> Dictionary:
	var item := str(args.get("item", "")).strip_edges()
	if item == "":
		return _fail("没说送什么")
	var reply := _economy({"op": "gift_in", "product": item})
	if not bool(reply.get("ok", false)):
		return _fail(str(reply.get("error", "送不了")))
	return {"ok": true, "item": item, "note": "收进包里了"}


## cabin_fish → the Economy "play" op with use "fish"; Life.play_outcome() rolls locally.
## minutes is a hint only: the APK does not own the world clock.
func cabin_fish(args: Dictionary) -> Dictionary:
	var minutes := clampi(int(args.get("minutes", 20)), 1, 180)
	var reply := _economy({"op": "play", "use": "fish", "umbrella": false})
	if not bool(reply.get("ok", false)):
		return _fail(str(reply.get("error", "钓不了")))
	var out := {"ok": true, "minutes": minutes, "lines": reply.get("lines") if reply.get("lines") is Array else []}
	var outcome = reply.get("outcome")
	if outcome is Dictionary:
		out["outcome"] = outcome
	return out


## cabin_status → read-only summary from Life (feeling_now / mood_of / hunger_of / thirst_of /
## bond_word) over Economy's stored state, plus the SharedFeed clock and weather.
func cabin_status(_args: Dictionary) -> Dictionary:
	var actor := _actor()
	if actor == "":
		return _fail("找不到住户")
	var now := SharedFeed.now_ms()
	var person := Residents.person(actor)
	var saved = Economy.people.get(actor)
	var feeling := Life.feeling_now(saved.get("feeling") if saved is Dictionary else null, now)
	var life_state = saved.get("life") if saved is Dictionary else null
	var merged: Dictionary = Life.merged(life_state, now)
	var bond: Dictionary = merged.get("bond", {}) if merged.get("bond") is Dictionary else {}
	var records: Dictionary = merged.get("records", {}) if merged.get("records") is Dictionary else {}
	var fish: Dictionary = records.get("fish", {}) if records.get("fish") is Dictionary else {}
	var closeness := float(bond.get("closeness", 0))
	var mood: Dictionary = Life.mood_of(_who(actor), feeling, life_state, _weather(), now, false)
	var coins := 0
	if saved is Dictionary:
		var wallet = saved.get("wallet")
		if wallet is Dictionary:
			coins = int(wallet.get("coins", 0))
	return {
		"ok": true,
		"who": str(person.get("name", "大肥鱼")),
		"time": "%s %s" % [_day(), _clock_text(now)],
		"scene": _scene_label(_view_scene()),
		"weather": _weather_text(),
		"mood": str(mood.get("word", "平静")),
		"joy": roundi(float(feeling.get("joy", 0))),
		"energy": roundi(float(feeling.get("energy", 0))),
		"satiety": roundi(float(feeling.get("satiety", 0))),
		"hydration": roundi(float(feeling.get("hydration", 0))),
		"hunger": Life.hunger_of(float(feeling.get("satiety", 0))),
		"thirst": Life.thirst_of(float(feeling.get("hydration", 0))),
		"bond": {"word": Life.bond_word(closeness), "closeness": roundi(closeness)},
		"coins": coins,
		"fishing": {"count": int(fish.get("count", 0)), "best": str(fish.get("bestName", ""))},
	}


# ---- Shared plumbing ---------------------------------------------------------


## Runs an economy.do frame through Economy.answer(), the same entry the bridge calls.
func _economy(frame: Dictionary) -> Dictionary:
	var actor := _actor()
	if actor == "":
		return _fail("找不到住户")
	var request := frame.duplicate()
	request["type"] = "economy.do"
	request["actor"] = actor
	request["id"] = "ai-%d-%d" % [Time.get_ticks_msec(), randi() % 100000]
	if not request.has("now"):
		request["now"] = SharedFeed.now_ms()
	if not request.has("who"):
		request["who"] = _who(actor)
	if not request.has("day"):
		request["day"] = _day()
	if not request.has("weather"):
		request["weather"] = _weather()
	var reply = Economy.answer(request)
	return reply if reply is Dictionary else _fail("经济系统没回应")


func _main() -> Node:
	if host == null or not is_instance_valid(host) or not host.is_inside_tree():
		return null
	return host.get_tree().current_scene


## The player's resident: whoever the camera follows, otherwise the first resident.
func _actor() -> String:
	var main := _main()
	if main != null:
		var chars = main.get("characters")
		var follow = main.get("follow")
		var index := int(follow) if follow is int else -1
		if chars is Array and index >= 0 and index < chars.size() and chars[index] != null:
			var key := str(chars[index].get("key"))
			if key != "":
				return key
	var people: Array = Residents.people()
	if not people.is_empty() and people[0] is Dictionary:
		return str(people[0].get("key", DEFAULT_ACTOR))
	return DEFAULT_ACTOR


func _character() -> Node:
	var main := _main()
	if main == null:
		return null
	var chars = main.get("characters")
	if not (chars is Array) or chars.is_empty():
		return null
	var key := _actor()
	for character in chars:
		if character != null and str(character.get("key")) == key:
			return character
	return null ## 别退回到 chars[0]：那会摸到/作用到别的住户


func _who(actor: String) -> String:
	var person := Residents.person(actor)
	return str(person.get("flavor", actor)) if not person.is_empty() else actor


func _object_row(needle: String) -> Dictionary:
	for row in WorldData.objects:
		if not (row is Dictionary):
			continue
		var id := str(row.get("id", ""))
		var name := str(row.get("name", ""))
		if id == needle or name == needle:
			return row
		if id != "" and id.contains(needle):
			return row
		if name != "" and name.contains(needle):
			return row
	return {}


func _view_scene() -> String:
	var main := _main()
	if main == null:
		return ""
	return str(main.get("view_scene"))


func _scene_label(scene: String) -> String:
	if scene == "":
		return "原地"
	var info = WorldData.scenes.get(scene)
	if info is Dictionary and str(info.get("name", "")) != "":
		return str(info.get("name"))
	return scene


func _space_of_scene(scene: String) -> String:
	for space in WorldData.SPACE_SCENE:
		if str(WorldData.SPACE_SCENE[space]) == scene:
			return str(space)
	return ""


## 把模型给的东西（id / 简称 / 中文房间名）解析成真实场景 id；认不出就返回 ""。
func _resolve_scene(needle: String) -> String:
	var n := needle.strip_edges()
	if n == "":
		return ""
	if WorldData.scenes.has(n):
		return n
	var low := n.to_lower()
	if WorldData.SPACE_SCENE.has(low):
		var mapped := str(WorldData.SPACE_SCENE[low])
		if WorldData.scenes.has(mapped):
			return mapped
		## 旧表把 home 指到已经不存在的 qianxia-home；回落到她自己的房间
		if low == "home":
			for alias in HOME_ALIASES:
				var alt := str(WorldData.SPACE_SCENE.get(alias, ""))
				if alt != "" and WorldData.scenes.has(alt):
					return alt
			if WorldData.scenes.has("xiaojingyu-home"):
				return "xiaojingyu-home"
		return ""
	## 中文显示名反查（公园 / 小卖部 / 大肥鱼家 / 电玩城 / 汤屋 / 餐厅）
	for id in WorldData.scenes:
		var info = WorldData.scenes[id]
		if info is Dictionary:
			var label := str(info.get("name", ""))
			if label != "" and (label == n or label.contains(n) or n.contains(label)):
				return id
	return ""


func _day() -> String:
	return Time.get_date_string_from_unix_time(int(SharedFeed.now_ms() / 1000.0) + 28800)


func _clock_text(now: float) -> String:
	var stamp := Time.get_datetime_dict_from_unix_time(int(now / 1000.0) + 28800)
	return "%s %02d:%02d" % [str(Life.WEEK[int(stamp.get("weekday", 0))]), int(stamp.get("hour", 0)), int(stamp.get("minute", 0))]


func _weather() -> Dictionary:
	var weather = SharedFeed.weather
	return weather if weather is Dictionary else {}


func _weather_text() -> String:
	var weather := _weather()
	for key in ["word", "text", "sky", "kind"]:
		if str(weather.get(key, "")) != "":
			return str(weather.get(key))
	return "不知道"


func _fail(text: String) -> Dictionary:
	return {"ok": false, "error": text}


func _not_wired(why: String) -> Dictionary:
	return {"ok": false, "error": "未接通：" + why}
