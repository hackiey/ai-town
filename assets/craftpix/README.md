# CraftPix 素材目录

这个目录同时保存两类内容：

- `craftpix-net-*/`：从 CraftPix 下载并按原目录名解压的第三方素材包；在根目录
  `.gitignore` 中逐包忽略，不提交到仓库。
- `scripts/`：仓库维护的素材检查、转换和导出工具；需要提交到仓库。

不要把不同素材包按 `tilesets/`、`characters/` 等用途重新拆开。游戏代码直接引用
各素材包内部的原始相对路径。

## 已使用的素材包

| 本地目录 | 内容 | 主要文件 | 是否需要脚本处理 |
| --- | --- | --- | --- |
| `craftpix-net-254170-rpg-character-sprite-sheet-generator/` | 48x48 四方向 RPG 角色生成器 | `Rpg Character Sprite Sheet Generator.psd`、展示 PNG | **需要**。源素材是分层 PSD，使用 `scripts/export_character_psd.py export-components` 导出 119 张对齐透明组件 spritesheet 和目录 JSON；Godot 人物编辑器实时拼接组件，不再接入固定成品人物。 |
| `craftpix-net-504452-free-village-pixel-tileset-for-top-down-defense/` | 32x32 村庄地块、房屋、帐篷、箱子、装饰和门动画 | `1 Tiles/FieldsTileset.png`、`1.1 Tiles/Tileset2.png`、`2 Objects/`、`3 Animated Objects/{Door1,Door2,DoubleDoor1,DoubleDoor2}.png`、`PSD/` | 不需要预处理。包内已有完整 tilesheet、切分 PNG、对象 PNG 和动画条带；Godot 可直接导入，PSD 只作为可编辑源。当前 2D 小镇主要使用这个包。 |
| `craftpix-net-665131-free-fields-tileset-pixel-art-for-tower-defense/` | 32x32 田野地块、围栏、植物、营地、塔位、旗帜和篝火 | `1 Tiles/FieldsTileset.png`、`2 Objects/`、`3 Animated Objects/1 Flag/`、`3 Animated Objects/2 Campfire/`、`PSD/` | 不需要预处理。Godot 可直接使用 PNG 和动画条带；PSD 只是可编辑源。`FieldsTileset.png` 与 504452 包中的同名文件完全相同，项目只暴露一份 canonical 地形。 |

每个素材包中的 `License.txt`、`license.txt` 或官方许可链接应与素材一起保留。新增素材包时：

1. 解压到 `assets/craftpix/<原始素材包目录名>/`。
2. 在本表中登记用途、关键文件和处理方式。
3. 在根目录 `.gitignore` 中新增该素材包的精确目录规则。
4. 如果需要转换，把通用脚本放在 `assets/craftpix/scripts/`，不要放进被忽略的素材包。

## RPG 角色 PSD 导出

不需要 Photoshop。`scripts/export_character_psd.py` 使用 `psd-tools` 和 Pillow 读取
PSD 图层。主要工作流是把每个可用图层导出成同尺寸透明组件，让 Godot 按组件配置实时叠加；单个 JSON 预设导出仍保留为素材校验和回归测试工具。

依赖已经安装在项目本地的 `.venv-psd`。在其他机器首次使用时执行：

```bash
python3 -m venv .venv-psd
.venv-psd/bin/python -m pip install -r assets/craftpix/scripts/requirements-psd.txt
```

查看 PSD 中所有可选图层：

```bash
.venv-psd/bin/python assets/craftpix/scripts/export_character_psd.py list
```

生成 Godot 人物编辑器使用的组件库：

```bash
.venv-psd/bin/python assets/craftpix/scripts/export_character_psd.py export-components \
  --default-preset assets/craftpix/scripts/presets/craftpix-net-254170-rpg-character-sprite-sheet-generator/example_pale_adventurer.json
```

输出位于原素材包内部：

```text
craftpix-net-254170-rpg-character-sprite-sheet-generator/exported/
├── character_components.json
└── components/<group>/<part>.png
```

每个组件仍是 `144x192 RGBA`，保持三列动作帧、四行方向帧和 PSD 原始绘制顺序。目录会排除 Photoshop 辅助层；重新导出时会清理已经失效的组件 PNG。

角色预设置于：

```text
assets/craftpix/scripts/presets/
  craftpix-net-254170-rpg-character-sprite-sheet-generator/
    example_pale_adventurer.json
```

预设中的 `groups` 值可以是一个图层名，也可以是多个图层名组成的数组。后者适合
同时选择披风、腰带等多个附件。若需要 PSD 自带的脚底阴影，设置：

```json
"include_top_level": ["Shadow"]
```

需要把某个组合单独导成完整 spritesheet 进行像素对照时：

```bash
.venv-psd/bin/python assets/craftpix/scripts/export_character_psd.py export \
  --preset assets/craftpix/scripts/presets/craftpix-net-254170-rpg-character-sprite-sheet-generator/example_pale_adventurer.json \
  --output assets/craftpix/craftpix-net-254170-rpg-character-sprite-sheet-generator/exported/example_pale_adventurer.png
```

输出为 `144x192 RGBA`，三列动作帧、四行方向帧，每帧 `48x48`。方向顺序为
`down`、`left`、`right`、`up`；每行是 `step_a`、`idle`、`step_b`。

需要同时拆出 12 张单帧图片时，在导出命令后追加：

```bash
--frames-dir /tmp/example_pale_adventurer_frames
```

运行导出器测试：

```bash
.venv-psd/bin/python -m unittest assets/craftpix/scripts/tests/test_export_character_psd.py
```
