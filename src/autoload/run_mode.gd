@tool
extends Node

# 解析 cmdline user args（`--` 之后的部分），暴露运行模式给所有 autoload / scene。
# 必须排在 autoload 列表最前面：BackendRuntimeClient 会在 _ready 查它，所以要先就绪。
#
# 支持参数（在 `godot ... --` 后面写）：
#   --mode runtime|client       默认 client
#   --town <id>                 默认 town_001
#   --port <int>                runtime 监听端口，默认 7777
#   --connect <host:port>       client 连接目标，默认 127.0.0.1:7777
#   --backend-ws <url>          可选，覆盖 BackendRuntimeClient 默认地址
#   --INIT                      runtime 启动时把旧 state.db 归档到 backend/data/archive/
#                               （按时间戳命名），再新建空 state.db，便于事后分析每一局

const DEFAULT_MODE := "client"
const DEFAULT_TOWN := "town_001"
const DEFAULT_PORT := 7777
const DEFAULT_CONNECT := "127.0.0.1:7777"

var mode: String = DEFAULT_MODE
var town_id: String = DEFAULT_TOWN
var port: int = DEFAULT_PORT
var connect_host: String = "127.0.0.1"
var connect_port: int = DEFAULT_PORT
var backend_ws_override: String = ""
var reset_db: bool = false


func _enter_tree() -> void:
	_parse(OS.get_cmdline_user_args())


func is_runtime() -> bool:
	return mode == "runtime"


func is_client() -> bool:
	return mode == "client"


func _parse(args: PackedStringArray) -> void:
	var i := 0
	while i < args.size():
		var arg := args[i]
		match arg:
			"--mode":
				if i + 1 < args.size():
					mode = args[i + 1]
					i += 1
			"--town":
				if i + 1 < args.size():
					town_id = args[i + 1]
					i += 1
			"--port":
				if i + 1 < args.size():
					port = int(args[i + 1])
					i += 1
			"--connect":
				if i + 1 < args.size():
					_parse_connect(args[i + 1])
					i += 1
			"--backend-ws":
				if i + 1 < args.size():
					backend_ws_override = args[i + 1]
					i += 1
			"--INIT":
				reset_db = true
			_:
				push_warning("[RunMode] unknown arg: %s" % arg)
		i += 1
	if mode != "runtime" and mode != "client":
		push_warning("[RunMode] invalid mode '%s', falling back to '%s'" % [mode, DEFAULT_MODE])
		mode = DEFAULT_MODE


func _parse_connect(value: String) -> void:
	var parts := value.split(":")
	if parts.size() == 2:
		connect_host = parts[0]
		connect_port = int(parts[1])
	else:
		connect_host = value
		connect_port = DEFAULT_PORT
