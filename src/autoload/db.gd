extends Node

# Godot server 直连的 SQLite。**只在 RunMode.is_runtime() (headless server)
# 进程激活**——player client 不直连 DB，所有跨网状态走 Godot multiplayer / RPC。
#
# 文件位置：`backend/data/state.db`（monorepo 布局沿用，物理位置不重要）。
#
# Schema 所有权：
#   - **Godot 拥有 game-world 表**：character_groups / world_events /
#     runtime_sessions。这些 CREATE 在本文件 `_GAME_WORLD_SCHEMA` 里，boot
#     时执行（`CREATE TABLE IF NOT EXISTS`，幂等）。
#   - backend 拥有 brain 表：action_log / runtime_storage /
#     agent_sessions / agent_session_messages。schema
#     在 `backend/src/db/schema.ts`，由 backend boot 时建。
#
# 设计原则：游戏运行不依赖 backend。Godot server 单独启动也能跑（NPC 没有大脑，
# 但世界、权限、事件持久化全部正常）。详见
# [[feedback_backend_not_game_db_owner]]。
#
# 用法：
#   var groups: Array = Db.get_character_groups("oren_vale")
#   var ok: bool      = Db.is_member_of("player_1", "blacksmith_shop")
#
# 路径解析：
#   - 优先 OS env `AI_GAMES_DB_PATH`（绝对或相对项目根都行）
#   - 默认相对 godot project 根的 `backend/data/state.db`

const _DEFAULT_REL_PATH := "backend/data/state.db"
const _NPCS_JSON_REL_PATH := "backend/data/town/npcs.json"
# 共享 player 模板：新玩家创角的初始属性（背包/钱包/熟练度）真值，和 npcs.json 同目录。
# backend 同一文件读 soul/knowledge_books 给 AI 接管 seed memory（见 memory-service.ts）。
const _PLAYER_TEMPLATE_REL_PATH := "backend/data/town/player-template.json"
const GOD_GROUP := "god"
const _INITIAL_GAME_HOUR := 6
const _INITIAL_GAME_SECONDS := float(_INITIAL_GAME_HOUR) * 3600.0
const _MORNING_START_GAME_MINUTE := _INITIAL_GAME_HOUR * 60
const _MIN_SLEEP_NEEDED_HOURS := 8
const _MAX_SLEEP_NEEDED_HOURS := 10
const _DEFAULT_INITIAL_WAKE_TIME := "06:00"
const _MORNING_INITIAL_HUNGER := 70.0
const _MORNING_REST_DECAY_PER_AWAKE_HOUR := 2.0
const _STARTER_INVENTORY_SLOT_COUNT := 20
const _STARTER_INVENTORY_STACK_MAX := 99

# Godot 拥有 schema 的 game-world 表。boot 时按顺序执行；`IF NOT EXISTS`
# 幂等。新增表/索引直接加这里（不要加到 backend schema.ts）。
const _GAME_WORLD_SCHEMA: Array[String] = [
	"""CREATE TABLE IF NOT EXISTS character_groups (
		townId TEXT NOT NULL,
		characterId TEXT NOT NULL,
		groupId TEXT NOT NULL,
		joinedAt TEXT NOT NULL,
		source TEXT,
		PRIMARY KEY (townId, characterId, groupId)
	)""",
	"CREATE INDEX IF NOT EXISTS idx_groups_town_group ON character_groups (townId, groupId)",
	"CREATE INDEX IF NOT EXISTS idx_groups_town_char ON character_groups (townId, characterId)",

	"""CREATE TABLE IF NOT EXISTS world_events (
		id TEXT PRIMARY KEY,
		townId TEXT NOT NULL,
		type TEXT NOT NULL,
		actorId TEXT,
		spokenText TEXT,
		data TEXT,
		occurredAt TEXT NOT NULL,
		createdAt TEXT NOT NULL,
		gameTime TEXT
	)""",
	"CREATE INDEX IF NOT EXISTS idx_events_town_created ON world_events (townId, createdAt DESC)",
	"CREATE INDEX IF NOT EXISTS idx_events_town_type_created ON world_events (townId, type, createdAt DESC)",
	"CREATE INDEX IF NOT EXISTS idx_events_type_created ON world_events (type, createdAt DESC)",

	"""CREATE TABLE IF NOT EXISTS runtime_sessions (
		rowid INTEGER PRIMARY KEY AUTOINCREMENT,
		townId TEXT NOT NULL,
		instanceId TEXT NOT NULL,
		connectedAt TEXT NOT NULL,
		disconnectedAt TEXT,
		lastSeenAt TEXT NOT NULL,
		lastAckSeq INTEGER NOT NULL
	)""",
	"CREATE INDEX IF NOT EXISTS idx_sessions_town_connected ON runtime_sessions (townId, connectedAt DESC)",

	# town_clock: 每镇 1 行的当前 game time。totalGameSeconds 是真值（其余字段
	# 都从它派生）。GameClock 周期 UPSERT，启动时读回；停机期间 game time 暂停
	# (详见 docs/architecture/state-persistence-plan.md §2.5)。
	"""CREATE TABLE IF NOT EXISTS town_clock (
		townId TEXT PRIMARY KEY,
		totalGameSeconds REAL NOT NULL,
		savedAt TEXT NOT NULL
	)""",

	# character_states: 角色当前态真值（位姿 / 数值 / 装备 / statuses）。
	# 每角色一行；存在即代表"该角色已被持久化过"——start-up seed（npcs.json /
	# Player STARTER_KIT）在该行存在时跳过。复原顺序：scene 静态 spawn → _ready
	# 调 Db.take_character_state 拿这一行覆盖默认。
	"""CREATE TABLE IF NOT EXISTS character_states (
		townId TEXT NOT NULL,
		characterId TEXT NOT NULL,
		currentLocationId TEXT,
		posX REAL, posY REAL, posZ REAL,
		rotY REAL,
		animState TEXT,
		hp REAL NOT NULL,
		maxHp REAL NOT NULL DEFAULT 100.0,
		stamina REAL NOT NULL,
		maxStamina REAL NOT NULL DEFAULT 100.0,
		hunger REAL NOT NULL,
		maxHunger REAL NOT NULL DEFAULT 100.0,
		rest REAL NOT NULL DEFAULT 100.0,
		maxRest REAL NOT NULL DEFAULT 100.0,
		drunk REAL NOT NULL DEFAULT 0.0,
		sickness REAL NOT NULL DEFAULT 0.0,
		drunkTier TEXT NOT NULL DEFAULT '',
		sicknessTier TEXT NOT NULL DEFAULT '',
		sleepNeededHours REAL NOT NULL DEFAULT 0.0,
		temperature REAL NOT NULL,
		burning INTEGER NOT NULL DEFAULT 0,
		alive INTEGER NOT NULL DEFAULT 1,
		equippedRightHand TEXT,
		equippedLeftHand TEXT,
		equippedBody TEXT,
		equippedHead TEXT,
		activeStatuses TEXT,
		silverCentiBalance INTEGER NOT NULL DEFAULT 0,
		-- currentActivity*：旁人能直接看出来的"身体动作"真值。
		-- kind 是 slug 枚举（using_workstation / working_at_farm / ...），target 是关联 entity 的 slug
		-- （workstation_def_id / farm_id / ...）。idle / 空字符串 = 没在做特殊动作。
		-- 由各 action runner 在 enter/exit 状态时调 update_character_activity / clear_character_activity 写。
		-- Backend perception 直接读这两列即可，不再去 workstation/farm 表反查。
		currentActivityKind TEXT,
		currentActivityTarget TEXT,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, characterId)
	)""",
	"CREATE INDEX IF NOT EXISTS idx_character_states_town_alive ON character_states (townId, alive)",

	# item_instances: 背包 / 装备 / 容器（含货架）/ 预留地面物品。ownerKind 用
	# 'character'（背包）和 'container'（容器+货架统一），ownerKind='world' 列预留给后续地面玩法。
	# listingPriceCenti: 货架陈列标价（centi 银），null = 普通容器/未定价。仅展示，付钱靠 trade/give。
	#
	# Schema 三层（见 project_item_state_architecture）：
	#   reaction 涌现身份（generate 冻结）：shapeType / tags / materials / physicsProps
	#   可变 aspect state（null = 此物没该 aspect）：containerAmount / containerContent /
	#     freshnessTier / freshnessAgeHours / durability
	#   效果数据：baseEffects（reaction generate 时定）/ displayedEffects（Phase 2 GDScript
	#     applicator 算后写入；Phase 1 列保留但写入空）
	#
	# 旧的 customProperties JSON bag 已废弃 —— 每字段语义明确、有 typed 列。
	"""CREATE TABLE IF NOT EXISTS item_instances (
		id TEXT PRIMARY KEY,
		townId TEXT NOT NULL,
		itemDefId TEXT NOT NULL,
		ownerKind TEXT NOT NULL,
		ownerId TEXT,
		locationId TEXT,
		posX REAL, posY REAL, posZ REAL,
		slotIndex INTEGER,

		stackCount INTEGER NOT NULL,
		quality INTEGER NOT NULL,

		shapeType TEXT NOT NULL,
		tags TEXT NOT NULL,
		materials TEXT NOT NULL,
		physicsProps TEXT,

		containerAmount REAL,
		containerContent TEXT,
		transformAge REAL,
		transformSettleHour REAL,
		fermentCeiling INTEGER,
		freshnessTier INTEGER,
		freshnessAgeHours REAL,
		durability INTEGER,

		baseEffects TEXT,
		displayedEffects TEXT,

		listingPriceCenti INTEGER,

		createdAt TEXT NOT NULL,
		updatedAt TEXT NOT NULL
	)""",
	"CREATE INDEX IF NOT EXISTS idx_items_town_owner ON item_instances (townId, ownerKind, ownerId)",
	"CREATE INDEX IF NOT EXISTS idx_items_town_location ON item_instances (townId, locationId)",
	"""CREATE UNIQUE INDEX IF NOT EXISTS idx_items_char_slot
		ON item_instances (townId, ownerKind, ownerId, slotIndex)
		WHERE ownerKind = 'character'""",
	# 货架已统一为容器（ShelfNode extends ContainerNode），内容物走 ownerKind='container'。
	# 货架陈列的"标价"作为槽位 aspect listingPriceCenti 随 item_instances 一起存，不再有独立 listing 表。
	"""CREATE UNIQUE INDEX IF NOT EXISTS idx_items_container_slot
		ON item_instances (townId, ownerKind, ownerId, slotIndex)
		WHERE ownerKind = 'container'""",

	# trade_offers: offer_trade/respond_to_trade 的 pending 状态真值。
	# offerJson/requestJson 保留 LLM 文本，requestedShelfItemsJson 存结构化的 listing+数量。
	"""CREATE TABLE IF NOT EXISTS trade_offers (
		id TEXT PRIMARY KEY,
		townId TEXT NOT NULL,
		fromCharacterId TEXT NOT NULL,
		toCharacterId TEXT NOT NULL,
		offerJson TEXT NOT NULL,
		requestJson TEXT NOT NULL,
		shelfListingIdsJson TEXT,
		requestedShelfItemsJson TEXT,
		status TEXT NOT NULL,
		createdAt TEXT NOT NULL,
		updatedAt TEXT NOT NULL,
		respondedAt TEXT
	)""",
	"CREATE INDEX IF NOT EXISTS idx_trade_offers_pending_from ON trade_offers (townId, fromCharacterId, status, createdAt DESC)",
	"CREATE INDEX IF NOT EXISTS idx_trade_offers_pending_to ON trade_offers (townId, toCharacterId, status, createdAt DESC)",

	# farm_states: 整片田级别的湿度 / pest 计数（每 farm 一行）。
	# pestCountToday / lastProcessedDay 按 game-day 重置由 FarmGroup 自己管。
	# locationId / totalSlots 是 boot 时 seed 的静态信息：locationId 让 backend 把 farm_id
	# （短，如"1号农田"）翻成 location_markers 里的全名（"灰石农圃1号农田"）；totalSlots = scene
	# 里该田的 FarmSlot 子节点总数，让 backend 知道"全田多少格"（farm_plots 只记被种过的格）。
	# cropsSeeded：标记该田是否已应用过 boot 初始种植（TownWorld._seed_initial_crops）。
	# 1 = 一次性 seed 已跑过；玩家全收完 → 田仍标 1，不会下次启动又被填满。
	"""CREATE TABLE IF NOT EXISTS farm_states (
		townId TEXT NOT NULL,
		farmId TEXT NOT NULL,
		locationId TEXT,
		totalSlots INTEGER NOT NULL DEFAULT 0,
		moisture REAL NOT NULL,
		pestCountToday INTEGER NOT NULL DEFAULT 0,
		lastProcessedDay INTEGER NOT NULL DEFAULT -1,
		cropsSeeded INTEGER NOT NULL DEFAULT 0,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, farmId)
	)""",

	# farm_plots: 每 plot 一行。varietyId IS NULL → 空地（暂不存行也行，但留行
	# 让"空 plot 的历史"也能被表达）。stage 由 Godot 算（hydrate / tick / harvest 都过
	# Lua compute_stage）后写盘——backend 直接 SELECT 取，不再镜像公式 / variety
	# catalog。值始终落 generic id（seed/sprout/vegetative/flowering/ripe），中文显示由
	# 两边各自读 i18n。
	"""CREATE TABLE IF NOT EXISTS farm_plots (
		townId TEXT NOT NULL,
		farmId TEXT NOT NULL,
		plotIndex INTEGER NOT NULL,
		varietyId TEXT,
		spawnedAtGameHour INTEGER,
		stage TEXT,
		careScoreSum REAL,
		careScoreCount INTEGER,
		harvestsDone INTEGER,
		hasPest INTEGER,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, farmId, plotIndex)
	)""",
	"CREATE INDEX IF NOT EXISTS idx_farm_plots_town_farm ON farm_plots (townId, farmId)",

	# mine_state: 每个矿场一行。
	# currentP 是每次挥镐固定的产出概率，由 Mines autoload 按 mine 类型种入。
	# attemptsThisHour / yieldThisHour 仅作运行时监控/分析用，不影响 currentP。
	"""CREATE TABLE IF NOT EXISTS mine_state (
		townId TEXT NOT NULL,
		mineId TEXT NOT NULL,
		currentP REAL NOT NULL,
		attemptsThisHour INTEGER NOT NULL DEFAULT 0,
		yieldThisHour INTEGER NOT NULL DEFAULT 0,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, mineId)
	)""",

	# container_seeds: 容器是否已应用过 starting_inventory。row 存在即"已 seed 一次"，
	# 不再重复（即便容器被清空）。类似 character_states 的"被持久化过"语义。
	"""CREATE TABLE IF NOT EXISTS container_seeds (
		townId TEXT NOT NULL,
		containerId TEXT NOT NULL,
		seededAt TEXT NOT NULL,
		PRIMARY KEY (townId, containerId)
	)""",

	# mining_log: 矿工每次 dig 成功的产出留痕。append-only，按 character + day 求和算工资。
	"""CREATE TABLE IF NOT EXISTS mining_log (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		townId TEXT NOT NULL,
		characterId TEXT NOT NULL,
		gameDay INTEGER NOT NULL,
		gameHour INTEGER NOT NULL,
		oreType TEXT NOT NULL,
		qty INTEGER NOT NULL,
		createdAt TEXT NOT NULL
	)""",
	"CREATE INDEX IF NOT EXISTS idx_mining_log_char_day ON mining_log (townId, characterId, gameDay)",
	"CREATE INDEX IF NOT EXISTS idx_mining_log_char_id ON mining_log (townId, characterId, id)",

	# agent_ledgers: 角色专属虚拟账册。LLM 通过 write/read 工具的脏检查路径写入（如玛格达的
	# "王室薪水记录"）。entry 是 LLM 自由文本。read 时按 (characterId, ledgerName) 全 SELECT
	# 拼成完整文本返回；写时 append-only 不覆盖。
	"""CREATE TABLE IF NOT EXISTS agent_ledgers (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		townId TEXT NOT NULL,
		characterId TEXT NOT NULL,
		ledgerName TEXT NOT NULL,
		gameDay INTEGER NOT NULL,
		gameHour INTEGER NOT NULL,
		title TEXT,
		entry TEXT NOT NULL,
		createdAt TEXT NOT NULL
	)""",
	"CREATE INDEX IF NOT EXISTS idx_agent_ledgers_owner ON agent_ledgers (townId, characterId, ledgerName, id)",

	# workstation_states: 场景里 WorkstationNode 的静态配置（定义 id / 位置 / owner_group / verbs / 模式）
	# 与运行时占用（currentOperatorId / currentVerb / busy）。Backend 用作 perception 拼 context 的真值；
	# Godot 自身运行时不读这张表（scene + Workstations autoload 是 godot 端真值）。
	# 静态字段 boot 时由 TownWorld 通过 save_workstation_state 整行 UPSERT；
	# 运行时占用由 WorkstationNode.try_acquire/release 通过 set_workstation_occupants 同步。
	# 多占场景（Workstation.max_concurrent_users > 1）下 currentOperatorId 写 NULL——
	# 列具体人名既不准也无决策价值，busy 仍能表达"是否有人在用"。
	# displayName 不存这里——名字 source-of-truth 是 data/i18n/<locale>/workstations.json，
	# Godot UI 走 workstation_node.display_name getter，backend 走 DisplayNameResolver.workstation()。
	"""CREATE TABLE IF NOT EXISTS workstation_states (
		townId TEXT NOT NULL,
		workstationNodeId TEXT NOT NULL,
		workstationDefId TEXT NOT NULL,
		locationId TEXT,
		ownerGroup TEXT,
		posX REAL, posY REAL, posZ REAL,
		interactionMode TEXT,
		slotCount INTEGER NOT NULL DEFAULT 0,
		verbs TEXT,
		currentOperatorId TEXT,
		currentVerb TEXT,
		busy INTEGER NOT NULL DEFAULT 0,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, workstationNodeId)
	)""",

	# container_states: 场景里 ContainerNode 的静态配置。container_seeds 跟踪是否已 seed
	# starting_inventory，而本表是给 backend perception 看的"容器存在于此 + 容量 + 钥匙要求"。
	# 内容物在 item_instances (ownerKind='container', ownerId=containerId)。
	# 当前未跟踪 locationId（容器没有归属字段；backend 可按 pos 关联到 location_markers）。
	# displayName 不存这里——参见 workstation_states 注释，容器同理走 i18n containers.json。
	"""CREATE TABLE IF NOT EXISTS container_states (
		townId TEXT NOT NULL,
		containerId TEXT NOT NULL,
		lockItemId TEXT,
		ownerGroup TEXT,
		slotCount INTEGER NOT NULL DEFAULT 0,
		interactionRadius REAL,
		posX REAL, posY REAL, posZ REAL,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, containerId)
	)""",

	# shelves: 场景里 ShelfNode 的静态配置（位置 / owner_group / 容量 / 交互半径）。仅作"这个容器是货架"
	# 的标记 + 命名来源。货架已统一为容器（ShelfNode extends ContainerNode），内容物走 item_instances
	# (ownerKind='container')，标价走槽位 listingPriceCenti。Backend 按本表 shelfId 查内容 + 标价。
	# displayName 不存这里——参见 workstation_states 注释，货架同理走 i18n locations.json。
	"""CREATE TABLE IF NOT EXISTS shelves (
		townId TEXT NOT NULL,
		shelfId TEXT NOT NULL,
		ownerGroup TEXT,
		locationId TEXT,
		slotCount INTEGER NOT NULL DEFAULT 0,
		interactionRadius REAL,
		posX REAL, posY REAL, posZ REAL,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, shelfId)
	)""",

	# item_defs: Items autoload 的静态目录 dump。Backend 没法读 .tres，需要这张表才能
	# 在 inventory / shelf 渲染时拼"基础功效"等模板级信息。
	#
	# baseEffects 是 typed JSON dict（如 `{"hunger":30,"stamina":5}`），**不**存预渲染
	# 字符串 —— 渲染由 backend agent-shared/item-display/ 模块（Phase 3）处理。
	# displayName 不存：name 走 i18n catalog（data/i18n/<locale>/items.json），backend
	# 通过 NameResolver 拿翻译，避免双源。
	# staticJson 装"渲染需要的模板级数值"（capacity / max_durability / max_stack 等），
	# 按字段加，结构由 town_world.gd dump 处 + backend item-display 模块约定。
	# Boot 时全量 UPSERT 覆盖；item def 改了 .tres 后 server 重启即生效。
	"""CREATE TABLE IF NOT EXISTS item_defs (
		townId TEXT NOT NULL,
		itemDefId TEXT NOT NULL,
		kind TEXT,
		baseEffects TEXT,
		staticJson TEXT,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, itemDefId)
	)""",

	# location_markers: TownWorld 从 Positions 下 Marker3D 树和 WorkstationNode anchor 合算出来的
	# 逻辑地点。Backend 用作 perception 中"附近的地点"来源；ownerGroup 只作为归属元数据返回。
	# posX/Y/Z 用首个 anchor 的世界坐标；isWorkstation=1 时表示该地点由 WorkstationNode 锚定（well 等）。
	# displayName 不存这里——参见 workstation_states 注释，地点同理走 i18n locations.json。
	"""CREATE TABLE IF NOT EXISTS location_markers (
		townId TEXT NOT NULL,
		locationId TEXT NOT NULL,
		parentLocationId TEXT,
		ownerGroup TEXT,
		posX REAL, posY REAL, posZ REAL,
		isWorkstation INTEGER NOT NULL DEFAULT 0,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, locationId)
	)""",

	# player_accounts: 玩家登录名 → 稳定 characterId 的映射。login UI 输入 name，server
	# 查这张表拿对应 characterId（不存在则生成 player_<8hex>）。name 是 UNIQUE，避免两个
	# 玩家撞名；characterId 也是 UNIQUE，被 character_states / item_instances / 各 agent 表
	# 引用，永不复用。改 name（rename）不会引起任何级联 —— characterId 不动。
	"""CREATE TABLE IF NOT EXISTS player_accounts (
		townId TEXT NOT NULL,
		name TEXT NOT NULL,
		characterId TEXT NOT NULL,
		createdAt TEXT NOT NULL,
		PRIMARY KEY (townId, name)
	)""",
	"CREATE UNIQUE INDEX IF NOT EXISTS idx_player_accounts_character ON player_accounts (townId, characterId)",

	# npc_proficiency: 角色对每个 skill_id 的熟练度 0-100。NPC 初值由 npcs.json
	# 的 `proficiency` 字段 seed（仅当行不存在时，玩家进度不会被覆盖）；Player
	# 没有 seed，从 0 起步，靠 craft 攒。
	# 唯一写者：workstation_action_runner._commit_active（见 docs/proficiency_system.md）。
	"""CREATE TABLE IF NOT EXISTS npc_proficiency (
		townId TEXT NOT NULL,
		characterId TEXT NOT NULL,
		skillId TEXT NOT NULL,
		value REAL NOT NULL,
		updatedAt TEXT NOT NULL,
		PRIMARY KEY (townId, characterId, skillId)
	)""",
	"CREATE INDEX IF NOT EXISTS idx_proficiency_town_char ON npc_proficiency (townId, characterId)",
]

