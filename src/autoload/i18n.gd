extends Node

# i18n catalog loader：启动时把 res://data/i18n/<locale>/*.json 全部读进来、扁平化
# 成 dot-separated key、注册到 TranslationServer。代码里所有用户/游戏可见字符串都
# 走 tr("ui.farm.title") / tr("npc.oren_vale.name") 这种 key。
# prompts.json 也走这里：backend prompt catalog 与 UI 共享同一份 dict
# （例如 prompt.context.proficiency.skill.* 同时被 LLM prompt 和角色面板复用）。
#
# Locale 优先级：cmdline --locale > env GAME_LOCALE > "zh"。fallback 链 locale→zh→key。
#
# 必须排在 RunMode 之后、其它 autoload 之前——其它 autoload _init 里调 tr() 需要
# 翻译表已就绪。

const I18N_DIR := "res://data/i18n"
const SOURCE_LOCALE := "zh"
const SUPPORTED_LOCALES := ["zh", "en"]
const DOMAINS := [
	"ui", "items", "materials", "shapes", "verbs", "workstations", "containers", "reactions",
	"npcs", "locations", "skills", "groups", "attributes", "symptoms",
	"tools", "errors", "prompts",
]

var locale: String = SOURCE_LOCALE


func _enter_tree() -> void:
	locale = _resolve_locale()
	_load_all_locales()
	TranslationServer.set_locale(locale)


func backend_locale() -> String:
	# 同样的 locale 串发给后端，用作 LLM prompt / 错误文本解析。
	return locale


func _resolve_locale() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--locale="):
			return _validate(arg.substr("--locale=".length()))
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--locale" and i + 1 < args.size():
			return _validate(args[i + 1])
	var env_val := OS.get_environment("GAME_LOCALE")
	if not env_val.is_empty():
		return _validate(env_val)
	return SOURCE_LOCALE


func _validate(candidate: String) -> String:
	var c := candidate.strip_edges().to_lower()
	if SUPPORTED_LOCALES.has(c):
		return c
	push_warning("[I18n] unsupported locale '%s', falling back to %s" % [c, SOURCE_LOCALE])
	return SOURCE_LOCALE


func _load_all_locales() -> void:
	for loc in SUPPORTED_LOCALES:
		_load_locale(loc)


func _load_locale(loc: String) -> void:
	var translation := Translation.new()
	translation.locale = loc
	for domain in DOMAINS:
		var path := "%s/%s/%s.json" % [I18N_DIR, loc, domain]
		var dict := _read_json(path)
		if dict.is_empty():
			continue
		# domain 文件名只是组织用，不参与 key——JSON 自带顶层 namespace
		# (items.json 顶层应是 "item": {...}，flatten 后 = item.<id>.name)
		var flat := _flatten("", dict)
		for key in flat:
			translation.add_message(key, flat[key])
	TranslationServer.add_translation(translation)


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("[I18n] cannot open %s" % path)
		return {}
	var raw := file.get_as_text()
	file.close()
	if raw.strip_edges().is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[I18n] %s is not a JSON object" % path)
		return {}
	return parsed as Dictionary


func _flatten(prefix: String, src: Dictionary, out: Dictionary = {}) -> Dictionary:
	for k in src.keys():
		var key := "%s.%s" % [prefix, str(k)] if prefix != "" else str(k)
		var v: Variant = src[k]
		match typeof(v):
			TYPE_DICTIONARY:
				_flatten(key, v as Dictionary, out)
			TYPE_ARRAY:
				var arr: Array = v as Array
				for i in arr.size():
					var item: Variant = arr[i]
					var idx_key := "%s.%d" % [key, i]
					if typeof(item) == TYPE_DICTIONARY:
						_flatten(idx_key, item as Dictionary, out)
					else:
						out[idx_key] = String(item)
			_:
				out[key] = String(v)
	return out
