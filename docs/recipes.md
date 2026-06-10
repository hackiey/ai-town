# 食谱手册（Phase 2 测试用）

游戏内 craft 反应的人类可读速查。每条反应一行：**工作台 + verb + sub_option + 输入 → 输出**。
失败行为 / 难度都列出来，方便复现。

> 注意：所有反应都是 server 权威。**靠近工作台按 E** 打开 ActionPanel，
> 选 verb / sub_option（多选时是下拉框，单选时折叠隐藏），把背包格拖进 6 个槽，
> 点 Execute。失败 ≠ 报错，是 reaction 抛骰子，输出按 failure_modes 处理。

---

## 0. 调试命令（chat bar 输入 `/...`）

| 命令 | 作用 |
|---|---|
| `/give <item_id> [qty=1] [quality=100]` | 加单个 item 到自己背包 |
| `/pack raw` | 全套原料（够走完所有链）：iron/copper/tin_ore + charcoal + wood + fiber + flax_seed + wheat + water + meat + egg + berry + salt |
| `/pack craft` | 跳过 forge/anvil：iron_blade/pick_head/axe_head + wood_shaft + rope |
| `/pack food` | 食物链原料：wheat + water + salt + meat + egg + berry |
| `/pack bronze` | 青铜链原料：copper_ore + tin_ore + charcoal |
| `/timewarp <n>` | 调时间倍率 |

**起始背包**（首次 spawn 自动）：iron_ore×5, copper_ore×3, tin_ore×3, charcoal×8, wood×5, fiber×6, flax_seed×5, wheat×5, raw_meat×2, egg×2, berry×5, salt×3, tomato_seed×3, wood_bucket×1。

> `wheat` 现在同时承担两种角色：既能直接 `/plant wheat` 种到农田里，也能拿去磨坊磨成 `flour`。实现上它和 `tomato_seed` 一样，物品 `tags` 里都带 `seed`。

---

## 1. 工作台位置

6 个 craft 工作台 + 1 个水井（无限水源容器，非工作台）：

| 工作台 | 颜色 | 位置 | 模式 |
|---|---|---|---|
| 工作台 workbench | 棕色 | (-7, 1.31, 11) | action_panel |
| 熔炉 forge | 橙红 | (-10, 1.31, 11) | action_panel |
| 铁砧 anvil | 深灰 | (-13, 1.31, 11) | action_panel |
| 磨坊 mill | 米白 | (-16, 1.31, 11) | action_panel |
| 晾晒架 drying_rack | 麻黄 | 杂货店外 | action_panel |
| 灶台 stove | 深棕 | (-19, 1.31, 11) | action_panel |
| 水井 well | 深蓝 | (-12.5, 0.5, 11) | 无限水源容器；鼠标悬停 + E 开取水面板（见 §4.8） |

---

## 2. 完整食谱表

### 2.1 熔炉 forge（verb = fire）

| sub_option | 输入 | 输出 | 难度 | 失败 |
|---|---|---|---|---|
| —（无） | ore_chunk × 1 + 任意 fuel × 1 | 同材质 ingot × 1 | 0.15 | 70% 退矿 / 30% 全废 |
| —（无） | copper ingot × 1 + tin ingot × 1 | bronze ingot × 1 | 0.25 | 100% 全退 |

> **smelt 走 transform**：从 `material.transforms[fire]` 查得新材质 id（iron_ore→iron, copper_ore→copper, tin_ore→tin）。
> **alloy** 自动识别 copper+tin 走合金分支，输出 bronze。
> 燃料：charcoal（主推）。质量按 weighted_avg：矿 0.8 + 燃料 0.2。

### 2.2 铁砧 anvil（verb = shape，sub_option 必选）

> 铁砧 `shape` 当前只消耗 metal ingot；燃料只在 forge/fire 冶炼阶段消耗，不要在 anvil 输入里再加入 charcoal 或 wood。

| sub_option | 输入 | 输出 | 难度 | 失败 |
|---|---|---|---|---|
| blade | metal ingot × 1 | flat_blade × 1（同材质） | 0.3 | 70% 扁了/退料 / 30% 碎了/废料 |
| pick_head | metal ingot × 1 | pick_head × 1 | 0.3 | 同上 |
| axe_head | metal ingot × 1 | axe_head × 1 | 0.3 | 同上 |