var _db: Variant = null   # SQLite 实例；类型是 GDExtension 注入的，写 Variant 避免 IDE 红线

# Boot 时一次性 SELECT 进内存的真值缓存。各节点 _ready 时 take_* 拿走自己那份。
# 写路径不走 cache，直接 INSERT/UPDATE → 简单且 single-source。
var _character_states_cache: Dictionary = {}        # characterId -> Dictionary
var _inventory_cache: Dictionary = {}               # characterId -> Dictionary{slotIndex: slot dict}
var _container_inventory_cache: Dictionary = {}      # containerId -> Dictionary{slotIndex: slot dict}
var _farm_states_cache: Dictionary = {}             # farmId -> Dictionary
var _farm_plots_cache: Dictionary = {}              # farmId -> Dictionary{plotIndex: row dict}


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	if not RunMode.is_runtime():
		# client 端不开 DB；如果有节点误调 Db.* 会因为 _db == null 早 fail
		set_process(false)
		return
	_open()


func _open() -> void:
	# 用 ClassDB 取 SQLite 类，避免硬依赖 IDE 解析；GDExtension 没装时给清晰报错
	if not ClassDB.class_exists("SQLite"):
		push_error("[Db] SQLite class not registered — 跑 ./scripts/install-sqlite-gdextension 安装 GDExtension 后重启编辑器/server")
		return
	_db = ClassDB.instantiate("SQLite")
	if _db == null:
		push_error("[Db] failed to instantiate SQLite")
		return
	var path := _resolve_db_path()
	if RunMode.reset_db:
		_reset_database_files(path)
	# 父目录可能不存在（fresh checkout，backend 从未启动过），先建好
	var dir_err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		push_warning("[Db] mkdir %s failed: %s" % [path.get_base_dir(), dir_err])
	_db.path = path
	_db.foreign_keys = false
	# open_db 在文件不存在时会创建空 DB；这是预期路径——Godot 是 game-world
	# 表的 schema owner，backend 不在场也要能 boot
	if not _db.open_db():
		push_error("[Db] failed to open %s" % path)
		_db = null
		return
	# WAL：reader/writer 并发安全（backend 也会用同一个文件）
	_db.query("PRAGMA journal_mode = WAL")
	_db.query("PRAGMA synchronous = NORMAL")
	_db.query("PRAGMA busy_timeout = 5000")
	# 建/确认 game-world 表存在
	for stmt in _GAME_WORLD_SCHEMA:
		if not _db.query(stmt):
			push_error("[Db] schema bootstrap failed: %s" % _db.error_message)
	_apply_schema_migrations()
	# 首次种子：character_groups 对当前 town 为空时，从 npcs.json 每个 NPC 的 groups[] 灌入
	_ensure_groups_seeded(RunMode.town_id)
	_ensure_town_clock_seeded(RunMode.town_id)
	_ensure_npc_character_states_seeded(RunMode.town_id)
	_ensure_proficiency_seeded(RunMode.town_id)
	# Hydrate caches：把 character_states / item_instances / farm_states / farm_plots
	# 整表 SELECT 进内存 dict，等各 scene 节点 _ready 时 take_* / all_* 拿走。
	_hydrate_caches(RunMode.town_id)


func _apply_schema_migrations() -> void:
	_ensure_column("character_states", "rest", "REAL NOT NULL DEFAULT 100.0")
	# 损伤层：drunk 醉酒 / sickness 生病累计值（0..100）。老行加列后默认 0 = 清醒健康。
	_ensure_column("character_states", "drunk", "REAL NOT NULL DEFAULT 0.0")
	_ensure_column("character_states", "sickness", "REAL NOT NULL DEFAULT 0.0")
	# 派生档位 key（Godot 单一写者，随 raw 一起持久化；backend SELECT-only 渲染）。
	_ensure_column("character_states", "drunkTier", "TEXT NOT NULL DEFAULT ''")
	_ensure_column("character_states", "sicknessTier", "TEXT NOT NULL DEFAULT ''")
	_ensure_column("character_states", "sleepNeededHours", "REAL NOT NULL DEFAULT 0.0")
	# 属性上限：Character 节点 export 的 max_* 值随 buff/装备/等级可能动态变。
	# 默认 100 与 Character 基类的默认 export 对齐；新角色 save 前老行会用 default。
	_ensure_column("character_states", "maxHp", "REAL NOT NULL DEFAULT 100.0")
	_ensure_column("character_states", "maxStamina", "REAL NOT NULL DEFAULT 100.0")
	_ensure_column("character_states", "maxHunger", "REAL NOT NULL DEFAULT 100.0")
	_ensure_column("character_states", "maxRest", "REAL NOT NULL DEFAULT 100.0")
	# currentActivity*：见 character_states schema 注释。老 DB 加列后默认 NULL = idle。
	_ensure_column("character_states", "currentActivityKind", "TEXT")
	_ensure_column("character_states", "currentActivityTarget", "TEXT")
	# 启动时把所有角色的 activity 清零——这是 volatile "当下"状态，server crash 时
	# 残留的旧值不该带到下一次启动；runner 会在重新进入 working 时重新填。
	if _db != null:
		_db.query("UPDATE character_states SET currentActivityKind = NULL, currentActivityTarget = NULL")
	# 老 DB 加 farm_states 静态字段（locationId / totalSlots），boot seed 会随后填值。
	_ensure_column("farm_states", "locationId", "TEXT")
	_ensure_column("farm_states", "totalSlots", "INTEGER NOT NULL DEFAULT 0")
	# cropsSeeded：一次性 boot 初始种植标记。老 DB 默认 0 → 下次启动会被首次 seed。
	_ensure_column("farm_states", "cropsSeeded", "INTEGER NOT NULL DEFAULT 0")
	# Container 字段统一：keyItemId 重命名 lockItemId（与基类 WorkstationNode.lock_item_id 对齐），
	# 加 ownerGroup 让 backend 直接过滤 group。老 DB 已有 keyItemId 时改名；新 DB 直接走新 schema。
	_rename_column_if_present("container_states", "keyItemId", "lockItemId")
	_ensure_column("container_states", "ownerGroup", "TEXT")
	# world_events.text 重命名为 spokenText（语义收窄到"实际说出/输入的文字"）。
	# 旧 DB 把列改名，新 DB 直接 CREATE 走新名。
	_rename_column_if_present("world_events", "text", "spokenText")
	# item_defs.staticJson：Item template 渲染需要的模板级数值（capacity / max_durability /
	# max_stack 等）。加新字段只在 town_world.gd dump 处 + backend item-display 处加一行。
	_ensure_column("item_defs", "staticJson", "TEXT")
	# item_defs.baseEffects：typed JSON dict（{"hunger":30,"stamina":5}）。老 DB 用 effectsLine
	# 预渲染字符串，现已废弃；为兼容老 DB 新加 baseEffects 列，effectsLine 旧值不再读。
	_ensure_column("item_defs", "baseEffects", "TEXT")
	# item_instances：typed 平铺列替代 customProperties JSON bag。老 DB 加缺的列，
	# 老行 shapeType / tags / materials NULL 时 _item_row_to_slot 给空值兜底。
	_ensure_column("item_instances", "shapeType", "TEXT")
	_ensure_column("item_instances", "tags", "TEXT")
	_ensure_column("item_instances", "materials", "TEXT")
	_ensure_column("item_instances", "physicsProps", "TEXT")
	_ensure_column("item_instances", "containerAmount", "REAL")
	_ensure_column("item_instances", "containerContent", "TEXT")
	_ensure_column("item_instances", "transformAge", "REAL")
	_ensure_column("item_instances", "transformSettleHour", "REAL")
	_ensure_column("item_instances", "fermentCeiling", "INTEGER")
	_ensure_column("item_instances", "freshnessTier", "INTEGER")
	_ensure_column("item_instances", "freshnessAgeHours", "REAL")
	_ensure_column("item_instances", "baseEffects", "TEXT")
	_ensure_column("item_instances", "displayedEffects", "TEXT")
	_ensure_column("item_instances", "listingPriceCenti", "INTEGER")
	# farm_plots.stage：把派生量 stage 落盘，让 backend 直接读不再镜像公式 / variety
	# catalog。Godot tick / hydrate / harvest 算完 stage 后随 persist 一起写。
	_ensure_column("farm_plots", "stage", "TEXT")


