class_name Money

# 货币显示/换算工具。背包/wallet 内部全用 centi（int）；显示给玩家或 LLM 用 silver(float)。
# 1 silver = 100 centi；1 gold = 10 silver = 1000 centi。
#
# 字段命名约定：
#   - DB / 内部数值：xxx_centi  (int)
#   - 显示 / Tool 接口：silver  (float, 2 位小数)
#
# 中世纪银币可被剪开找零（cut coinage），所以小数表达合法。

const CENTI_PER_SILVER := 100
const SILVER_PER_GOLD := 10


static func silver_to_centi(silver: float) -> int:
	return int(round(silver * CENTI_PER_SILVER))


static func centi_to_silver(centi: int) -> float:
	return centi / float(CENTI_PER_SILVER)


# "7.50 银" 形式（玩家友好）
static func format_silver_from_centi(centi: int) -> String:
	if centi <= 0:
		return "0 银"
	return "%.2f 银" % (centi / float(CENTI_PER_SILVER))


# "7 银 50 分" 形式（强调有零钱时用）
static func format_silver_centi_split(centi: int) -> String:
	if centi <= 0:
		return "0 银"
	var silver_part := centi / CENTI_PER_SILVER
	var centi_part := centi % CENTI_PER_SILVER
	if centi_part == 0:
		return "%d 银" % silver_part
	if silver_part == 0:
		return "%d 分" % centi_part
	return "%d 银 %d 分" % [silver_part, centi_part]
