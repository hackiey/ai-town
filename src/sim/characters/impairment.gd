class_name Impairment

# 损伤层统一口径。两个来源——drunk 醉酒 / sickness 生病（都是 Character 上 0..100 的数值）。
# "干活"惩罚取两者最重 max(drunk, sickness)；说话乱码 / 走路踉跄是醉酒专属，单读 drunk。
#
# 所有曲线只在这一处定义；各动作结算点（crafting / mining / 农活 / 打水）调这里，
# 惩罚只在"真正执行动作"时临时算，不写回存储的熟练度（避免污染 prompt 渲染）。
# 数值见 docs/plan：醉酒/生病损伤系统。

# 档位阈值——**全工程唯一定义处**。只被本文件的 *_tier_key() 引用；backend 读持久化的
# character_states.drunkTier/sicknessTier，不复制这组数（见 docs/architecture/impairment-system.md §2）。
const DRUNK_TIPSY := 6.0
const DRUNK_DRUNK := 30.0
const DRUNK_WASTED := 60.0
const SICK_MILD := 10.0
const SICK_MODERATE := 40.0
const SICK_SEVERE := 70.0

# 负重（encumbrance）档位阈值——以"负重比例 = carry_weight / max_carry_weight"为输入。
# **仅用于显示/prompt 的 carryTier 文案**，不参与数值惩罚（惩罚走下面的连续曲线）。
const ENCUMBER_LADEN := 0.75
const ENCUMBER_HEAVY := 0.90
const ENCUMBER_OVERLOADED := 1.0
# 体力消耗倍率斜率（可调）：mult = 1 + K×ratio。K=1 → 满载×2，超载继续往上。
const ENCUMBER_STAMINA_K := 1.0

# 醉话乱码用的符号池（说话/听不清都用同一套，与 backend say.ts 保持观感一致）。
const GARBLE_CHARS := "%^$#@&*"


# 干活惩罚强度（0..100）= 醉酒 / 病情里更重的那个。
static func work_impair(character) -> float:
	if character == null:
		return 0.0
	return maxf(float(character.drunk), float(character.sickness))


# 醉酒专属强度（说话乱码 / 走路踉跄 / 听不清）。
static func drunk_level(character) -> float:
	if character == null:
		return 0.0
	return float(character.drunk)


# ─── 曲线（impair 0..100）──────────────────────────────────

# 有效熟练度直接减：p_eff = max(0, p - impair)。烹饪/铁匠/采矿用。
static func proficiency_penalty(impair: float) -> float:
	return maxf(0.0, impair)


# 失手概率（种植 / 除虫）。醉100 → 50%。
static func fail_chance(impair: float) -> float:
	return clampf(impair / 200.0, 0.0, 1.0)


# 收获产量乘子。醉100 → ×0.33。
static func yield_mult(impair: float) -> float:
	return clampf(1.0 - impair / 150.0, 0.05, 1.0)


# 浇水入土湿度乘子（洒水）。醉100 → ×~0.09（土壤几乎没涨）。
static func water_mult(impair: float) -> float:
	return clampf(1.0 - impair / 110.0, 0.0, 1.0)


# 打水量乘子。醉100 → ×0.5（只打一半）。
static func well_mult(impair: float) -> float:
	return clampf(1.0 - impair / 200.0, 0.05, 1.0)


# ─── 档位 key（阈值的唯一定义处）──────────────────────────────
# 返回与 backend / i18n 共用的语义 key（""=清醒健康）。**阈值常量只在这两个函数里用。**
# Godot 算好 key 随 raw 一起持久化到 character_states.drunkTier/sicknessTier，
# backend 直接 SELECT 这个 key 渲染 prompt，不再自己存一份阈值（见 docs/architecture/impairment-system.md §2）。

static func drunk_tier_key(drunk: float) -> String:
	if drunk >= DRUNK_WASTED:
		return "wasted"
	if drunk >= DRUNK_DRUNK:
		return "drunk"
	if drunk >= DRUNK_TIPSY:
		return "tipsy"
	return ""