# 检测老列存在且新列不在时改名。SQLite 3.25+ 支持 ALTER TABLE RENAME COLUMN。
func _rename_column_if_present(table_name: String, old_name: String, new_name: String) -> void:
	if _db == null:
		return
	if not _db.query("PRAGMA table_info(%s)" % table_name):
		push_error("[Db] PRAGMA table_info(%s) failed: %s" % [table_name, _db.error_message])
		return
	var has_old := false
	var has_new := false
	for row_v in (_db.query_result as Array):
		var row: Dictionary = row_v as Dictionary
		var n := str(row.get("name", ""))
		if n == old_name:
			has_old = true
		elif n == new_name:
			has_new = true
	if has_new or not has_old:
		return
	if not _db.query("ALTER TABLE %s RENAME COLUMN %s TO %s" % [table_name, old_name, new_name]):
		push_error("[Db] ALTER TABLE %s RENAME COLUMN %s TO %s failed: %s" % [table_name, old_name, new_name, _db.error_message])


func _ensure_column(table_name: String, column_name: String, definition: String) -> void:
	if _db == null:
		return
	if not _db.query("PRAGMA table_info(%s)" % table_name):
		push_error("[Db] PRAGMA table_info(%s) failed: %s" % [table_name, _db.error_message])
		return
	for row_v in (_db.query_result as Array):
		var row: Dictionary = row_v as Dictionary
		if str(row.get("name", "")) == column_name:
			return
	if not _db.query("ALTER TABLE %s ADD COLUMN %s %s" % [table_name, column_name, definition]):
		push_error("[Db] ALTER TABLE %s ADD COLUMN %s failed: %s" % [table_name, column_name, _db.error_message])


# 从 backend/data/town/npcs.json 读每个 NPC 的 groups[] 灌入 character_groups。
# 幂等：表里该 town 已有任何行就跳过——避免 dev 期手动改组成员后被 seed 覆盖。
# JSON 结构：{ "<npc_id>": { ..., "groups": ["<group_id>", ...], ... }, ... }
# 设计：NPC 身份/初始归属真值在 npcs.json（项目规则 "NPC 配置真值在 npcs.json"），
# 运行时真值在 SQLite character_groups。groups.json 已废弃。
func _ensure_groups_seeded(town_id: String) -> void:
	if _db == null or town_id.is_empty():
		return
	# 用 raw query 跑 LIMIT 1 存在性检查；godot-sqlite 的 select_rows 不接 LIMIT
	if not _db.query("SELECT rowid FROM character_groups WHERE townId = '%s' LIMIT 1" % _esc(town_id)):
		push_error("[Db] seed existence check failed: %s" % _db.error_message)
		return
	if not (_db.query_result as Array).is_empty():
		return
	var json_path := _resolve_npcs_json_path()
	if not FileAccess.file_exists(json_path):
		push_warning("[Db] npcs.json not found at %s — skip seed" % json_path)
		return
	var raw := FileAccess.get_file_as_string(json_path)
	if raw.is_empty():
		push_warning("[Db] npcs.json empty — skip seed")
		return
	var parsed: Variant = JSON.parse_string(raw)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[Db] npcs.json is not a JSON object")
		return
	var now := Time.get_datetime_string_from_system(true)
	for npc_id in parsed.keys():
		var def: Variant = parsed[npc_id]
		if typeof(def) != TYPE_DICTIONARY:
			continue
		var groups_v: Variant = def.get("groups", [])
		if typeof(groups_v) != TYPE_ARRAY:
			continue
		for group_id in groups_v:
			var sql := "INSERT OR IGNORE INTO character_groups (townId, characterId, groupId, joinedAt, source) VALUES ('%s', '%s', '%s', '%s', 'seed')" % [
				_esc(town_id), _esc(str(npc_id)), _esc(str(group_id)), now,
			]
			_db.query(sql)


func _resolve_npcs_json_path() -> String:
	var project_root := ProjectSettings.globalize_path("res://")
	return project_root.path_join(_NPCS_JSON_REL_PATH)


func _ensure_town_clock_seeded(town_id: String) -> void:
	if _db == null or town_id.is_empty():
		return
	if not _db.query("SELECT 1 FROM town_clock WHERE townId = '%s' LIMIT 1" % _esc(town_id)):
		push_warning("[Db] town_clock seed check failed: %s" % _db.error_message)
		return
	if not (_db.query_result as Array).is_empty():
		return
	save_town_clock_seconds(_INITIAL_GAME_SECONDS)


func _ensure_npc_character_states_seeded(town_id: String) -> void:
	if _db == null or town_id.is_empty():
		return
	var json_path := _resolve_npcs_json_path()
	if not FileAccess.file_exists(json_path):
		push_warning("[Db] npcs.json not found at %s — skip character state seed" % json_path)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Db] npcs.json is not a JSON object — skip character state seed")
		return
	var npcs: Dictionary = parsed as Dictionary
	for npc_id_v in npcs.keys():
		var npc_id := str(npc_id_v)
		if npc_id.is_empty() or _has_character_state(town_id, npc_id):
			continue
		var conf_v: Variant = npcs.get(npc_id, {})
		if typeof(conf_v) != TYPE_DICTIONARY:
			continue
		var conf: Dictionary = conf_v as Dictionary
		var sleep_needed := _deterministic_sleep_needed_hours(npc_id)
		save_character_state(npc_id, _initial_character_state_fields(npc_id, conf, sleep_needed))
		_seed_character_inventory(npc_id, conf.get("starting_inventory", []))


# 把 npcs.json 里 proficiency 字段（{skill_id: value}）按 (town, character, skill)
# INSERT OR IGNORE 进 npc_proficiency。已存在的行不动 —— 玩家进度 / NPC 已涨上去
# 的数值不会被启动 seed 抹掉。新加 skill 到 npcs.json 时，下次 boot 会补上缺的行。
func _ensure_proficiency_seeded(town_id: String) -> void:
	if _db == null or town_id.is_empty():
		return
	var json_path := _resolve_npcs_json_path()
	if not FileAccess.file_exists(json_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(json_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var npcs: Dictionary = parsed as Dictionary
	var now := Time.get_datetime_string_from_system(true)
	for npc_id_v in npcs.keys():
		var npc_id := str(npc_id_v)
		if npc_id.is_empty():
			continue
		var conf_v: Variant = npcs.get(npc_id, {})
		if typeof(conf_v) != TYPE_DICTIONARY:
			continue
		var prof_v: Variant = (conf_v as Dictionary).get("proficiency", {})
		if typeof(prof_v) != TYPE_DICTIONARY:
			continue
		for skill_id_v in (prof_v as Dictionary).keys():
			var skill_id := str(skill_id_v)
			if skill_id.is_empty():
				continue
			var value := float((prof_v as Dictionary).get(skill_id_v, 0.0))
			var sql := "INSERT OR IGNORE INTO npc_proficiency (townId, characterId, skillId, value, updatedAt) VALUES ('%s', '%s', '%s', %f, '%s')" % [
				_esc(town_id), _esc(npc_id), _esc(skill_id), value, now,
			]
			if not _db.query(sql):
				push_warning("[Db] proficiency seed failed for %s.%s: %s" % [npc_id, skill_id, _db.error_message])


# 返回某角色当前的全部熟练度 {skill_id: value}。无行 → 空 dict（公式按 0 处理 = 生手）。
func get_proficiency_table(character_id: String) -> Dictionary:
	var out: Dictionary = {}
	if _db == null or character_id.is_empty():
		return out
	var where := "townId = '%s' AND characterId = '%s'" % [_esc(RunMode.town_id), _esc(character_id)]
	var rows: Array = _db.select_rows("npc_proficiency", where, ["skillId", "value"])
	for row_v in rows:
		var row: Dictionary = row_v
		out[str(row.get("skillId", ""))] = float(row.get("value", 0.0))
	return out


# UPSERT 单个 skill 的最新数值。value clamp 到 [0, 100]。唯一调用方：
# workstation_action_runner._commit_active（在 craft 完成后）。
func upsert_proficiency(character_id: String, skill_id: String, value: float) -> void:
	if _db == null or character_id.is_empty() or skill_id.is_empty():
		return
	var clamped: float = clampf(value, 0.0, 100.0)
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO npc_proficiency (townId, characterId, skillId, value, updatedAt) VALUES ('%s', '%s', '%s', %f, '%s') ON CONFLICT(townId, characterId, skillId) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id), _esc(character_id), _esc(skill_id), clamped, now,
	]
	if not _db.query(sql):
		push_warning("[Db] proficiency upsert failed for %s.%s: %s" % [character_id, skill_id, _db.error_message])


# 新玩家首次出现时种初始属性，跟 NPC 同源（共享 player 模板）：character_state（含钱包）、
# starter 背包、初始熟练度。_has_character_state 幂等闸门保证只在创角那一次跑——玩家后续
# 玩出来的熟练度/背包都正常持久化，不会被覆盖。未来创角选技能 UI 也只是改这份模板的种子值。
func ensure_player_seeded(character_id: String, sleep_needed_hours: float) -> void:
	if _db == null or character_id.is_empty() or _has_character_state(RunMode.town_id, character_id):
		return
	var template := _load_player_template()
	var conf := {
		"initial_wake_time": _DEFAULT_INITIAL_WAKE_TIME,
		"starting_wallet_silver": float(template.get("starting_wallet_silver", 30.0)),
	}
	save_character_state(character_id, _initial_character_state_fields(character_id, conf, sleep_needed_hours))
	_seed_character_inventory(character_id, template.get("starting_inventory", []))
	_seed_player_proficiency(character_id, template.get("proficiency", {}))


# 按模板 proficiency（{skill_id: value}）INSERT OR IGNORE 进 npc_proficiency。
# tool 开放只看「行是否存在」（见 game-tools/factory.ts isAxisAccessibleTo），所以这一步
# 决定新玩家「会哪些手艺」。0 值合法 = 会但还没练。
func _seed_player_proficiency(character_id: String, prof_v: Variant) -> void:
	if _db == null or character_id.is_empty() or typeof(prof_v) != TYPE_DICTIONARY:
		return
	var now := Time.get_datetime_string_from_system(true)
	for skill_id_v in (prof_v as Dictionary).keys():
		var skill_id := str(skill_id_v)
		if skill_id.is_empty():
			continue
		var value := float((prof_v as Dictionary).get(skill_id_v, 0.0))
		var sql := "INSERT OR IGNORE INTO npc_proficiency (townId, characterId, skillId, value, updatedAt) VALUES ('%s', '%s', '%s', %f, '%s')" % [
			_esc(RunMode.town_id), _esc(character_id), _esc(skill_id), value, now,
		]
		if not _db.query(sql):
			push_warning("[Db] player proficiency seed failed for %s.%s: %s" % [character_id, skill_id, _db.error_message])


var _player_template_cache: Dictionary = {}