> 难度 0.3 → mastery=1.0 时 fail_chance ≈ 0.3 - 0.6 = clamp(-0.3, 0, 1) = 0。
> **当前 mastery 写死 1.0，所以打铁基本不会失败**——失败 modes 只有等 Phase 4 mastery 系统接进来才看得到。
> 想强制看失败：临时把对应 .tres 的 difficulty 改 0.8 重启。

### 2.3 工作台 workbench（verb = combine / carve / mix）

#### combine（必选 sub_option）

| sub_option | 输入（顺序固定） | 输出 |
|---|---|---|
| shovel | flat_blade + shaft + rope | flat_blade_on_shaft（铁锹） |
| pick | pick_head + shaft + rope | pick_head_on_shaft（铁镐） |
| axe | axe_head + shaft + rope | axe_head_on_shaft（铁斧） |
| knife | flat_blade + shaft | knife（短刀，无需绳） |
| sickle | flat_blade + shaft | sickle（镰刀，无需绳） |
| rope | fiber_bundle × 1 | rope × 1 |

> knife 和 sickle 输入完全一样——靠 sub_option 区分。
> combine 的失败 mode 多是"绳子断了，金属和木头还在"——只消耗绳。

#### carve（必选 sub_option）

| sub_option | 输入 | 输出 |
|---|---|---|
| shaft | wood log × 1 | shaft × 1（手柄） |
| plank | wood log × 1 | plank × 1（木板） |

> log 是 wood 的默认 shape（fiber 不行——需 `materials.body.category == "wood"`）。

#### mix（无 sub_option）

| 输入 | 输出 |
|---|---|
| flour + water | dough（面团） |

### 2.4 磨坊 mill（verb = grind）

| 输入 | 输出 |
|---|---|
| 任意 grain（wheat 等）× 1 | 同材质 powder × 1（小麦→面粉） |

> grain 是 material category，不是 shape。

### 2.5 晾晒架 drying_rack（verb = dry，sub_option 必选）

| sub_option | 输入 | 输出 |
|---|---|---|
| save_seed | tomato_fruit × 1 | tomato_seed × 2 |
| save_seed | flax_bundle × 1 | flax_seed × 2 |
| fiber | flax_bundle × 1 | fiber × 3 |

### 2.6 灶台 stove（verb = bake / mix）

| verb | 输入 | 输出 | 备注 |
|---|---|---|---|
| bake | dough × 1 | loaf（面包） | 60% 烤焦 / 40% 夹生（退料） |
| bake | raw_meat × 1 | dish（cooked_meat） | shelf 72h，35s |
| bake | raw_meat + salt | dish（**cured_meat**，腌肉） | shelf 120h，hunger +25%，30s |
| bake | egg × 1 | dish（omelet） | shelf 36h，20s |
| bake | egg + salt | dish（**cured_omelet**，咸蛋饼） | shelf 180h，22s |
| mix | berry + water | jar（berry_jam） | shelf 720h（30 天） |
| mix | fruit_whole + water | bowl（vegetable_stew） | shelf 48h |
| mix | fruit_whole + water + salt | bowl（**cured_stew**，盐渍菜汤） | shelf 240h |

> bake 的多条反应靠 input 0 的 material / tags 区分（dough vs meat vs egg），加盐版多一个 salt 输入。
> mix 的两条用 input 0 区分（berry material vs fruit_whole shape + tag）。
> 早期版本有独立 fry verb，已合并到 bake——煎和烤在 MVP 阶段产物相同（都是 cooked_meat / omelet），保留两个动词只是冗余。

---

## 3. 推荐测试链路（按时长 5 分钟内全跑完）

### A. 铁锹链（最经典，4 步）

```
起始包  →  iron_ore × 5, charcoal × 8 已有
1. 熔炉 fire: iron_ore + charcoal → iron_ingot
2. 铁砧 shape sub=blade: iron_ingot → flat_blade（铁刃）
3. 工作台 carve sub=shaft: wood → wood_shaft
4. 工作台 combine sub=shovel: flat_blade + wood_shaft + rope → 铁锹
   （rope 需要先：combine sub=rope: fiber → rope）
```

### B. 青铜锭（验证 alloy + 涌现 item_id）

```
1. 熔炉 fire: copper_ore + charcoal → copper_ingot
2. 熔炉 fire: tin_ore + charcoal → tin_ingot
3. 熔炉 fire: copper_ingot + tin_ingot → bronze_ingot
   item_id = auto_<hash>，UI 应显示"青铜锭"（material display_name + shape display_name）
4. 铁砧 shape sub=blade: bronze_ingot → 青铜扁刃
```

