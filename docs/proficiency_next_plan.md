# 熟练度系统 - 后续计划

> P0 三条 + Tier 1（架构债）+ B1（farming）已全部清完。本文件跟踪**剩余的设计岔路 + 等触发项**。
> 已解决的历史问题保留在 `proficiency_issues.md`，本文件按"还需要做什么"组织。

---

## ✅ 已关闭

### A1. GD 端镜像表清理【原 #6】
> **Done**：`Crafts` autoload（`src/autoload/crafts.gd`）直接读 `data/skills/crafts.json`，`WORKSTATION_AXIS_ACTIONS` / `_AXIS_BY_WORKSTATION_VERB` 两处镜像表已删。

### A2. mining 和 craft 的 proficiency 增长路径合并【原 #7】
> **Skipped**：两条路径今天都调同一个 lua `compute_proficiency_gain` 函数，公式单点真值。"未来改公式忘同步" 是假设性风险，commit 时 grep 两处即可。把开发时间花在 B2/B3 等真问题上更值。

### B1. farming 轴覆盖失衡【原 #10】
> **Done**：用户拍板"种地不需要熟练度，知道相关的技巧就好了"。落实方案：
> - `farming` skill_id 整条删除（skills.json / KNOWN_SKILLS / npcs.json proficiency 字段）
> - `dry_seed` tool / 2 条 lua reaction / 完整 wire 链全删
> - `drying_rack` 工作站改造成 ContainerNode + `passive_tags=["drying"]`
> - 新增 `data/mechanics/drying.lua` 被动转换机制：晾架槽内 `Item.dries_into` 非空的水果每 game-hour tick，到 `drying_hours` 阈值 swap 成种子
> - `farm_action_runner._apply_farming_proficiency_gain` dead code 删除
> - 16 个农户 NPC `proficiency.farming` → `knowledge_books += farming_basics`
> - farming_basics 知识更新晾架说明

### #15 factory.ts 工程整洁
> **Done**：`draw_water` / `use_container` 物理上拆成独立块，注释明确避免误伤。

---

## 🟡 设计岔路（需要先拍板再动手）

### B2. 技能书 → proficiency 通路【原 #11】
**问题**：读完 `iron_tool_chain_basics` 等技能书不会涨对应 proficiency 数值。书目前只是"知识灌入 agent memory"，不影响 skill check。

**与现状的关系**：`proficiency: {smithing: 0}` 已经能让 NPC 看到 smithing 工具 + memory 灌入对应书。所以 **"不涨数值，只解锁感知"已经是事实**。问题变成"要不要给个起步数值"。

**需拍板**：
- (a) 读书是"一次性起步推力"：seed proficiency = N（如读完 +5）
- (b) 不变（教材纯叙事 + 解锁感知，proficiency 起步 0 慢慢练）
- (c) 教材按掌握度分层：第一次读 +0，第二次读 +5，第三次读 +10（鼓励复读）

**预估**：(a)/(c) 半天（boot seed 时检查 entry 加书逻辑）；(b) 零代码

**与 B1 的对照**：B1 把 farming 整条移到了 knowledge 路径，验证了"无数值的知识书"是可行的。B2 是问"其他书要不要也这样"。

---

### B3. master 天花板【原 #12】
**问题**：lua 最高 difficulty=65；公式在 p>75 时 `slow≈0.16`，普通 game loop 内 NPC 爬不到 master tier（≥90）。

**需拍板**：
- (a) 不动公式，加几个 d=80+ 的"传说级" reaction（如 forge_master_blade 难度 85，产 perfect quality）
- (b) 调公式让 plateau 拉到 85，master 仍然稀有但不为零
- (c) master tier 设计上就该极罕见 / 几乎不可达，保持现状

**预估**：(a) 看新加几条；(b) 改两行 lua 公式 + 重新测曲线；(c) 零代码

---

## 🟢 等触发（无玩家反馈前不动）

### C1. i18n 完整性（en 缺位）【原 #8 残余】
**问题**：链条书重分类后，`skill_axis` 字段已从 i18n catalog 移除，原 #8 主因消除。但 en/skills.json 整体内容仍贫瘠（只 `character_attributes_basics` 一本），其他 7 本完全没翻译。

**做法**：等真有 en player 再补；或一次性机器翻译走起。

**优先级**：低，独立问题。

---

### C2. 玩家本人看不到自己的熟练度【原 #13】
**问题**：DB / `character.get_proficiency_table` 已通用，Player 也读得到。但游戏 UI 里玩家本人没有任何窗口看到"我伐木/木工到了多少"。LLM 看得到（prompt context），玩家本人反而看不到。

**做法**：在 character_attributes 面板（已存在）旁边加一个"手艺"标签页，复用 backend 的 tier 文案。

**优先级**：等玩家反馈触发。

---

### D1. `smelt`（forge + mint）无 group gate【原 #14】
**问题**：doc 写"国家管控铸币靠未来 group 过滤"，目前不存在。Godot `_find_workstation` 的 `access_denied` 是 group→workstation 层不是 tool→workstation 层。

**做法**：等 player 真的走到 mint 前再说；或趁 axis 重构时在 crafts.json 加 `requiresGroup` 可选字段。

**优先级**：低，无玩家反馈前不动。

---

## 📋 新增技术债（drying 改造副产品）

### 被动转换机制缺文档
新增 `Containers.tick_passive` + `ContainerNode.passive_tags` + `Item.dries_into/drying_hours/drying_yield_qty` + `data/mechanics/drying.lua` 一整套被动转换系统，但没有专门文档。未来加发酵 / 烟熏 / 腌制时没参考。

**做法**：写一份 `docs/passive_transformations.md` 或者在 `docs/architecture/simulation-layer.md` 加一节。等出现第二种被动机制时再写也行（现在写有点早）。

### Godot 编辑器手工验证
`drying_rack_workstation_node.tscn` 改了 script 绑定（WorkstationNode → ContainerNode），需要：
1. Godot 编辑器打开 town.tscn 看 DryingRack 节点是否正常加载
2. Inspector 显示 `passive_tags = ["drying"]` + `slot_count = 6`
3. Runtime：删 state.db 启动，NPC `use_container put` 番茄到晾架 → `/timewarp 24h` → `use_container inspect` 看到种子

**优先级**：高（架构改完不验证就是埋雷，见 `[[feedback_bug_recurrence_means_architecture]]`）

---

## 执行顺序建议

```
现在做：
  1. 人工验证 drying_rack（Godot 编辑器 + 端到端测试）

设计决策（看你想先聊哪个）：
  B2 技能书是否给数值
  B3 master 是否可达

等触发不动：
  C1 en i18n（等需求）
  C2 玩家 UI（等玩家反馈）
  D1 mint group gate（等玩家场景）

文档：
  - 被动转换机制文档（出现第二种被动 mechanic 时写）
```

**结论**：架构层基本干净了。剩下要么是产品设计决策（B 系列），要么是等用户反馈（C/D 系列）。