func _load_player_template() -> Dictionary:
	if not _player_template_cache.is_empty():
		return _player_template_cache
	var path := ProjectSettings.globalize_path("res://").path_join(_PLAYER_TEMPLATE_REL_PATH)
	if not FileAccess.file_exists(path):
		push_warning("[Db] player-template.json not found at %s — player seed will be empty" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[Db] player-template.json malformed at %s" % path)
		return {}
	_player_template_cache = parsed as Dictionary
	return _player_template_cache


func _has_character_state(town_id: String, character_id: String) -> bool:
	if _db == null or town_id.is_empty() or character_id.is_empty():
		return false
	if not _db.query("SELECT 1 FROM character_states WHERE townId = '%s' AND characterId = '%s' LIMIT 1" % [_esc(town_id), _esc(character_id)]):
		return false
	return not (_db.query_result as Array).is_empty()


func _deterministic_sleep_needed_hours(character_id: String) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(abs(hash(character_id)))
	return float(rng.randi_range(_MIN_SLEEP_NEEDED_HOURS, _MAX_SLEEP_NEEDED_HOURS))


func _initial_character_state_fields(character_id: String, conf: Dictionary, sleep_needed_hours: float) -> Dictionary:
	var wake_minute := maxi(_parse_time_of_day_minutes(conf.get("initial_wake_time", _DEFAULT_INITIAL_WAKE_TIME)), _MORNING_START_GAME_MINUTE)
	var wake_hour := float(wake_minute) / 60.0
	var start_hour := float(_MORNING_START_GAME_MINUTE) / 60.0
	var rest := 100.0
	if wake_minute <= _MORNING_START_GAME_MINUTE:
		rest = clampf(100.0 - (_MORNING_REST_DECAY_PER_AWAKE_HOUR * maxf(start_hour - wake_hour, 0.0)), 0.0, 100.0)
	else:
		var remaining_sleep_hours := float(wake_minute - _MORNING_START_GAME_MINUTE) / 60.0
		var slept_by_start := maxf(sleep_needed_hours - remaining_sleep_hours, 0.0)
		rest = clampf(100.0 * minf(1.0, slept_by_start / maxf(sleep_needed_hours, 0.1)), 0.0, 100.0)
	var hunger := _MORNING_INITIAL_HUNGER
	var stamina := _initial_effective_stamina_max(hunger, rest)
	var statuses := []
	if wake_minute > _MORNING_START_GAME_MINUTE:
		statuses.append({
			"type": "sleeping",
			"started_at": Time.get_ticks_msec() / 1000.0,
			"expires_total_hours": ceili(float(wake_minute) / 60.0),
			"source_id": "initial_wake_time",
		})
	return {
		"currentLocationId": "",
		"posX": 0.0,
		"posY": 0.0,
		"posZ": 0.0,
		"rotY": 0.0,
		"animState": "idle",
		"hp": 100.0,
		"stamina": stamina,
		"hunger": hunger,
		"rest": rest,
		"sleepNeededHours": sleep_needed_hours,
		"temperature": 36.5,
		"burning": false,
		"alive": true,
		"activeStatuses": statuses,
		"silverCentiBalance": maxi(0, int(round(float(conf.get("starting_wallet_silver", 0)) * 100.0))),
	}


func _parse_time_of_day_minutes(value: Variant) -> int:
	if typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT:
		var total := int(value)
		return total if total >= 0 and total < 24 * 60 else -1
	var text := str(value).strip_edges()
	if text.is_empty():
		return -1
	var parts := text.split(":", false)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1
	var hour := int(parts[0])
	var minute := int(parts[1])
	if hour < 0 or hour >= 24 or minute < 0 or minute >= 60:
		return -1
	return hour * 60 + minute


func _initial_effective_stamina_max(hunger: float, rest: float) -> float:
	var result: Variant = MechanicHost.query("physiology", "effective_stamina_max", [
		100.0,
		hunger,
		100.0,
		rest,
		100.0,
	])
	return float(result) if result != null else 100.0


func _seed_character_inventory(character_id: String, entries_v: Variant) -> int:
	if not (entries_v is Array):
		return 0
	var slot_index := 0
	var written := 0
	for entry_v in (entries_v as Array):
		var item_id := ""
		var quantity := 0
		var quality := 100
		if entry_v is Dictionary:
			var entry: Dictionary = entry_v as Dictionary
			item_id = str(entry.get("item_id", entry.get("itemId", "")))
			quantity = int(entry.get("quantity", 0))
			quality = int(entry.get("quality", 100))
		elif entry_v is Array and (entry_v as Array).size() >= 2:
			var entry_arr: Array = entry_v as Array
			item_id = str(entry_arr[0])
			quantity = int(entry_arr[1])
		if item_id.is_empty() or quantity <= 0:
			continue
		if not Items.has_id(item_id):
			push_warning("[Db] starter inventory unknown item '%s' for %s" % [item_id, character_id])
			continue
		var remaining := quantity
		while remaining > 0 and slot_index < _STARTER_INVENTORY_SLOT_COUNT:
			var put := mini(_STARTER_INVENTORY_STACK_MAX, remaining)
			var slot := InventorySlotData.from_template(item_id, quality)
			slot["quantity"] = put
			save_inventory_slot(character_id, slot_index, slot)
			written += 1
			remaining -= put
			slot_index += 1
	return written


func _resolve_db_path() -> String:
	var env_path := OS.get_environment("AI_GAMES_DB_PATH").strip_edges()
	if not env_path.is_empty():
		return ProjectSettings.globalize_path(env_path) if env_path.begins_with("res://") else env_path
	# 项目根的相对路径：globalize_path 把 res:// 转绝对，再 .. 上去找 backend/
	var project_root := ProjectSettings.globalize_path("res://")
	return project_root.path_join(_DEFAULT_REL_PATH)


func _reset_database_files(path: String) -> void:
	# --INIT 不再删除旧 DB，而是把它（连同 -wal/-shm）整套搬到 <base_dir>/archive/，
	# 文件名带 wall-clock 时间戳。便于事后用 sqlite3 cli 翻每一局游戏的数据。
	# 没有旧 DB 时（fresh checkout）直接 no-op，让后续 open_db 创建新空库。
	if not FileAccess.file_exists(path):
		return
	var archive_dir := path.get_base_dir().path_join("archive")
	var mk := DirAccess.make_dir_recursive_absolute(archive_dir)
	if mk != OK and mk != ERR_ALREADY_EXISTS:
		push_error("[Db] --INIT failed to create archive dir %s: %s" % [archive_dir, mk])
		return
	# Time.get_datetime_string_from_system() → "2026-05-26T14:30:12"；
	# 转成 "20260526-143012" 便于排序 + 文件名安全
	var timestamp := Time.get_datetime_string_from_system().replace("-", "").replace(":", "").replace("T", "-")
	var archive_path := archive_dir.path_join("state-%s.db" % timestamp)
	var err := DirAccess.rename_absolute(path, archive_path)
	if err != OK:
		push_error("[Db] --INIT failed to archive %s -> %s: %s" % [path, archive_path, err])
		return
	print("[Db] --INIT archived previous DB to %s" % archive_path)
	# WAL/SHM 是上次进程留下的"待 checkpoint"状态，里面可能含有未合并到主文件的数据；
	# 一并搬到归档位置（保持后缀），确保归档 DB 打开时不丢数据。
	for suffix in ["-wal", "-shm"]:
		var aux_path := "%s%s" % [path, suffix]
		if not FileAccess.file_exists(aux_path):
			continue
		var aux_err := DirAccess.rename_absolute(aux_path, "%s%s" % [archive_path, suffix])
		if aux_err != OK:
			push_warning("[Db] --INIT failed to archive %s: %s" % [aux_path, aux_err])


# ─── Public read API ──────────────────────────────────────────────────

# 角色当前 group id 列表（不过滤 god；caller 自己决定要不要加）。
# DB 没开 / 没记录都返回空数组。
func get_character_groups(character_id: String) -> Array:
	if _db == null or character_id.is_empty():
		return []
	var rows: Array = _db.select_rows("character_groups", "characterId = '%s'" % _esc(character_id), ["groupId"])
	var out: Array = []
	for r in rows:
		out.append(str(r.get("groupId", "")))
	return out


# 是否在某 group 中。"god" group 的成员视为 bypass，命中任何 group 检查都返回 true。
func is_member_of(character_id: String, group_id: String) -> bool:
	if _db == null or character_id.is_empty() or group_id.is_empty():
		return false
	var groups := get_character_groups(character_id)
	if groups.has(GOD_GROUP):
		return true
	return groups.has(group_id)


# 给定 owner_group，判断该角色能否访问仍采用硬权限的资源。
# owner_group 为空 = public，所有人通过。
func can_access(character_id: String, owner_group: String) -> bool:
	if owner_group.is_empty():
		return true
	if _db == null:
		# 权限闸门 fail-closed：判不了就拒绝。can_access 只该 server 调（_db 必非空），
		# 走到这里说明要么在 client 误调、要么 server DB 加载失败——两种都要立刻暴露，
		# 不能静默放行（那会让所有 owner_group 形同虚设）。
		push_error("[Db] can_access 在 _db==null 时被调用 —— 拒绝访问（fail-closed）；caller 应只在 server 调")
		return false
	var groups := get_character_groups(character_id)
	if groups.has(GOD_GROUP):
		return true
	return groups.has(owner_group)


# ─── Public write API（拜师/收徒/dev tool 调用） ──────────────────────

func add_member(character_id: String, group_id: String, source: String = "runtime") -> void:
	if _db == null or character_id.is_empty() or group_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	# INSERT OR IGNORE 跟 backend service 行为一致
	var sql := "INSERT OR IGNORE INTO character_groups (townId, characterId, groupId, joinedAt, source) VALUES ('%s', '%s', '%s', '%s', '%s')" % [
		_esc(RunMode.town_id), _esc(character_id), _esc(group_id), now, _esc(source),
	]
	_db.query(sql)


func remove_member(character_id: String, group_id: String) -> void:
	if _db == null or character_id.is_empty() or group_id.is_empty():
		return
	var sql := "DELETE FROM character_groups WHERE townId = '%s' AND characterId = '%s' AND groupId = '%s'" % [
		_esc(RunMode.town_id), _esc(character_id), _esc(group_id),
	]
	_db.query(sql)


# ─── Public API: player_accounts ──────────────────────────────────────

# 按 login name 拿/建 characterId。name 已存在 → 复用旧 characterId（玩家回归）；
# 否则生成 player_<8hex> + INSERT 一行新账号。返回 {"characterId": String, "isNew": bool}；
# DB 没开或 name 空 → {"characterId": "", "isNew": false}。
#
# UNIQUE(name) 是真值；同名第二个 client 由 town.gd 在 auth 阶段查 Players.is_character_online
# 拒掉（DB 层不区分"在线/离线"，只保证 name↔characterId 一对一）。
func lookup_or_create_player_account(login_name: String) -> Dictionary:
	var empty := {"characterId": "", "isNew": false}
	if _db == null:
		return empty
	var trimmed := login_name.strip_edges()
	if trimmed.is_empty():
		return empty
	if not _db.query("SELECT characterId FROM player_accounts WHERE townId = '%s' AND name = '%s' LIMIT 1" % [_esc(RunMode.town_id), _esc(trimmed)]):
		push_warning("[Db] lookup_or_create_player_account select failed: %s" % _db.error_message)
		return empty
	var rows: Array = _db.query_result as Array
	if not rows.is_empty():
		return {"characterId": str(rows[0].get("characterId", "")), "isNew": false}
	# 新玩家：生成 player_<8hex>，碰撞极小但 UNIQUE 兜底，最多 retry 5 次
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var now := Time.get_datetime_string_from_system(true)
	for attempt in 5:
		var cid := "player_%08x" % rng.randi()
		var insert_sql := "INSERT INTO player_accounts (townId, name, characterId, createdAt) VALUES ('%s', '%s', '%s', '%s')" % [
			_esc(RunMode.town_id), _esc(trimmed), _esc(cid), now,
		]
		if _db.query(insert_sql):
			return {"characterId": cid, "isNew": true}
		# UNIQUE 冲突 = 撞到已有 characterId（极罕见）或 name 抢跑；重读一次 name
		if not _db.query("SELECT characterId FROM player_accounts WHERE townId = '%s' AND name = '%s' LIMIT 1" % [_esc(RunMode.town_id), _esc(trimmed)]):
			continue
		var raced: Array = _db.query_result as Array
		if not raced.is_empty():
			return {"characterId": str(raced[0].get("characterId", "")), "isNew": false}
	push_error("[Db] lookup_or_create_player_account failed after retries: %s" % _db.error_message)
	return empty


# ─── Public API: town_clock ───────────────────────────────────────────

# 当前 town 的累计 game time（秒）。表里没行返回 -1.0，caller 用默认初值。
func get_town_clock_seconds() -> float:
	if _db == null:
		return -1.0
	if not _db.query("SELECT totalGameSeconds FROM town_clock WHERE townId = '%s'" % _esc(RunMode.town_id)):
		push_warning("[Db] get_town_clock_seconds query failed: %s" % _db.error_message)
		return -1.0
	var rows: Array = _db.query_result as Array
	if rows.is_empty():
		return -1.0
	return float(rows[0].get("totalGameSeconds", -1.0))


# UPSERT 当前 town 的 game time。GameClock 周期调（默认每 5 real-sec）。
func save_town_clock_seconds(total_game_seconds: float) -> void:
	if _db == null:
		return
	var now := Time.get_datetime_string_from_system(true)
	# SQLite 3.24+ 的 ON CONFLICT 子句，跟 backend service 用法对齐
	var sql := "INSERT INTO town_clock (townId, totalGameSeconds, savedAt) VALUES ('%s', %f, '%s') ON CONFLICT(townId) DO UPDATE SET totalGameSeconds = excluded.totalGameSeconds, savedAt = excluded.savedAt" % [
		_esc(RunMode.town_id), total_game_seconds, now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_town_clock_seconds failed: %s" % _db.error_message)


# ─── Public API: character_states ─────────────────────────────────────

# 取并消费 character_states cache 行。首次开服 seed 在 Db bootstrap 阶段完成；
# 运行时 caller 只 hydrate，不在 Character / NPC 里补默认状态。
func take_character_state(character_id: String) -> Dictionary:
	if character_id.is_empty():
		return {}
	var row: Variant = _character_states_cache.get(character_id, null)
	if row == null:
		return _select_character_state(character_id)
	_character_states_cache.erase(character_id)
	return row as Dictionary

# UPSERT 当前角色态。fields 期望键：currentLocationId / posX/Y/Z / rotY / animState /
# hp / stamina / hunger / rest / sleepNeededHours / temperature / burning(bool) / alive(bool) / equipped*(4) /
# activeStatuses(Array)。缺字段按 SQL 默认值 / 上一次值（用 COALESCE 兜底太重，
# MVP 先要求 caller 传齐主字段）。
func save_character_state(character_id: String, fields: Dictionary) -> void:
	if _db == null or character_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var statuses_json := JSON.stringify(fields.get("activeStatuses", []))
	var sql := "INSERT INTO character_states (townId, characterId, currentLocationId, posX, posY, posZ, rotY, animState, hp, maxHp, stamina, maxStamina, hunger, maxHunger, rest, maxRest, drunk, sickness, drunkTier, sicknessTier, sleepNeededHours, temperature, burning, alive, equippedRightHand, equippedLeftHand, equippedBody, equippedHead, activeStatuses, silverCentiBalance, updatedAt) VALUES ('%s', '%s', %s, %f, %f, %f, %f, %s, %f, %f, %f, %f, %f, %f, %f, %f, %f, %f, '%s', '%s', %f, %f, %d, %d, %s, %s, %s, %s, %s, %d, '%s') ON CONFLICT(townId, characterId) DO UPDATE SET currentLocationId = excluded.currentLocationId, posX = excluded.posX, posY = excluded.posY, posZ = excluded.posZ, rotY = excluded.rotY, animState = excluded.animState, hp = excluded.hp, maxHp = excluded.maxHp, stamina = excluded.stamina, maxStamina = excluded.maxStamina, hunger = excluded.hunger, maxHunger = excluded.maxHunger, rest = excluded.rest, maxRest = excluded.maxRest, drunk = excluded.drunk, sickness = excluded.sickness, drunkTier = excluded.drunkTier, sicknessTier = excluded.sicknessTier, sleepNeededHours = excluded.sleepNeededHours, temperature = excluded.temperature, burning = excluded.burning, alive = excluded.alive, equippedRightHand = excluded.equippedRightHand, equippedLeftHand = excluded.equippedLeftHand, equippedBody = excluded.equippedBody, equippedHead = excluded.equippedHead, activeStatuses = excluded.activeStatuses, silverCentiBalance = excluded.silverCentiBalance, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id), _esc(character_id),
		_sql_str_or_null(fields.get("currentLocationId", "")),
		float(fields.get("posX", 0.0)), float(fields.get("posY", 0.0)), float(fields.get("posZ", 0.0)),
		float(fields.get("rotY", 0.0)),
		_sql_str_or_null(fields.get("animState", "")),
		float(fields.get("hp", 0.0)), float(fields.get("maxHp", 100.0)),
		float(fields.get("stamina", 0.0)), float(fields.get("maxStamina", 100.0)),
		float(fields.get("hunger", 0.0)), float(fields.get("maxHunger", 100.0)),
		float(fields.get("rest", 0.0)), float(fields.get("maxRest", 100.0)),
		float(fields.get("drunk", 0.0)), float(fields.get("sickness", 0.0)),
		_esc(str(fields.get("drunkTier", ""))), _esc(str(fields.get("sicknessTier", ""))),
		float(fields.get("sleepNeededHours", 0.0)),
		float(fields.get("temperature", 0.0)),
		1 if bool(fields.get("burning", false)) else 0,
		1 if bool(fields.get("alive", true)) else 0,
		_sql_str_or_null(fields.get("equippedRightHand", "")),
		_sql_str_or_null(fields.get("equippedLeftHand", "")),
		_sql_str_or_null(fields.get("equippedBody", "")),
		_sql_str_or_null(fields.get("equippedHead", "")),
		_sql_str_or_null(statuses_json),
		int(fields.get("silverCentiBalance", 0)),
		now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_character_state failed: %s" % _db.error_message)


# 只更新 activity 两列；各 action runner enter/exit 路径调用。比 save_character_state
# 的整行 UPSERT 轻。kind 是 slug 枚举（using_workstation / working_at_farm / ...），target
# 是关联实体 slug（workstation_def_id / farm_id / ...）；target 允许空字符串。
# 角色行尚未持久化时（首次 boot 阶段）静默 noop，下一次 save_character_state 会带空值。
func update_character_activity(character_id: String, kind: String, target: String) -> void:
	if _db == null or character_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "UPDATE character_states SET currentActivityKind = %s, currentActivityTarget = %s, updatedAt = '%s' WHERE townId = '%s' AND characterId = '%s'" % [
		_sql_str_or_null(kind), _sql_str_or_null(target), now,
		_esc(RunMode.town_id), _esc(character_id),
	]
	if not _db.query(sql):
		push_warning("[Db] update_character_activity failed: %s" % _db.error_message)


# 清空 activity。所有结束路径（commit / cancel / 状态变更）都应调用。幂等。
func clear_character_activity(character_id: String) -> void:
	if _db == null or character_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "UPDATE character_states SET currentActivityKind = NULL, currentActivityTarget = NULL, updatedAt = '%s' WHERE townId = '%s' AND characterId = '%s'" % [
		now, _esc(RunMode.town_id), _esc(character_id),
	]
	if not _db.query(sql):
		push_warning("[Db] clear_character_activity failed: %s" % _db.error_message)


# ─── Public API: item_instances（character ownership 部分）────────────

# 取并消费 character 的 inventory cache。返回 Dictionary{slotIndex: slot dict}。
# 空 dict 表示 cache 里没行；caller 自己决定是否 seed。
func take_inventory(character_id: String) -> Dictionary:
	if character_id.is_empty():
		return {}
	var slots: Variant = _inventory_cache.get(character_id, null)
	if slots == null:
		return _select_character_inventory(character_id)
	_inventory_cache.erase(character_id)
	return slots as Dictionary

# 把单 slot 的 instance dict UPSERT 到表里（一槽一行）。slot 为空（item_id="" 或
# quantity<=0）时 DELETE 该行。Caller 负责调；helper 内部不判 character 还是 player。
func save_inventory_slot(character_id: String, slot_index: int, slot: Dictionary) -> void:
	if _db == null or character_id.is_empty():
		return
	var item_id := str(slot.get("item_id", ""))
	var qty := int(slot.get("quantity", 0))
	if item_id.is_empty() or qty <= 0:
		_delete_inventory_slot(character_id, slot_index)
		return
	# 用确定性 id：(town, character, slot)。同 slot 后续写入直接覆盖同一 id，避免
	# 唯一约束 INSERT OR REPLACE 把 createdAt 抹掉。
	var row_id := "%s|%s|%d" % [RunMode.town_id, character_id, slot_index]
	var now := Time.get_datetime_string_from_system(true)
	var sql := _build_item_instance_upsert(row_id, item_id, "character", character_id, "", slot_index, slot, now)
	if not _db.query(sql):
		push_warning("[Db] save_inventory_slot failed: %s" % _db.error_message)


func _delete_inventory_slot(character_id: String, slot_index: int) -> void:
	if _db == null:
		return
	var sql := "DELETE FROM item_instances WHERE townId = '%s' AND ownerKind = 'character' AND ownerId = '%s' AND slotIndex = %d" % [
		_esc(RunMode.town_id), _esc(character_id), slot_index,
	]
	if not _db.query(sql):
		push_warning("[Db] delete_inventory_slot failed: %s" % _db.error_message)


# ─── Public API: containers (item_instances ownerKind='container') ────

# 取走某容器的全部 slot dict（boot 后由 ContainerNode._ready 拿走）。
func take_container_inventory(container_id: String) -> Dictionary:
	if container_id.is_empty():
		return {}
	var slots: Variant = _container_inventory_cache.get(container_id, null)
	if slots == null:
		return {}
	_container_inventory_cache.erase(container_id)
	return slots as Dictionary


# UPSERT 一槽。slot 为空（item_id="" 或 quantity<=0）时 DELETE。
func save_container_slot(container_id: String, slot_index: int, slot: Dictionary) -> void:
	if _db == null or container_id.is_empty():
		return
	var item_id := str(slot.get("item_id", ""))
	var qty := int(slot.get("quantity", 0))
	if item_id.is_empty() or qty <= 0:
		_delete_container_slot(container_id, slot_index)
		return
	var row_id := "%s|container|%s|%d" % [RunMode.town_id, container_id, slot_index]
	var now := Time.get_datetime_string_from_system(true)
	var sql := _build_item_instance_upsert(row_id, item_id, "container", container_id, "", slot_index, slot, now)
	if not _db.query(sql):
		push_warning("[Db] save_container_slot failed: %s" % _db.error_message)


func _delete_container_slot(container_id: String, slot_index: int) -> void:
	if _db == null:
		return
	var sql := "DELETE FROM item_instances WHERE townId = '%s' AND ownerKind = 'container' AND ownerId = '%s' AND slotIndex = %d" % [
		_esc(RunMode.town_id), _esc(container_id), slot_index,
	]
	if not _db.query(sql):
		push_warning("[Db] delete_container_slot failed: %s" % _db.error_message)


# 容器是否已 seed 过 starting_inventory。Containers autoload 在 register 时检查；
# 不存在就 seed + mark_container_seeded，存在就跳过。
func has_seeded_container(container_id: String) -> bool:
	if _db == null or container_id.is_empty():
		return false
	var sql := "SELECT containerId FROM container_seeds WHERE townId = '%s' AND containerId = '%s' LIMIT 1" % [
		_esc(RunMode.town_id), _esc(container_id),
	]
	if not _db.query(sql):
		push_warning("[Db] has_seeded_container failed: %s" % _db.error_message)
		return false
	return _db.query_result.size() > 0


func mark_container_seeded(container_id: String) -> void:
	if _db == null or container_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO container_seeds (townId, containerId, seededAt) VALUES ('%s', '%s', '%s') ON CONFLICT(townId, containerId) DO NOTHING" % [
		_esc(RunMode.town_id), _esc(container_id), now,
	]
	if not _db.query(sql):
		push_warning("[Db] mark_container_seeded failed: %s" % _db.error_message)


# ─── Public API: ground items (item_instances ownerKind='world') ──────
#
# 玩家/NPC 丢弃落在世界里的物品。复用 item_instances 表（ownerKind='world'）；
# 位置写 posX/posY/posZ；不用 slotIndex（恒 0）。id 由 caller 生成（spawn
# 用 "world|<usec>|<rnd>"），保证同 usec 多 spawn 不冲突。
# Spoilage 真值在 slot.freshness_age_hours（已是 typed 列），不另存时间戳。

func save_ground_item(id: String, item_id: String, pos: Vector3, slot: Dictionary) -> void:
	if _db == null or id.is_empty() or item_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := _build_item_instance_upsert(id, item_id, "world", "", "", 0, slot, now, pos)
	if not _db.query(sql):
		push_warning("[Db] save_ground_item failed: %s" % _db.error_message)


func delete_ground_item(id: String) -> void:
	if _db == null or id.is_empty():
		return
	var sql := "DELETE FROM item_instances WHERE townId = '%s' AND ownerKind = 'world' AND id = '%s'" % [
		_esc(RunMode.town_id), _esc(id),
	]
	if not _db.query(sql):
		push_warning("[Db] delete_ground_item failed: %s" % _db.error_message)


# Boot 时 bulk load。返回 Array[Dictionary]，每行 {id, pos: Vector3, slot: Dictionary}。
func all_ground_items() -> Array:
	if _db == null:
		return []
	var sql := "SELECT id, itemDefId, posX, posY, posZ, slotIndex, stackCount, quality, shapeType, tags, materials, physicsProps, containerAmount, containerContent, transformAge, transformSettleHour, fermentCeiling, freshnessTier, freshnessAgeHours, durability, baseEffects, displayedEffects FROM item_instances WHERE townId = '%s' AND ownerKind = 'world'" % _esc(RunMode.town_id)
	if not _db.query(sql):
		push_warning("[Db] all_ground_items failed: %s" % _db.error_message)
		return []
	var out: Array = []
	for row_v in _db.query_result:
		var row: Dictionary = row_v as Dictionary
		var slot := _item_row_to_slot(row)
		if slot.is_empty():
			continue
		out.append({
			"id": str(row.get("id", "")),
			"pos": Vector3(float(row.get("posX", 0.0)), float(row.get("posY", 0.0)), float(row.get("posZ", 0.0))),
			"slot": slot,
		})
	return out


# ─── Public API: mining_log ────────────────────────────

func log_mining(character_id: String, ore_type: String, qty: int, game_day: int, game_hour: int) -> void:
	if _db == null or character_id.is_empty() or ore_type.is_empty() or qty <= 0:
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO mining_log (townId, characterId, gameDay, gameHour, oreType, qty, createdAt) VALUES ('%s', '%s', %d, %d, '%s', %d, '%s')" % [
		_esc(RunMode.town_id), _esc(character_id), game_day, game_hour, _esc(ore_type), qty, now,
	]
	if not _db.query(sql):
		push_warning("[Db] log_mining failed: %s" % _db.error_message)