### C. 食物链（3 步出面包）

```
1. 磨坊 grind: wheat → flour
2. 工作台 mix: flour + water → dough
3. 灶台 bake: dough → 面包
```

> 如果想同时体验种地和做面包，先留几份 `wheat` 当播种粮，再把剩下的拿去磨粉。

### D. 简单刀（最快出工具，2 步）

```
1. 铁砧 shape sub=blade: iron_ingot → flat_blade
2. 工作台 combine sub=knife: flat_blade + wood_shaft → 短刀
```

---

## 4. 质量传递（quality_strategy）

- **weighted_avg**（默认）：按 input 的 `quality_weight` 加权平均。例：`/give iron_ore 5 90` + `/give iron_ore 5 30` 用同槽（不会 stack 因为 quality 不同），smelt 出来约 60。
- **first**（mill_grind, bake_bread）：只看 input 0。
- **min / max**：当前没用到，预留。

mastery 暂全部 1.0，所以 final = base（没乘 mastery）。

**食物饱食度上限 30**：任何食物在 q=100 最优状态下 hunger 增量 ≤ 30。设计原则——保经济循环，玩家/NPC 一天需吃 3-4 餐才能饱腹，烹饪/交易频繁。当前分布：berry 4 / berry_jam 15 / omelet 20 / cooked_meat 22 / veg_stew 25 / cured_omelet 24 / cured_stew 28 / bread 30 / tomato 30 / cured_meat 30。

**消费侧 quality 倍率**（`Character.quality_multiplier`）：线性 `q/100`。q=100 → 1.0×，q=70 → 0.7×，q=0 → 0×。
- 食物 lua 用 `ctx.quality_multiplier` 乘 hunger / stamina（cooked_meat / bread / ... 都已用）。
- Crop yield 数量也乘这个倍率（高 maturity_int 收成更多，line `crop.gd:265`）。
- 早期是 4 桶分档（90/70/40），跟 quality_curve 冲突——q=70 桶里的"满营养"会让 2 肉曲线 0.7 出来反而比 1 肉赚（80 > 60）。改线性后 1 肉 = 1.0×，2 肉 = 1.4× 总，3 肉 = 1.2× 总，5 肉 = 0×。

---

## 4.5 投入数量曲线（`quality_curve`）

每个 reaction input 都有"最优数量"概念，偏离最优 → 品质曲线惩罚。模型统一，没有 strict / batch / dose 之分：放多少都允许（被 input predicate 接住），曲线惩罚最终品质。

**默认曲线**（`crafting_dispatcher.gd:DEFAULT_QUALITY_CURVE`）：

| 投入数量 | 品质乘数 |
|---|---|
| 1（最优） | 1.00 |
| 2 | 0.70 |
| 3 | 0.40 |
| 4 | 0.15 |
| ≥5 | 0.00（毁了） |

每个 input 算自己的曲线，**乘起来**得 `quality_modifier`，输出 quality = base × modifier。多个 input 都偏离 = 双重扣分。

**输出数量** = 短板原则：`min(matches[primary_input_indices].qty)`。`primary_input_indices` 默认 = 所有 input。
- bake_meat (primary=meat): 5 块肉 → 5 块熟肉，每块 quality × 0 = 完全不能吃
- bake_meat_salted (primary=[meat]): 3 肉 + 1 盐 → 3 腌肉，肉曲线 0.4 × 盐曲线 1.0 = 0.4
- combine_shovel (primary=all): 2 刀刃 + 1 木柄 + 1 绳 → min(2,1,1)=1 把锹，刀刃曲线 0.7

**duration 固定**——不随投入数量变化（区别于早期的 batch ×N 模型）。

**自定义曲线**：reaction input predicate 可写 `quality_curve: [1.0, 0.5, 0]`（更严的曲线）覆盖默认。比如药剂调配可以严到只允许 1 份，主菜烹饪可以宽容到 3-4 份还有 50% 品质。

**典型反应行为**：
- 1 肉 → 1 熟肉 quality 100 → N 饱食度
- 2 肉 → 2 熟肉 quality 70 → 总 1.4N 饱食度
- 3 肉 → 3 熟肉 quality 40 → 总 1.2N 饱食度
- 4 肉 → 4 熟肉 quality 15 → 总 0.6N 饱食度
- 5+ 肉 → 全 quality 0，零饱食度

