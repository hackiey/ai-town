# assets/skeleton

骨架/重定向元数据。被 FBX `.import` 文件引用，不是 runtime 资源。

| 文件 | 类型 | 用途 |
|---|---|---|
| `fk_bone_map.tres` | `BoneMap` | FK `FantasyKingdom_Characters.fbx` import 时引用：humanoid 槽 → Synty bone（如 `LeftUpperArm` ← `Shoulder_L`）。inline 的 SkeletonProfileHumanoid |
| `mixamo_profile.tres` | `SkeletonProfileHumanoid` | Mixamo `*.fbx` import 时它们各自的 BoneMap 引用此为 profile（避免每个 FBX inline 重复创建） |

详细 import 配置和"加新动画 / 加新角色"步骤见 [`src/characters/npcs/README.md`](../../src/characters/npcs/README.md)。