# 返回 {totals:{ore_type: total_qty}, maxLogId:int}，统计 character 在 last_log_id 之后的 yield。
func sum_mining_after_log_id(character_id: String, last_log_id: int) -> Dictionary:
	if _db == null or character_id.is_empty():
		return {"totals": {}, "maxLogId": last_log_id}
	var sql := "SELECT oreType, SUM(qty) AS total, MAX(id) AS maxLogId FROM mining_log WHERE townId = '%s' AND characterId = '%s' AND id > %d GROUP BY oreType" % [
		_esc(RunMode.town_id), _esc(character_id), maxi(0, last_log_id),
	]
	if not _db.query(sql):
		push_warning("[Db] sum_mining_after_log_id failed: %s" % _db.error_message)
		return {"totals": {}, "maxLogId": last_log_id}
	var totals: Dictionary = {}
	var max_log_id := last_log_id
	for row_v in _db.query_result:
		var row: Dictionary = row_v as Dictionary
		totals[str(row.get("oreType", ""))] = int(row.get("total", 0))
		max_log_id = maxi(max_log_id, int(row.get("maxLogId", last_log_id)))
	return {"totals": totals, "maxLogId": max_log_id}


# 列出最近 N 个 game-day 内所有矿工的逐条流水。read("王室薪水记录") 拼系统真值用。
# 返回 [{characterId, gameDay, gameHour, oreType, qty}, ...]，按 (characterId, id) 排序。
func recent_mining_log(since_game_day: int) -> Array:
	var out: Array = []
	if _db == null:
		return out
	var sql := "SELECT characterId, gameDay, gameHour, oreType, qty FROM mining_log WHERE townId = '%s' AND gameDay >= %d ORDER BY characterId, id" % [
		_esc(RunMode.town_id), since_game_day,
	]
	if not _db.query(sql):
		push_warning("[Db] recent_mining_log failed: %s" % _db.error_message)
		return out
	for row_v in _db.query_result:
		var row: Dictionary = row_v as Dictionary
		out.append({
			"characterId": str(row.get("characterId", "")),
			"gameDay": int(row.get("gameDay", 0)),
			"gameHour": int(row.get("gameHour", 0)),
			"oreType": str(row.get("oreType", "")),
			"qty": int(row.get("qty", 0)),
		})
	return out


# ─── Public API: agent_ledgers ─────────────────────────

func append_agent_ledger(character_id: String, ledger_name: String, title: String, entry: String, game_day: int, game_hour: int) -> bool:
	if _db == null or character_id.is_empty() or ledger_name.is_empty() or entry.is_empty():
		return false
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO agent_ledgers (townId, characterId, ledgerName, gameDay, gameHour, title, entry, createdAt) VALUES ('%s', '%s', '%s', %d, %d, '%s', '%s', '%s')" % [
		_esc(RunMode.town_id), _esc(character_id), _esc(ledger_name), game_day, game_hour, _esc(title), _esc(entry), now,
	]
	if not _db.query(sql):
		push_warning("[Db] append_agent_ledger failed: %s" % _db.error_message)
		return false
	return true


# 按 (characterId, ledgerName) 取全部条目，按 id 升序。返回 [{gameDay, gameHour, title, entry}, ...]
func read_agent_ledger(character_id: String, ledger_name: String) -> Array:
	var out: Array = []
	if _db == null or character_id.is_empty() or ledger_name.is_empty():
		return out
	var sql := "SELECT gameDay, gameHour, title, entry FROM agent_ledgers WHERE townId = '%s' AND characterId = '%s' AND ledgerName = '%s' ORDER BY id" % [
		_esc(RunMode.town_id), _esc(character_id), _esc(ledger_name),
	]
	if not _db.query(sql):
		push_warning("[Db] read_agent_ledger failed: %s" % _db.error_message)
		return out
	for row_v in _db.query_result:
		var row: Dictionary = row_v as Dictionary
		out.append({
			"gameDay": int(row.get("gameDay", 0)),
			"gameHour": int(row.get("gameHour", 0)),
			"title": str(row.get("title", "")),
			"entry": str(row.get("entry", "")),
		})
	return out