总营养 sweet spot 在 2-3 块；放 5 块完全浪费。

## 4.6 工作台 staging（物理搬运）

ActionPanel 不是"虚拟引用"，而是 server-authoritative 的物理 staging：
- 从背包拖物品到工作台 → 背包 -1 / staging +1（同 stack 自动合并）
- 左键点 staging slot → 退还 1 件回背包
- 关 panel（craft 不在进行）→ 自动全部退还
- Cancel craft（移动 / 死亡）→ 自动全部退还
- Execute → 用 staging 内容跑 dispatcher

实现：`Player.staged_items: Array` 走 owner-private MultiplayerSynchronizer，`request_stage_to_workstation` / `request_unstage_from_workstation` / `request_clear_staging` 三条 RPC。

## 4.7 移动锁（craft 期间）

制造期间禁止移动。玩家点 walk 目标 → server 拒绝 + 弹 ConfirmationDialog "正在制造，是否取消？"。
- "取消并移动" → 取消 craft + 退还所有 staged + 走过去
- "继续制造" → 关闭 dialog，留在原地

适用于所有有 duration 的反应。瞬时反应（duration=0）不受影响。

## 4.8 容器、水井与酿酒（液体模型）

> 详见 [architecture/game-mechanics.md §7](./architecture/game-mechanics.md)。这里只列测试速查。

**液体容器**（`kind=container` + tag `liquid_container`）：液体只存在于容器里。槽状态 = `container_amount`(升) + `container_content` + 复用 `quality`。

| 容器 | 容量 | 备注 |
|---|---|---|
| wood_bucket 木桶 | 20 升 | 通用 |
| brewing_barrel 酿酒桶 | 100 升 | 兼发酵（tag `brewing_vessel`）|
| cup 杯子 | 小 | 分装/喝 |

**水井** = 无限水源容器（`ContainerNode` 带 `infinite_content="water"`，**不是 direct 工作站**）：靠近 → 鼠标悬停 + E → 取水面板 → 选背包容器 + 数量打水。

**倒液体**：右键装液体的容器 → "倒出液体…" → 选目标 + 数量（同 content 或目标空才行，品质按量加权平均）。

**酿酒（被动）**：酿酒桶灌满水 + 背包麦芽(1:1) → 右键桶"酿酒…"选原料 → 水立刻变啤酒(品质0)，48h 爬到上限。上限 = 麦芽品质 × `clamp(0.6+(酿酒熟练度-难度)/100,0,1)`。

**晾晒（被动）**：小麦放进晾晒架 → 自动晾成麦芽，品质 0→小麦品质，24h。

被动转化（晾晒/发酵）由全局定时器 `PassiveSimulator` 推进，定义在 `data/mechanics/crafting.lua`（`trigger=passive`）。`/eat`/`/drink` 喝酒走容器内液体。

**起始包**有 1 个空桶。出生第一件事：走到水井（鼠标悬停 + E）装满。

---

## 5. Stacking 规则

两槽 merge 当且仅当**所有字段全等**：item_id, quality, shape_type, materials, tags, properties。

- 原料无 properties → 自然 stack
- crafted item 多半带 properties（blade_area, edge_sharpness）→ 不 stack
- 同 quality 同 material 同 shape 的 ingot → stack

---

## 6. ActionPanel UI

- **Verb 下拉**：workstation.verbs 多于 1 个才显示。anvil/workbench/stove 都会有。
- **Sub-option 下拉**：verb.sub_options 非空才显示。combine/shape/carve 必选。
- **6 个槽**：拖背包格进去（按物品而不按 stack）。槽数固定 6，多余的留空。
- **Execute** 按钮：发 RPC `request_craft(verb, ws_id, sub_option, slot_indices, expected_item_ids)`，server 跑 dispatcher，回成功/失败/no_match 提示。

---

## 7. 时间消耗 + 进度条（Phase 2.5）

每条反应的 `duration_seconds` 现在生效：
- 点 Execute → server 锁定 outcome（success/failure 抛骰发生在**开始**而不是结束）
- 启动 server-side timer，duration 期间 ActionPanel 显示进度条
- 期间 Execute 按钮禁用，再次按 request_craft 直接被拒
- timer 到期 → 再校验 slot 仍持有 → commit outcome（扣材料 + 加产出）
- 中途 slot 被换掉 / 物品被吃 → cancel，不扣材料