static func sickness_tier_key(sickness: float) -> String:
	if sickness >= SICK_SEVERE:
		return "severe"
	if sickness >= SICK_MODERATE:
		return "moderate"
	if sickness >= SICK_MILD:
		return "mild"
	return ""


# ─── 档位标签（HUD / 显示用，从 key 派生）──────────────────────

static func drunk_tier_label(drunk: float) -> String:
	match drunk_tier_key(drunk):
		"wasted": return TranslationServer.translate("ui.status.impairment.drunk_wasted")
		"drunk": return TranslationServer.translate("ui.status.impairment.drunk")
		"tipsy": return TranslationServer.translate("ui.status.impairment.tipsy")
	return ""


static func sickness_tier_label(sickness: float) -> String:
	match sickness_tier_key(sickness):
		"severe": return TranslationServer.translate("ui.status.impairment.sick_severe")
		"moderate": return TranslationServer.translate("ui.status.impairment.sick_moderate")
		"mild": return TranslationServer.translate("ui.status.impairment.sick_mild")
	return ""


static func disease_label(disease_id: String) -> String:
	if disease_id.is_empty():
		return ""
	var key := "disease.%s.name" % disease_id
	var translated := str(TranslationServer.translate(key))
	return "" if translated == key else translated


# ─── 负重（encumbrance）─────────────────────────────────────
# 输入是负重比例 ratio = carry_weight / max_carry_weight。负重不影响"干活产出"
# （work_impair 不并入它）；代价只有两条：体力消耗加快 + 移动变慢。

# 档位 key（阈值唯一定义处，仅给 HUD/prompt 文案用）。""=轻装。
static func encumbrance_tier_key(ratio: float) -> String:
	if ratio >= ENCUMBER_OVERLOADED:
		return "overloaded"
	if ratio >= ENCUMBER_HEAVY:
		return "heavy"
	if ratio >= ENCUMBER_LADEN:
		return "laden"
	return ""


static func encumbrance_tier_label(ratio: float) -> String:
	match encumbrance_tier_key(ratio):
		"overloaded": return TranslationServer.translate("ui.status.impairment.encumber_overloaded")
		"heavy": return TranslationServer.translate("ui.status.impairment.encumber_heavy")
		"laden": return TranslationServer.translate("ui.status.impairment.encumber_laden")
	return ""


# 体力消耗倍率（≥1）：与负重平滑成比例，1 + K×ratio。所有体力扣点（StaminaWallet.try_spend）
# 乘这个 —— 负重越高、同一动作越费体力（连带越饿）。
static func encumber_stamina_mult(ratio: float) -> float:
	return 1.0 + ENCUMBER_STAMINA_K * maxf(0.0, ratio)


# 移动速度倍率：轻装(≤laden)不减速；过 laden 后线性下滑，夹底 0.3（超载几乎挪不动）。
static func encumber_move_mult(ratio: float) -> float:
	return clampf(1.0 - maxf(0.0, ratio - ENCUMBER_LADEN) * 1.6, 0.3, 1.0)


# ─── 醉话乱码（drunk 专属）─────────────────────────────────
# 按 drunk 强度逐字符把字替换成符号；空白字符保留。drunk 越高越糊。
# 说话端（speaker drunk）和听话端（listener 烂醉）都用这个，传不同的强度即可。
static func garble_text(text: String, drunk: float, per_char_divisor: float = 150.0) -> String:
	if drunk < DRUNK_TIPSY or text.is_empty():
		return text
	var p := clampf(drunk / per_char_divisor, 0.0, 0.9)
	var out := ""
	for ch in text:
		if ch == " " or ch == "\n" or ch == "\t":
			out += ch
		elif randf() < p:
			out += GARBLE_CHARS[randi() % GARBLE_CHARS.length()]
		else:
			out += ch
	return out