# 启动后清理掉场景里不再存在的 container 残留库存。Containers autoload 调。
func prune_orphan_container_storage(valid_container_ids: Array[String]) -> void:
	if _db == null:
		return
	var valid: Array[String] = []
	for cid in valid_container_ids:
		if not cid.is_empty():
			valid.append("'%s'" % _esc(cid))
	var where := "townId = '%s' AND ownerKind = 'container'" % _esc(RunMode.town_id)
	if not valid.is_empty():
		where += " AND ownerId NOT IN (%s)" % ", ".join(valid)
	var sql := "DELETE FROM item_instances WHERE %s" % where
	if not _db.query(sql):
		push_warning("[Db] prune_orphan_container_storage failed: %s" % _db.error_message)


# ─── Public API: trade_offers ────────────────────────────────────────

func create_trade_offer(
	from_character_id: String,
	to_character_id: String,
	offer: Array,
	request: Array,
	shelf_listing_ids: Array = [],
	requested_shelf_items: Array = []
) -> Dictionary:
	if _db == null or from_character_id.is_empty() or to_character_id.is_empty():
		return {}
	var trade_id := "trade_%d" % Time.get_ticks_usec()
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO trade_offers (id, townId, fromCharacterId, toCharacterId, offerJson, requestJson, shelfListingIdsJson, requestedShelfItemsJson, status, createdAt, updatedAt, respondedAt) VALUES ('%s', '%s', '%s', '%s', '%s', '%s', %s, %s, 'pending', '%s', '%s', NULL)" % [
		_esc(trade_id), _esc(RunMode.town_id), _esc(from_character_id), _esc(to_character_id),
		_esc(JSON.stringify(_to_plain_array(offer))),
		_esc(JSON.stringify(_to_plain_array(request))),
		_sql_str_or_null(JSON.stringify(_to_plain_array(shelf_listing_ids))),
		_sql_str_or_null(JSON.stringify(_to_plain_array(requested_shelf_items))),
		now, now,
	]
	if not _db.query(sql):
		push_warning("[Db] create_trade_offer failed: %s" % _db.error_message)
		return {}
	return find_trade_offer(trade_id)


func find_trade_offer(trade_id: String) -> Dictionary:
	if _db == null or trade_id.is_empty():
		return {}
	var sql := "SELECT id, fromCharacterId, toCharacterId, offerJson, requestJson, shelfListingIdsJson, requestedShelfItemsJson, status, createdAt, updatedAt, respondedAt FROM trade_offers WHERE townId = '%s' AND id = '%s' LIMIT 1" % [
		_esc(RunMode.town_id), _esc(trade_id),
	]
	if not _db.query(sql):
		push_warning("[Db] find_trade_offer failed: %s" % _db.error_message)
		return {}
	var rows: Array = _db.query_result as Array
	if rows.is_empty():
		return {}
	return _trade_row_to_snapshot(rows[0] as Dictionary)


func update_trade_offer_status(trade_id: String, status: String) -> void:
	if _db == null or trade_id.is_empty() or status.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var responded_at_sql := "NULL" if status == "pending" else "'%s'" % now
	var sql := "UPDATE trade_offers SET status = '%s', updatedAt = '%s', respondedAt = %s WHERE townId = '%s' AND id = '%s'" % [
		_esc(status), now, responded_at_sql, _esc(RunMode.town_id), _esc(trade_id),
	]
	if not _db.query(sql):
		push_warning("[Db] update_trade_offer_status failed: %s" % _db.error_message)


func pending_trade_snapshots_for_character(character_id: String) -> Array[Dictionary]:
	if _db == null or character_id.is_empty():
		return []
	var sql := "SELECT id, fromCharacterId, toCharacterId, offerJson, requestJson, shelfListingIdsJson, requestedShelfItemsJson, status, createdAt, updatedAt, respondedAt FROM trade_offers WHERE townId = '%s' AND status = 'pending' AND (fromCharacterId = '%s' OR toCharacterId = '%s') ORDER BY createdAt DESC" % [
		_esc(RunMode.town_id), _esc(character_id), _esc(character_id),
	]
	if not _db.query(sql):
		push_warning("[Db] pending_trade_snapshots_for_character failed: %s" % _db.error_message)
		return []
	var out: Array[Dictionary] = []
	for row_v in (_db.query_result as Array):
		out.append(_trade_row_to_snapshot(row_v as Dictionary))
	return out


# 同一对买卖只允许 1 条 pending：offer_trade 前置 check + respond_to_trade 查找入口。
func list_pending_trades_for_pair(buyer_id: String, seller_id: String) -> Array[Dictionary]:
	if _db == null or buyer_id.is_empty() or seller_id.is_empty():
		return []
	var sql := "SELECT id, fromCharacterId, toCharacterId, offerJson, requestJson, shelfListingIdsJson, requestedShelfItemsJson, status, createdAt, updatedAt, respondedAt FROM trade_offers WHERE townId = '%s' AND status = 'pending' AND fromCharacterId = '%s' AND toCharacterId = '%s' ORDER BY createdAt DESC" % [
		_esc(RunMode.town_id), _esc(buyer_id), _esc(seller_id),
	]
	if not _db.query(sql):
		push_warning("[Db] list_pending_trades_for_pair failed: %s" % _db.error_message)
		return []
	var out: Array[Dictionary] = []
	for row_v in (_db.query_result as Array):
		out.append(_trade_row_to_snapshot(row_v as Dictionary))
	return out


func find_pending_trade_for_pair(buyer_id: String, seller_id: String) -> Dictionary:
	var list := list_pending_trades_for_pair(buyer_id, seller_id)
	return list[0] if list.size() > 0 else {}


# 卖家要走开时枚举所有指向自己的 pending，便于一次性取消。
func list_pending_trades_as_seller(seller_id: String) -> Array[Dictionary]:
	if _db == null or seller_id.is_empty():
		return []
	var sql := "SELECT id, fromCharacterId, toCharacterId, offerJson, requestJson, shelfListingIdsJson, requestedShelfItemsJson, status, createdAt, updatedAt, respondedAt FROM trade_offers WHERE townId = '%s' AND status = 'pending' AND toCharacterId = '%s' ORDER BY createdAt DESC" % [
		_esc(RunMode.town_id), _esc(seller_id),
	]
	if not _db.query(sql):
		push_warning("[Db] list_pending_trades_as_seller failed: %s" % _db.error_message)
		return []
	var out: Array[Dictionary] = []
	for row_v in (_db.query_result as Array):
		out.append(_trade_row_to_snapshot(row_v as Dictionary))
	return out


# ─── Public API: farm_states ──────────────────────────────────────────

# 取并消费 farm_states cache 行。空 dict 表示首次 boot，caller 用 FarmGroup 默认值。
func take_farm_state(farm_id: String) -> Dictionary:
	if farm_id.is_empty():
		return {}
	var row: Variant = _farm_states_cache.get(farm_id, null)
	if row == null:
		return {}
	_farm_states_cache.erase(farm_id)
	return row as Dictionary

func save_farm_state(farm_id: String, moisture: float, pest_count_today: int, last_processed_day: int) -> void:
	if _db == null or farm_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO farm_states (townId, farmId, moisture, pestCountToday, lastProcessedDay, updatedAt) VALUES ('%s', '%s', %f, %d, %d, '%s') ON CONFLICT(townId, farmId) DO UPDATE SET moisture = excluded.moisture, pestCountToday = excluded.pestCountToday, lastProcessedDay = excluded.lastProcessedDay, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id), _esc(farm_id), moisture, pest_count_today, last_processed_day, now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_farm_state failed: %s" % _db.error_message)


# Boot 时一次性写入 farm 静态字段（locationId / totalSlots）。
# 不动 moisture/pest/lastDay —— 老田如果有持久化值会被保留；新田 INSERT 用默认 moisture=0.6。
func seed_farm_static(farm_id: String, location_id: String, total_slots: int) -> void:
	if _db == null or farm_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO farm_states (townId, farmId, locationId, totalSlots, moisture, pestCountToday, lastProcessedDay, updatedAt) VALUES ('%s', '%s', %s, %d, 0.6, 0, -1, '%s') ON CONFLICT(townId, farmId) DO UPDATE SET locationId = excluded.locationId, totalSlots = excluded.totalSlots, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id), _esc(farm_id), _sql_str_or_null(location_id), total_slots, now,
	]
	if not _db.query(sql):
		push_warning("[Db] seed_farm_static failed: %s" % _db.error_message)


# 该 farm 是否已经跑过一次 boot 初始种植。0/缺行 → 还没；1 → 已跑过，不再 seed。
# 直接读 DB（不走 cache）—— cache 在 FarmGroup._ready 里被 take_farm_state 消费掉，
# TownWorld._seed_initial_crops 跑得比 FarmGroup._ready 晚的情况下 cache 已空。
func farm_crops_seeded(farm_id: String) -> bool:
	if _db == null or farm_id.is_empty():
		return false
	var sql := "SELECT cropsSeeded FROM farm_states WHERE townId = '%s' AND farmId = '%s' LIMIT 1" % [
		_esc(RunMode.town_id), _esc(farm_id),
	]
	if not _db.query(sql):
		push_warning("[Db] farm_crops_seeded failed: %s" % _db.error_message)
		return false
	var rows: Array = _db.query_result
	if rows.is_empty():
		return false
	var row: Dictionary = rows[0] as Dictionary
	return int(row.get("cropsSeeded", 0)) != 0


# 写入 cropsSeeded=1。一次性、幂等。
func mark_farm_crops_seeded(farm_id: String) -> void:
	if _db == null or farm_id.is_empty():
		return
	var sql := "UPDATE farm_states SET cropsSeeded = 1 WHERE townId = '%s' AND farmId = '%s'" % [
		_esc(RunMode.town_id), _esc(farm_id),
	]
	if not _db.query(sql):
		push_warning("[Db] mark_farm_crops_seeded failed: %s" % _db.error_message)


# ─── Public API: farm_plots ───────────────────────────────────────────

# 整表 dump。town hydrate 阶段一次性遍历 spawn 所有 saved crops。
# 返回 Dictionary{farmId: Dictionary{plotIndex: row dict}}。
func all_farm_plots() -> Dictionary:
	return _farm_plots_cache.duplicate(true)

# 用 (farmId, plotIndex) UPSERT 一行作物状态。crop=null 字段表示空 plot。
func save_farm_plot(farm_id: String, plot_index: int, fields: Dictionary) -> void:
	if _db == null or farm_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var variety_id := str(fields.get("varietyId", ""))
	var sql := "INSERT INTO farm_plots (townId, farmId, plotIndex, varietyId, spawnedAtGameHour, stage, careScoreSum, careScoreCount, harvestsDone, hasPest, updatedAt) VALUES ('%s', '%s', %d, %s, %d, %s, %f, %d, %d, %d, '%s') ON CONFLICT(townId, farmId, plotIndex) DO UPDATE SET varietyId = excluded.varietyId, spawnedAtGameHour = excluded.spawnedAtGameHour, stage = excluded.stage, careScoreSum = excluded.careScoreSum, careScoreCount = excluded.careScoreCount, harvestsDone = excluded.harvestsDone, hasPest = excluded.hasPest, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id), _esc(farm_id), plot_index,
		_sql_str_or_null(variety_id),
		int(fields.get("spawnedAtGameHour", 0)),
		_sql_str_or_null(str(fields.get("stage", ""))),
		float(fields.get("careScoreSum", 0.0)),
		int(fields.get("careScoreCount", 0)),
		int(fields.get("harvestsDone", 0)),
		1 if bool(fields.get("hasPest", false)) else 0,
		now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_farm_plot failed: %s" % _db.error_message)

# Boot 路径：写 plot 行 + 同步进 _farm_plots_cache。区别于 save_farm_plot
# （只写盘，cache 仅在 Db._ready hydrate 时一次性填）—— 因为 TownWorld._ready
# seed 完之后还要走 town.gd._init_runtime → _hydrate_persisted_crops 读 cache 来
# spawn，所以 cache 必须当场同步，否则刚 seed 的行下一拍不会被 spawn 出来。
func seed_farm_plot(farm_id: String, plot_index: int, fields: Dictionary) -> void:
	if _db == null or farm_id.is_empty():
		return
	save_farm_plot(farm_id, plot_index, fields)
	var bucket: Dictionary = _farm_plots_cache.get(farm_id, {})
	bucket[plot_index] = {
		"varietyId": str(fields.get("varietyId", "")),
		"spawnedAtGameHour": int(fields.get("spawnedAtGameHour", 0)),
		"stage": str(fields.get("stage", "")),
		"careScoreSum": float(fields.get("careScoreSum", 0.0)),
		"careScoreCount": int(fields.get("careScoreCount", 0)),
		"harvestsDone": int(fields.get("harvestsDone", 0)),
		"hasPest": bool(fields.get("hasPest", false)),
	}
	_farm_plots_cache[farm_id] = bucket


# 清空 plot（作物 queue_free / harvest 单收类型时调）。
func clear_farm_plot(farm_id: String, plot_index: int) -> void:
	if _db == null or farm_id.is_empty():
		return
	var sql := "DELETE FROM farm_plots WHERE townId = '%s' AND farmId = '%s' AND plotIndex = %d" % [
		_esc(RunMode.town_id), _esc(farm_id), plot_index,
	]
	if not _db.query(sql):
		push_warning("[Db] clear_farm_plot failed: %s" % _db.error_message)


# ─── Public API: mine_state ───────────────────────────────────────────

# 取一行 mine_state；不存在返回空 dict。Mines autoload 启动时按需 ensure。
func get_mine_state(mine_id: String) -> Dictionary:
	if _db == null or mine_id.is_empty():
		return {}
	var sql := "SELECT mineId, currentP, attemptsThisHour, yieldThisHour FROM mine_state WHERE townId = '%s' AND mineId = '%s'" % [
		_esc(RunMode.town_id), _esc(mine_id),
	]
	if not _db.query(sql):
		push_warning("[Db] get_mine_state failed: %s" % _db.error_message)
		return {}
	var rows: Array = _db.query_result as Array
	if rows.is_empty():
		return {}
	return rows[0] as Dictionary

# UPSERT 整行。Mines.ensure_seed 用。
func save_mine_state(mine_id: String, current_p: float, attempts: int, yielded: int) -> void:
	if _db == null or mine_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO mine_state (townId, mineId, currentP, attemptsThisHour, yieldThisHour, updatedAt) VALUES ('%s', '%s', %f, %d, %d, '%s') ON CONFLICT(townId, mineId) DO UPDATE SET currentP = excluded.currentP, attemptsThisHour = excluded.attemptsThisHour, yieldThisHour = excluded.yieldThisHour, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id), _esc(mine_id), current_p, attempts, yielded, now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_mine_state failed: %s" % _db.error_message)