**主要 duration**（**game-second**，跟 `GameClock.time_scale` 走；默认 7×，所以下表 ÷7 ≈ 真实秒，典型反应约 15-30 真实秒；`/timewarp 100` 时几乎瞬完）：
- combine rope/knife 70s（10 真实秒），combine sickle/axe/pick/shovel 84-105s
- carve shaft/plank 140s，mill grind 140s，mix dough 70s
- forge smelt 210s（30 真实秒），forge alloy 280s（40 真实秒）
- anvil shape (blade/pick_head/axe_head) 210s
- bake bread 175s，bake omelet 140s，bake omelet+salt 154s，bake meat 245s，bake meat+salt 210s
- mix stew 210s，mix stew+salt 245s，mix jam 420s（60 真实秒，长保鲜）

**没设 duration**（duration=0）的反应会"瞬间完成"——保留向前兼容，新加反应建议都设 duration。

**现在没做的**：
- 普通制作 stamina 扣减（schema 字段在，dispatcher 不读）；采矿已由 server 按每 5 游戏分钟一次、每次 10 体力单独扣减
- mastery 系统（Phase 4 主线）
- 离开工作站自动 cancel（player 走开了 craft 还在跑）

---

## 8. 通用化反应（Phase 2.5）

肉类反应 (`bake_meat` / `bake_meat_salted`) 的 input predicate 用 `tags: ["meat", "raw"]` 而不是写死 `materials.body == raw_meat`。

**未来加 raw_beef / raw_chicken / raw_pork 的步骤**：
1. 写新 material .tres，`transforms.bake = "cooked_beef"`（或 chicken/pork 对应版）
2. 写新 cooked_beef material 带 `shelf_life_hours`
3. 写新 raw_beef item template 带 `tags = ["meat", "raw"]`
4. **反应零改动** —— predicate 已经匹配 tags

salted 版本目前还硬写 `materials: {body: "cured_meat"}`，加新肉时要么对应 cured 版各自配反应，要么扩 schema 加二级 transform key。

---

## 9. 腐烂系统（Phase 2.5）

**核心**：每个 perishable 材质有 `shelf_life_hours`；inventory stack 记 `freshness_tier`（5=新鲜 / 4=良好 / 3=一般 / 2=陈旧 / 1=将腐 / 0→腐烂）。

**shelf_life 一览**（game-hour）：

| 材质 | shelf | 备注 |
|---|---|---|
| dough, berry | 12 | 极易腐 |
| raw_meat | 24 | |
| omelet | 36 | |
| egg, vegetable_stew | 48 | |
| cooked_meat | 72 | |
| cured_meat | 120 | 盐版 ×5 |
| cured_omelet | 180 | |
| cured_stew | 240 | |
| bread | 168（一周） | |
| berry_jam | 720（一月） | jam 本身保鲜 |

**衰减节奏**：每 game-hour tick 一次，到 `shelf_life / 5` 就降一级 tier。raw_meat 24h → 每 4.8h 降一级；满级到 0 共 24h。

**stacking**：同 (item_id, quality, materials, shape_type, tags, **freshness_tier**) 才 merge。tier 不同 → 占新格。tier 衰减后会自动 re-merge（5→4 后跟原本就是 4 的 stack 合并）。

**craft 输出**：output.freshness_tier = min(perishable input 的 tier)。"加工不刷 freshness"——拿陈旧的肉煎，出来的熟肉也陈旧。但 cured_meat 寿命 120h 远比 cooked_meat 72h 长，所以加盐是真延寿。

**腐烂态**：tier 跌到 0 → swap 到 `materials.body.rotten_into`（默认 `rotten_food`），item_id = `rotten_food`，quality = 0。kind=trash 不能吃；/eat 检查 material.category=spoiled 直接拒绝。

**调试加速**：`/timewarp 1000` 让 game-clock 跑飞，几秒钟看肉腐烂。

---

## 10. 已知缺口（不是 bug）

- 失败基本不触发（mastery=1.0）。Phase 4 接 mastery 后才看到失败 UX。
- 普通制作的 stamina_cost 还没接体力扣减；采矿已经按每次尝试扣 10 体力。
- hazards（火灾 / 爆炸）= Phase 5。
- 容器型 passive 反应（pot 慢炖）= Phase 7。