# 累加 attemptsThisHour / yieldThisHour（不修改 currentP）。
func inc_mine_counters(mine_id: String, attempt_delta: int, yield_delta: int) -> void:
	if _db == null or mine_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "UPDATE mine_state SET attemptsThisHour = attemptsThisHour + %d, yieldThisHour = yieldThisHour + %d, updatedAt = '%s' WHERE townId = '%s' AND mineId = '%s'" % [
		attempt_delta, yield_delta, now, _esc(RunMode.town_id), _esc(mine_id),
	]
	if not _db.query(sql):
		push_warning("[Db] inc_mine_counters failed: %s" % _db.error_message)

# 取所有 mine 行（监控/分析用）。
func all_mine_states() -> Array:
	if _db == null:
		return []
	var sql := "SELECT mineId, currentP, attemptsThisHour, yieldThisHour FROM mine_state WHERE townId = '%s'" % _esc(RunMode.town_id)
	if not _db.query(sql):
		push_warning("[Db] all_mine_states failed: %s" % _db.error_message)
		return []
	return (_db.query_result as Array).duplicate(true)


# ─── Public API: workstation_states ───────────────────────────────────

# UPSERT 整行。TownWorld boot 时为每个 WorkstationNode 调用一次种入静态字段；
# 后续重启同样会跑（idempotent 覆盖；以场景为真）。运行时占用变化走
# set_workstation_occupants（由 WorkstationNode 调用）。
func save_workstation_state(node_id: String, fields: Dictionary) -> void:
	if _db == null or node_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var verbs_json := JSON.stringify(_to_plain_array(fields.get("verbs", [])))
	var sql := "INSERT INTO workstation_states (townId, workstationNodeId, workstationDefId, locationId, ownerGroup, posX, posY, posZ, interactionMode, slotCount, verbs, currentOperatorId, currentVerb, busy, updatedAt) VALUES ('%s', '%s', '%s', %s, %s, %f, %f, %f, %s, %d, %s, %s, %s, %d, '%s') ON CONFLICT(townId, workstationNodeId) DO UPDATE SET workstationDefId = excluded.workstationDefId, locationId = excluded.locationId, ownerGroup = excluded.ownerGroup, posX = excluded.posX, posY = excluded.posY, posZ = excluded.posZ, interactionMode = excluded.interactionMode, slotCount = excluded.slotCount, verbs = excluded.verbs, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id),
		_esc(node_id),
		_esc(str(fields.get("workstationDefId", ""))),
		_sql_str_or_null(fields.get("locationId", "")),
		_sql_str_or_null(fields.get("ownerGroup", "")),
		float(fields.get("posX", 0.0)),
		float(fields.get("posY", 0.0)),
		float(fields.get("posZ", 0.0)),
		_sql_str_or_null(fields.get("interactionMode", "")),
		int(fields.get("slotCount", 0)),
		_sql_str_or_null(verbs_json),
		_sql_str_or_null(fields.get("currentOperatorId", "")),
		_sql_str_or_null(fields.get("currentVerb", "")),
		1 if bool(fields.get("busy", false)) else 0,
		now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_workstation_state failed: %s" % _db.error_message)


# 全量同步占用 perception 镜像。WorkstationNode 是真值持有者，每次 _current_operators
# 变化都调一次（acquire / release / _exit_tree）。
# - first_operator_id：单占（max=1）传那个唯一 operator；多占（max>1）传 ""——
#   backend 看到 NULL 就不渲染"使用中：xx"，因为多占场景下 perception 列具体名字
#   既不准也无决策价值（反正没人被挡）。
# - count：当前 occupant 数量；busy = (count > 0)。schema 没有 count 列，所以只反映在 busy。
# 节点必须先 boot seed 过；行不存在则静默 no-op（不应该发生——seed 在 try_acquire 之前）。
func set_workstation_occupants(node_id: String, first_operator_id: String, latest_verb: String, count: int) -> void:
	if _db == null or node_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "UPDATE workstation_states SET currentOperatorId = %s, currentVerb = %s, busy = %d, updatedAt = '%s' WHERE townId = '%s' AND workstationNodeId = '%s'" % [
		_sql_str_or_null(first_operator_id),
		_sql_str_or_null(latest_verb),
		1 if count > 0 else 0,
		now,
		_esc(RunMode.town_id),
		_esc(node_id),
	]
	if not _db.query(sql):
		push_warning("[Db] set_workstation_occupants failed: %s" % _db.error_message)


# Server 启动时一次性清零本镇所有占用——节点本身是 ephemeral，重启后
# WorkstationNode._current_operators 自然回空，DB 镜像必须同步归零，避免上次
# server 崩溃残留的 busy=1 / currentOperatorId 跨重启误导 backend perception。
# TownWorld._seed_workstation_states_to_db 在 seed 前先调一次。
func clear_all_workstation_operators() -> void:
	if _db == null:
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "UPDATE workstation_states SET currentOperatorId = NULL, currentVerb = NULL, busy = 0, updatedAt = '%s' WHERE townId = '%s'" % [
		now, _esc(RunMode.town_id),
	]
	if not _db.query(sql):
		push_warning("[Db] clear_all_workstation_operators failed: %s" % _db.error_message)


# ─── Public API: container_states ─────────────────────────────────────

# 整行 UPSERT。TownWorld boot 时为每个 ContainerNode 调用一次。
# 锁后续变成动态（重分配 lock_item_id 或换 owner_group）由变更点重新调本函数全行覆盖。
func save_container_state(container_id: String, fields: Dictionary) -> void:
	if _db == null or container_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO container_states (townId, containerId, lockItemId, ownerGroup, slotCount, interactionRadius, posX, posY, posZ, updatedAt) VALUES ('%s', '%s', %s, %s, %d, %f, %f, %f, %f, '%s') ON CONFLICT(townId, containerId) DO UPDATE SET lockItemId = excluded.lockItemId, ownerGroup = excluded.ownerGroup, slotCount = excluded.slotCount, interactionRadius = excluded.interactionRadius, posX = excluded.posX, posY = excluded.posY, posZ = excluded.posZ, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id),
		_esc(container_id),
		_sql_str_or_null(fields.get("lockItemId", "")),
		_sql_str_or_null(fields.get("ownerGroup", "")),
		int(fields.get("slotCount", 0)),
		float(fields.get("interactionRadius", 0.0)),
		float(fields.get("posX", 0.0)),
		float(fields.get("posY", 0.0)),
		float(fields.get("posZ", 0.0)),
		now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_container_state failed: %s" % _db.error_message)


# ─── Public API: shelves ──────────────────────────────────────────────

# 整行 UPSERT。TownWorld boot 时为每个 ShelfNode 调用一次种入静态字段；
# owner_group / location_id 后续若动态变更，由变更点重新调本函数全行覆盖。
func save_shelf_state(shelf_id: String, fields: Dictionary) -> void:
	if _db == null or shelf_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO shelves (townId, shelfId, ownerGroup, locationId, slotCount, interactionRadius, posX, posY, posZ, updatedAt) VALUES ('%s', '%s', %s, %s, %d, %f, %f, %f, %f, '%s') ON CONFLICT(townId, shelfId) DO UPDATE SET ownerGroup = excluded.ownerGroup, locationId = excluded.locationId, slotCount = excluded.slotCount, interactionRadius = excluded.interactionRadius, posX = excluded.posX, posY = excluded.posY, posZ = excluded.posZ, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id),
		_esc(shelf_id),
		_sql_str_or_null(fields.get("ownerGroup", "")),
		_sql_str_or_null(fields.get("locationId", "")),
		int(fields.get("slotCount", 0)),
		float(fields.get("interactionRadius", 0.0)),
		float(fields.get("posX", 0.0)),
		float(fields.get("posY", 0.0)),
		float(fields.get("posZ", 0.0)),
		now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_shelf_state failed: %s" % _db.error_message)


# ─── Public API: item_defs ────────────────────────────────────────────

# UPSERT 一条 item def 静态信息。Boot 时被 TownWorld 全量调用一次每个 Items.all_ids()。
# Phase 1: 写 baseEffects（typed JSON dict 或 NULL），不再存预渲染 effectsLine 字符串。
# staticJson 装渲染需要的模板级数值（capacity / max_durability / max_stack 等），传入
# Dictionary 时自动 JSON.stringify；传入 String 时按原样存。displayName 走 i18n catalog。
func save_item_def(item_def_id: String, fields: Dictionary) -> void:
	if _db == null or item_def_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var base_effects_v: Variant = fields.get("baseEffects", null)
	var base_effects_sql := _sql_str_or_null(_nullable_json(base_effects_v))
	var static_v: Variant = fields.get("staticJson", null)
	var static_sql: String
	if static_v is Dictionary:
		static_sql = _sql_str_or_null(_nullable_json(static_v))
	else:
		static_sql = _sql_str_or_null(str(static_v) if static_v != null else "")
	var sql := "INSERT INTO item_defs (townId, itemDefId, kind, baseEffects, staticJson, updatedAt) VALUES ('%s', '%s', %s, %s, %s, '%s') ON CONFLICT(townId, itemDefId) DO UPDATE SET kind = excluded.kind, baseEffects = excluded.baseEffects, staticJson = excluded.staticJson, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id),
		_esc(item_def_id),
		_sql_str_or_null(fields.get("kind", "")),
		base_effects_sql,
		static_sql,
		now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_item_def failed: %s" % _db.error_message)


# ─── Public API: location_markers ─────────────────────────────────────

# 整行 UPSERT。TownWorld boot 时为每个 logical location 调用一次。
# 静态为主；运行时位置不变。owner_group 通过 town_world 的继承解析后传入。
func save_location_marker(location_id: String, fields: Dictionary) -> void:
	if _db == null or location_id.is_empty():
		return
	var now := Time.get_datetime_string_from_system(true)
	var sql := "INSERT INTO location_markers (townId, locationId, parentLocationId, ownerGroup, posX, posY, posZ, isWorkstation, updatedAt) VALUES ('%s', '%s', %s, %s, %f, %f, %f, %d, '%s') ON CONFLICT(townId, locationId) DO UPDATE SET parentLocationId = excluded.parentLocationId, ownerGroup = excluded.ownerGroup, posX = excluded.posX, posY = excluded.posY, posZ = excluded.posZ, isWorkstation = excluded.isWorkstation, updatedAt = excluded.updatedAt" % [
		_esc(RunMode.town_id),
		_esc(location_id),
		_sql_str_or_null(fields.get("parentLocationId", "")),
		_sql_str_or_null(fields.get("ownerGroup", "")),
		float(fields.get("posX", 0.0)),
		float(fields.get("posY", 0.0)),
		float(fields.get("posZ", 0.0)),
		1 if bool(fields.get("isWorkstation", false)) else 0,
		now,
	]
	if not _db.query(sql):
		push_warning("[Db] save_location_marker failed: %s" % _db.error_message)


# ─── Hydrate caches ───────────────────────────────────────────────────

func _hydrate_caches(town_id: String) -> void:
	if _db == null or town_id.is_empty():
		return
	_hydrate_character_states(town_id)
	_hydrate_inventory(town_id)
	_hydrate_container_inventory(town_id)
	_hydrate_farm_states(town_id)
	_hydrate_farm_plots(town_id)


func _hydrate_character_states(town_id: String) -> void:
	var rows: Array = _db.select_rows("character_states", "townId = '%s'" % _esc(town_id), [
		"characterId", "currentLocationId", "posX", "posY", "posZ", "rotY", "animState",
		"hp", "maxHp", "stamina", "maxStamina", "hunger", "maxHunger", "rest", "maxRest",
		"drunk", "sickness", "sleepNeededHours", "temperature", "burning", "alive",
		"equippedRightHand", "equippedLeftHand", "equippedBody", "equippedHead",
		"activeStatuses", "silverCentiBalance",
	])
	for r_v in rows:
		var r: Dictionary = r_v as Dictionary
		var character_id := str(r.get("characterId", ""))
		if character_id.is_empty():
			continue
		_character_states_cache[character_id] = _character_state_row_to_cache(r)


func _select_character_state(character_id: String) -> Dictionary:
	if _db == null or character_id.is_empty():
		return {}
	var rows: Array = _db.select_rows("character_states", "townId = '%s' AND characterId = '%s'" % [_esc(RunMode.town_id), _esc(character_id)], [
		"characterId", "currentLocationId", "posX", "posY", "posZ", "rotY", "animState",
		"hp", "maxHp", "stamina", "maxStamina", "hunger", "maxHunger", "rest", "maxRest",
		"drunk", "sickness", "sleepNeededHours", "temperature", "burning", "alive",
		"equippedRightHand", "equippedLeftHand", "equippedBody", "equippedHead",
		"activeStatuses", "silverCentiBalance",
	])
	if rows.is_empty():
		return {}
	return _character_state_row_to_cache(rows[0] as Dictionary)


func _character_state_row_to_cache(r: Dictionary) -> Dictionary:
	var statuses: Array = []
	var raw := str(r.get("activeStatuses", ""))
	if not raw.is_empty():
		var parsed: Variant = JSON.parse_string(raw)
		if parsed is Array:
			statuses = parsed as Array
	return {
		"currentLocationId": str(r.get("currentLocationId", "")),
		"posX": float(r.get("posX", 0.0)),
		"posY": float(r.get("posY", 0.0)),
		"posZ": float(r.get("posZ", 0.0)),
		"rotY": float(r.get("rotY", 0.0)),
		"animState": str(r.get("animState", "")),
		"hp": float(r.get("hp", 0.0)),
		"maxHp": float(r.get("maxHp", 100.0)),
		"stamina": float(r.get("stamina", 0.0)),
		"maxStamina": float(r.get("maxStamina", 100.0)),
		"hunger": float(r.get("hunger", 0.0)),
		"maxHunger": float(r.get("maxHunger", 100.0)),
		"rest": float(r.get("rest", 100.0)),
		"maxRest": float(r.get("maxRest", 100.0)),
		"drunk": float(r.get("drunk", 0.0)),
		"sickness": float(r.get("sickness", 0.0)),
		"sleepNeededHours": float(r.get("sleepNeededHours", 0.0)),
		"temperature": float(r.get("temperature", 36.5)),
		"burning": int(r.get("burning", 0)) != 0,
		"alive": int(r.get("alive", 1)) != 0,
		"equippedRightHand": str(r.get("equippedRightHand", "")),
		"equippedLeftHand": str(r.get("equippedLeftHand", "")),
		"equippedBody": str(r.get("equippedBody", "")),
		"equippedHead": str(r.get("equippedHead", "")),
		"activeStatuses": statuses,
		"silverCentiBalance": int(r.get("silverCentiBalance", 0)),
	}


func _hydrate_inventory(town_id: String) -> void:
	var rows: Array = _db.select_rows("item_instances",
		"townId = '%s' AND ownerKind = 'character'" % _esc(town_id),
		_item_instance_column_list("ownerId", "slotIndex"),
	)
	for r_v in rows:
		var r: Dictionary = r_v as Dictionary
		var owner_id := str(r.get("ownerId", ""))
		if owner_id.is_empty():
			continue
		var idx := int(r.get("slotIndex", -1))
		if idx < 0:
			continue
		var slot := _item_row_to_slot(r)
		if str(slot.get("item_id", "")).is_empty():
			continue
		var bucket: Dictionary = _inventory_cache.get(owner_id, {})
		bucket[idx] = slot
		_inventory_cache[owner_id] = bucket


func _select_character_inventory(character_id: String) -> Dictionary:
	if _db == null or character_id.is_empty():
		return {}
	var rows: Array = _db.select_rows("item_instances",
		"townId = '%s' AND ownerKind = 'character' AND ownerId = '%s'" % [_esc(RunMode.town_id), _esc(character_id)],
		_item_instance_column_list("ownerId", "slotIndex"),
	)
	var slots := {}
	for r_v in rows:
		var r: Dictionary = r_v as Dictionary
		var idx := int(r.get("slotIndex", -1))
		if idx < 0:
			continue
		var slot := _item_row_to_slot(r)
		if not str(slot.get("item_id", "")).is_empty():
			slots[idx] = slot
	return slots


func _hydrate_container_inventory(town_id: String) -> void:
	var rows: Array = _db.select_rows("item_instances",
		"townId = '%s' AND ownerKind = 'container'" % _esc(town_id),
		_item_instance_column_list("ownerId", "slotIndex"),
	)
	for r_v in rows:
		var r: Dictionary = r_v as Dictionary
		var owner_id := str(r.get("ownerId", ""))
		if owner_id.is_empty():
			continue
		var idx := int(r.get("slotIndex", -1))
		if idx < 0:
			continue
		var slot := _item_row_to_slot(r)
		if str(slot.get("item_id", "")).is_empty():
			continue
		var bucket: Dictionary = _container_inventory_cache.get(owner_id, {})
		bucket[idx] = slot
		_container_inventory_cache[owner_id] = bucket


func _hydrate_farm_states(town_id: String) -> void:
	var rows: Array = _db.select_rows("farm_states", "townId = '%s'" % _esc(town_id),
		["farmId", "moisture", "pestCountToday", "lastProcessedDay"])
	for r_v in rows:
		var r: Dictionary = r_v as Dictionary
		var farm_id := str(r.get("farmId", ""))
		if farm_id.is_empty():
			continue
		_farm_states_cache[farm_id] = {
			"moisture": float(r.get("moisture", 0.6)),
			"pestCountToday": int(r.get("pestCountToday", 0)),
			"lastProcessedDay": int(r.get("lastProcessedDay", -1)),
		}


func _hydrate_farm_plots(town_id: String) -> void:
	var rows: Array = _db.select_rows("farm_plots", "townId = '%s'" % _esc(town_id),
		["farmId", "plotIndex", "varietyId", "spawnedAtGameHour", "stage",
		"careScoreSum", "careScoreCount", "harvestsDone", "hasPest"])
	for r_v in rows:
		var r: Dictionary = r_v as Dictionary
		var farm_id := str(r.get("farmId", ""))
		if farm_id.is_empty():
			continue
		var bucket: Dictionary = _farm_plots_cache.get(farm_id, {})
		bucket[int(r.get("plotIndex", 0))] = {
			"varietyId": str(r.get("varietyId", "")),
			"spawnedAtGameHour": int(r.get("spawnedAtGameHour", 0)),
			"stage": str(r.get("stage", "")),
			"careScoreSum": float(r.get("careScoreSum", 0.0)),
			"careScoreCount": int(r.get("careScoreCount", 0)),
			"harvestsDone": int(r.get("harvestsDone", 0)),
			"hasPest": int(r.get("hasPest", 0)) != 0,
		}
		_farm_plots_cache[farm_id] = bucket


# item_instances 列名列表（typed 平铺，无 customProperties）。前两列由 caller 决定
# （比如 hydrate 要 ownerId/slotIndex；shelf join 已经把 listing 列名嵌进 SQL 里）。
# Phase 1 改 typed 平铺列后所有 hydrate/select 共用本函数避免列名打散。
func _item_instance_column_list(first: String, second: String) -> Array:
	return [
		first, second,
		"itemDefId", "stackCount", "quality",
		"shapeType", "tags", "materials", "physicsProps",
		"containerAmount", "containerContent",
		"transformAge", "transformSettleHour", "fermentCeiling",
		"freshnessTier", "freshnessAgeHours",
		"durability",
		"baseEffects", "displayedEffects",
		"listingPriceCenti",
	]


# SELECT 列表（带可选 table alias），给手写 SQL 用。和 _item_instance_column_list 保持同步。
func _item_instance_select_columns(alias: String) -> String:
	var prefix := "" if alias.is_empty() else "%s." % alias
	var cols := [
		"itemDefId", "stackCount", "quality",
		"shapeType", "tags", "materials", "physicsProps",
		"containerAmount", "containerContent",
		"transformAge", "transformSettleHour", "fermentCeiling",
		"freshnessTier", "freshnessAgeHours",
		"durability",
		"baseEffects", "displayedEffects",
		"listingPriceCenti",
	]
	var prefixed: Array = []
	for c in cols:
		prefixed.append("%s%s" % [prefix, c])
	return ", ".join(prefixed)


# UPSERT SQL 模板。location_id 空串 → 写 NULL；非空 → 写 'xxx'。
func _build_item_instance_upsert(row_id: String, item_id: String, owner_kind: String,
		owner_id: String, location_id: String, slot_index: int, slot: Dictionary, now: String,
		pos: Variant = null) -> String:
	var qty := int(slot.get("quantity", 0))
	var quality := int(slot.get("quality", 100))
	var shape_type_str := str(slot.get("shape_type", ""))
	var tags_json := JSON.stringify(_to_plain_array(slot.get("tags", [])))
	var materials_json := JSON.stringify(slot.get("materials", {}))
	var physics_json := _nullable_json(slot.get("physics_props", null))
	var base_effects_json := _nullable_json(slot.get("base_effects", null))
	var displayed_effects_json := _nullable_json(slot.get("displayed_effects", null))
	# ownerKind='world' 走 pos: Vector3，其余 caller 不传 → NULL，保持现状不动。
	var pos_x_sql := "NULL"
	var pos_y_sql := "NULL"
	var pos_z_sql := "NULL"
	if pos is Vector3:
		var pv: Vector3 = pos
		pos_x_sql = "%f" % pv.x
		pos_y_sql = "%f" % pv.y
		pos_z_sql = "%f" % pv.z
	return "INSERT INTO item_instances (id, townId, itemDefId, ownerKind, ownerId, locationId, posX, posY, posZ, slotIndex, stackCount, quality, shapeType, tags, materials, physicsProps, containerAmount, containerContent, transformAge, transformSettleHour, fermentCeiling, freshnessTier, freshnessAgeHours, durability, baseEffects, displayedEffects, listingPriceCenti, createdAt, updatedAt) VALUES ('%s', '%s', '%s', '%s', '%s', %s, %s, %s, %s, %d, %d, %d, '%s', '%s', '%s', %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, '%s', '%s') ON CONFLICT(id) DO UPDATE SET itemDefId = excluded.itemDefId, ownerId = excluded.ownerId, locationId = excluded.locationId, posX = excluded.posX, posY = excluded.posY, posZ = excluded.posZ, slotIndex = excluded.slotIndex, stackCount = excluded.stackCount, quality = excluded.quality, shapeType = excluded.shapeType, tags = excluded.tags, materials = excluded.materials, physicsProps = excluded.physicsProps, containerAmount = excluded.containerAmount, containerContent = excluded.containerContent, transformAge = excluded.transformAge, transformSettleHour = excluded.transformSettleHour, fermentCeiling = excluded.fermentCeiling, freshnessTier = excluded.freshnessTier, freshnessAgeHours = excluded.freshnessAgeHours, durability = excluded.durability, baseEffects = excluded.baseEffects, displayedEffects = excluded.displayedEffects, listingPriceCenti = excluded.listingPriceCenti, updatedAt = excluded.updatedAt" % [
		_esc(row_id), _esc(RunMode.town_id), _esc(item_id), _esc(owner_kind), _esc(owner_id),
		_sql_str_or_null(location_id),
		pos_x_sql, pos_y_sql, pos_z_sql,
		slot_index, qty, quality,
		_esc(shape_type_str), _esc(tags_json), _esc(materials_json),
		_sql_str_or_null(physics_json),
		_nullable_real(slot.get("container_amount", null)),
		_sql_str_or_null(_nullable_string(slot.get("container_content", null))),
		_nullable_real(slot.get("transform_age", null)),
		_nullable_real(slot.get("transform_settle_hour", null)),
		_nullable_int(slot.get("ferment_ceiling", null)),
		_nullable_int(slot.get("freshness_tier", null)),
		_nullable_real(slot.get("freshness_age_hours", null)),
		_nullable_int(slot.get("durability", null)),
		_sql_str_or_null(base_effects_json),
		_sql_str_or_null(displayed_effects_json),
		_nullable_int(slot.get("listing_price_centi", null)),
		now, now,
	]


# Aspect 字段 null → SQL NULL；否则 %f / %d 字面量。
func _nullable_real(v: Variant) -> String:
	if v == null:
		return "NULL"
	return "%f" % float(v)


func _nullable_int(v: Variant) -> String:
	if v == null:
		return "NULL"
	return "%d" % int(v)


# JSON dict 字段 null → 空串（再走 _sql_str_or_null 会变 NULL）；否则 stringify。
func _nullable_json(v: Variant) -> String:
	if v == null:
		return ""
	if v is Dictionary:
		return JSON.stringify(v)
	return ""


func _nullable_string(v: Variant) -> String:
	if v == null:
		return ""
	return str(v)


# 从 typed 平铺列还原 slot dict。null 列 → slot 里也 null（保持 aspect "不适用"语义）。
func _item_row_to_slot(row: Dictionary) -> Dictionary:
	var item_id := str(row.get("itemDefId", ""))
	if item_id.is_empty():
		return {}
	var slot: Dictionary = InventorySlotData.empty()
	slot["item_id"] = item_id
	slot["quantity"] = int(row.get("stackCount", 0))
	slot["quality"] = int(row.get("quality", 100))
	slot["shape_type"] = str(row.get("shapeType", ""))
	slot["materials"] = _parse_json_dict(row.get("materials", ""))
	slot["tags"] = _parse_json_tags(row.get("tags", ""))
	slot["physics_props"] = _parse_json_dict_or_null(row.get("physicsProps", null))
	slot["container_amount"] = _row_value_or_null(row, "containerAmount")
	slot["container_content"] = _row_value_or_null(row, "containerContent")
	slot["transform_age"] = _row_value_or_null(row, "transformAge")
	slot["transform_settle_hour"] = _row_value_or_null(row, "transformSettleHour")
	slot["ferment_ceiling"] = _row_value_or_null(row, "fermentCeiling")
	slot["freshness_tier"] = _row_value_or_null(row, "freshnessTier")
	slot["freshness_age_hours"] = _row_value_or_null(row, "freshnessAgeHours")
	slot["durability"] = _row_value_or_null(row, "durability")
	slot["base_effects"] = _parse_json_dict_or_null(row.get("baseEffects", null))
	slot["displayed_effects"] = _parse_json_dict_or_null(row.get("displayedEffects", null))
	slot["listing_price_centi"] = _row_value_or_null(row, "listingPriceCenti")
	# 经 normalize 防止 lua/sqlite 漂移；同时把 freshness_tier 等 int_or_null 走 coerce
	InventorySlotData.normalize(slot)
	return slot


func _parse_json_dict(raw: Variant) -> Dictionary:
	if raw == null:
		return {}
	var s := str(raw)
	if s.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(s)
	if parsed is Dictionary:
		return (parsed as Dictionary).duplicate(true)
	return {}


func _parse_json_dict_or_null(raw: Variant) -> Variant:
	if raw == null:
		return null
	var s := str(raw)
	if s.is_empty():
		return null
	var parsed: Variant = JSON.parse_string(s)
	if parsed is Dictionary:
		return (parsed as Dictionary).duplicate(true)
	return null


func _parse_json_tags(raw: Variant) -> PackedStringArray:
	if raw == null:
		return PackedStringArray()
	var s := str(raw)
	if s.is_empty():
		return PackedStringArray()
	var parsed: Variant = JSON.parse_string(s)
	if not (parsed is Array):
		return PackedStringArray()
	var pk := PackedStringArray()
	for t in (parsed as Array):
		pk.append(str(t))
	return pk


# SQLite 行字段可能没值（COL IS NULL 时 dict 直接缺 key 或值是 null）。
func _row_value_or_null(row: Dictionary, key: String) -> Variant:
	if not row.has(key):
		return null
	var v: Variant = row[key]
	if v == null:
		return null
	return v


func _json_array(raw: String) -> Array:
	if raw.is_empty():
		return []
	var parsed: Variant = JSON.parse_string(raw)
	if parsed is Array:
		return (parsed as Array).duplicate(true)
	return []


func _trade_row_to_snapshot(row: Dictionary) -> Dictionary:
	return {
		"trade_id": str(row.get("id", "")),
		"from_character_id": str(row.get("fromCharacterId", "")),
		"to_character_id": str(row.get("toCharacterId", "")),
		"offer": _json_array(str(row.get("offerJson", ""))),
		"request": _json_array(str(row.get("requestJson", ""))),
		"shelf_listing_ids": _json_array(str(row.get("shelfListingIdsJson", ""))),
		"requested_shelf_items": _json_array(str(row.get("requestedShelfItemsJson", ""))),
		"status": str(row.get("status", "pending")),
		"created_at": str(row.get("createdAt", "")),
		"updated_at": str(row.get("updatedAt", "")),
		"responded_at": str(row.get("respondedAt", "")),
	}


# ─── helpers ──────────────────────────────────────────────────────────

# 简单的 single-quote 转义。godot-sqlite 的 query() 不带 prepared statement
# 模板，select_rows 的 statuses 也是字符串拼接，所以这里手动 escape。
# 我们的 character_id / group_id 都是 snake_case 标识符，不允许引号是合理约束。
func _esc(s: String) -> String:
	return s.replace("'", "''")


# 把字符串写成 SQL 字面量；空串 → NULL。Caller 把结果直接 % 进 SQL（已转义）。
func _sql_str_or_null(value: Variant) -> String:
	var s := str(value)
	if s.is_empty():
		return "NULL"
	return "'%s'" % _esc(s)


# JSON.stringify 不喜欢 PackedStringArray —— 在它眼里是 Object 而不是 Array。
# 转成普通 Array[String] 再序列化，loadback 时再装回 PackedStringArray。
func _to_plain_array(value: Variant) -> Array:
	var out: Array = []
	if value is PackedStringArray:
		for s in (value as PackedStringArray):
			out.append(s)
	elif value is Array:
		for v in (value as Array):
			out.append(v)
	return out
