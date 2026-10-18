# L4D2 战役服务器插件包

给一台**纯净的 L4D2 专用服务器**用的战役插件包，分成四个文件夹，每个文件夹都和服务器的 `left4dead2/` 目录结构一致，直接复制进去即可。

| 文件夹 | 内容 | 是否必装 |
|---|---|---|
| `core/` | MetaMod:Source + SourceMod 1.12 本体、常用扩展、`server.cfg` | 必装 |
| `basic/` | 基础模块：突破人数上限、多人生还者、闲置/加入、投票换图、终局自动换图、100 tick、管理员菜单 | 建议装 |
| `advanced/` | 进阶模块：药役 / 硬核药役 / Anne 风格药役，游戏中随时 `!mode` 投票切换 | 可选 |
| `fun/` | 娱乐模块：倒地爬行、马格南电磁炮、自动炮台、自动回血、击杀回血 | 可选 |

所有插件都已经用 SourceMod 1.12 编译器编译好（`.smx`），源码 `.sp` 一起放在各模块的 `addons/sourcemod/scripting/` 下。

> 说明：插件全部编译通过，但我没有可用的 L4D2 服务器来实际运行测试。第一次上线请先在自己的服务器上跑一遍，有报错把 `addons/sourcemod/logs/errors_*.log` 发出来即可定位。

---

## 安装

1. 关掉服务器。
2. 依次把 `core/`、`basic/`、`advanced/`、`fun/` **里面的内容**复制到服务器的 `left4dead2/` 目录（同名文件夹合并，提示覆盖时选覆盖）。不需要的模块不复制即可，`core` 必须装。
3. 打开 `left4dead2/cfg/server.cfg`，改服务器名和 `rcon_password`。
4. 添加管理员：编辑 `left4dead2/addons/sourcemod/configs/admins_simple.ini`，加一行
   ```
   "STEAM_1:0:12345678" "99:z"
   ```
   换成你自己的 SteamID（进服后控制台输入 `status` 可以看到）。
5. 用 `server-scripts/` 里的启动脚本启动（放到 `srcds_run` / `srcds.exe` 所在的服务器根目录）。关键启动参数：
   ```
   -game left4dead2 -ip 0.0.0.0 -tickrate 100 +map c1m1_hotel +exec server.cfg
   ```
6. 进服后控制台输入 `sm plugins list` 和 `meta list`，确认插件都在运行。

**启动后自动退出 / 崩溃怎么排查**

1. 把 `left4dead2/addons/metamod.vdf` 改名为 `metamod.vdf.bak` 再启动，这样 MetaMod、SourceMod 和所有插件都不会加载。
   * 这样能正常启动：问题在插件包里，把文件名改回来，看下一步。
   * 这样还是退出：问题在服务器本体或启动参数，先用 steamcmd 执行 `app_update 222860 validate` 修复游戏文件。
2. 看 `left4dead2/addons/sourcemod/logs/` 下最新的 `errors_*.log` 和 `L*.log`。
3. 启动参数加 `-debug`，崩溃时会在服务器根目录生成 `debug.log`。

**Linux 注意**：Actions 扩展需要 GLIBC 2.35 以上，也就是 Ubuntu 22.04 / Debian 12 或更新的系统（用 `ldd --version` 查看）。l4dtoolz 和 tickrate_enabler 用的是官方的 `oldlinux` 构建（GLIBC 2.34），兼容性更好。Windows 服务器没有这个限制。

---

## core：SourceMod 本体

| 组件 | 版本 | 来源 |
|---|---|---|
| MetaMod:Source | 1.12（dev 1194） | 取自 [SirPlease/L4D2-Competitive-Rework](https://github.com/SirPlease/L4D2-Competitive-Rework) |
| SourceMod | 1.12.0.7230 | 同上；只保留官方自带的插件、扩展、翻译和配置 |
| Actions 扩展 | 4.0.1 | [Vinillia/actions.ext](https://github.com/Vinillia/actions.ext) Releases |
| SourceScramble、BuiltinVotes 扩展 | — | 取自 SirPlease/L4D2-Competitive-Rework |

`core/addons/sourcemod/scripting/include/` 是编译用的头文件（SourceMod 官方 + 各插件依赖），服务器运行不需要。

## basic：基础模块

| 功能 | 插件 | 作者 / 来源 | 常用命令 |
|---|---|---|---|
| 突破 4 人 / 8 人上限 | l4dtoolz 2.2.0（MetaMod 插件） | [accelerator74/l4dtoolz](https://github.com/accelerator74/l4dtoolz) | `server.cfg` 里的 `sv_maxplayers` |
| 100 tick | Tickrate Enabler | [accelerator74/Tickrate-Enabler](https://github.com/accelerator74/Tickrate-Enabler)（ProdigySim） | 启动参数 `-tickrate 100` |
| 高 tick 网络参数 | l4d2_tick_network_tweaks | [fdxx/l4d2_plugins](https://github.com/fdxx/l4d2_plugins) | 自动按 `-tickrate` 设置 |
| 高 tick 修正（门速度等） | TickrateFixes | Sir, Griffin, A1m`（SirPlease 仓库） | `tick_door_speed` |
| 公共依赖 | Left 4 DHooks 1.174 | [SilvDev/Left4DHooks](https://github.com/SilvDev/Left4DHooks)（Silvers） | — |
| 5 人以上生还者 | l4dmultislots + l4d_CreateSurvivorBot | [fbef0102/L4D1_2-Plugins](https://github.com/fbef0102/L4D1_2-Plugins)（HarryPotter） | `!join` `!js`，管理员 `sm_muladdbot` |
| 闲置 / 换队 | l4d_afk_commands | HarryPotter | `!afk` `!join` `!spec` `!zs`(自杀) |
| 投票换图 | l4d2_map_vote + l4d2_nativevote + l4d2_source_keyvalues | fdxx（[nativevote](https://github.com/fdxx/l4d2_nativevote)、[source_keyvalues](https://github.com/fdxx/l4d2_source_keyvalues)） | `!mapvote` `!votemap` `!v3` |
| 终局自动换图 | l4d2_next_map | fdxx | `!view_nextmap`，管理员 `sm_set_nextmap` |
| 管理员菜单扩展 | all4dead2 + spawn_infected_nolimit | HarryPotter | `!admin` 菜单里刷特感、刷物品、尸潮 |
| 管理员复活 | l4d_sm_respawn | HarryPotter | `sm_respawn <玩家>` |
| 管理员基础 | SourceMod 自带 admin / basevotes / funcommands 等 | AlliedModders | `!admin` |

人数设置：`server.cfg` 的 `sv_maxplayers`（真人上限）和 `cfg/sourcemod/l4dmultislots.cfg` 的 `l4d_multislots_max_survivors`（生还者上限），默认都是 8。

## advanced：进阶模块（药役，随时切换）

进服后输入 **`!mode`**（或 `!modes`、`!moshi`）打开菜单，选模式后发起游戏原生投票，过半同意立即切换。管理员（权限 `c`）选择时直接生效，也可以用控制台 `sm_setmode <键名>`。

| 键名 | 模式 | 内容 |
|---|---|---|
| `normal` | 原版战役 | 不加载任何难度插件 |
| `pills` | 药役（普通） | 4 特 / 16 秒刷新；只有止痛药和 T1 武器（无包、电击器、投掷物、升级包）；AI 特感加强（AI_HardSI） |
| `pills_hard` | 药役（硬核） | 6 特 / 10 秒，在离生还者最近的视野外刷新，Hunter 和 Charger 各 2 只 |
| `anne` | Anne 风格药役 | 6 特 / 16 秒，一波死完再刷；使用 AnneHappy 的 AI（Hunter/Jockey/Charger/Spitter/Boomer/Smoker/Tank）和目标分配 |

药役模式下 `!mode` 里还可以投票调整**特感数量**（2~12 特）、**刷新时间**（5~30 秒）、**刷新位置**、**一起复活**。

工作方式：

* 难度插件放在 `plugins/disabled/` 下，SourceMod 不会自动加载，由 `l4d2_mode_switcher` 按模式加载 / 卸载。
* 每个模式的参数写在 `cfg/l4d2_modes/<键名>.cfg`，用 `sm_mode_cvar` 修改 cvar，切回其他模式时自动还原。
* 当前模式会记住，换图、重启服务器后保持。想固定开服模式，把 `cfg/sourcemod/l4d2_mode_switcher.cfg` 里的 `l4d2_mode_remember` 设为 0、`l4d2_mode_default` 设为想要的键名。
* 特感和 AI 立即生效；物品规则从下一回合开始生效。想切换后立刻重开本章节，设置 `l4d2_mode_restart_on_switch 1`。
* 新增模式：在 `addons/sourcemod/configs/l4d2_modes.cfg` 里加一段，写好 `cfg/l4d2_modes/` 下的 cfg，然后 `sm_mode_reload`。

| 插件 | 作者 / 来源 | 说明 |
|---|---|---|
| l4d2_mode_switcher | 本仓库编写 | 模式投票、插件加载卸载、cvar 还原 |
| l4d2_si_spawn_control | fdxx | 特感数量、刷新时间、刷新位置控制（需要 SourceScramble 扩展） |
| l4d2_item_rule | fdxx | 物品替换 / 限制（把包换成药、高级枪换成小枪） |
| AI_HardSI | HarryPotter（原作者 Breezy） | 药役两个模式用的 AI 特感加强 |
| ai_hunter_2 / ai_jockey_2 / ai_charger_2 / ai_spitter_2 / ai_boomer_2 / ai_smoker_new / ai_tank_new | 夜羽真白 等，取自 [fantasylidong/CompetitiveWithAnne](https://github.com/fantasylidong/CompetitiveWithAnne) | Anne 模式的 AI |
| SI_Target_limit / l4d_target_override | AnneHappy / Silvers | 限制同一个人被几只控制型特感盯上 |

**关于 Anne 和 AST**：完整的 AnneHappy 是一整套对抗改战役的服务器包（基于 confogl 和 `coop_base_versus`，400 多个插件，并依赖 MySQL），没法和本插件包混装。这里只取了它的 AI 插件，刷特改用 fdxx 的 l4d2_si_spawn_control，所以叫"Anne 风格"。想要原汁原味的 Anne，请单独开一台服务器装 [CompetitiveWithAnne 的 Release 包](https://github.com/fantasylidong/CompetitiveWithAnne/releases)（选 `nomysql` 版本）。"AST" 药役在 GitHub 上没有找到公开源码，药役（普通 / 硬核）两个模式是按常见药役规则配置的。

改动说明：`ai_tank_new.sp` 原本依赖 Anne 刷特插件的 `l4d_infected_limit`，找不到时会直接报错；已改为依次回退到 `l4d2_si_spawn_control_max_specials`，再回退到新建的 `ai_tank_si_limit`。`cfg/AI_HardSI/aggressive_ai.cfg` 把 `sm_cvar` 换成了 `sm_mode_cvar`，切回原版时这些官方 cvar 会被还原。两处都在文件里加了注释。

## fun：娱乐模块

GitHub 上没有找到能直接用的倒地爬行、电磁炮、炮台插件（Silvers 的 Incapped Crawling、Machine Gun System 只发布在 AlliedModders 论坛，而且后者 2021 年已停更），所以这四个插件是本仓库重新编写的，只依赖 Left 4 DHooks。

| 插件 | 命令 | 主要 cvar（`cfg/sourcemod/<插件名>.cfg`，首次启动自动生成） |
|---|---|---|
| **倒地爬行** l4d2_incap_crawl | 倒地后按住前进 | `l4d2_crawl_speed` 速度，`l4d2_crawl_hurt` 爬行每秒掉血，`l4d2_crawl_anim` 第三人称爬行动作；被控时不能爬 |
| **马格南电磁炮** l4d2_magnum_railgun | `!railgun` / `!dcp` 开关 | 马格南开火射出穿透光束，路径上所有感染者都受伤，特感被击退；按住装弹键蓄能最多 3 倍伤害。`l4d2_railgun_damage_*` 伤害，`l4d2_railgun_cooldown` 冷却，`l4d2_railgun_access` 权限 |
| **自动炮台** l4d2_auto_turret | `!turret` / `!pt` 放置，`!removeturret` 收回 | 自动转向射击视野内感染者（特感优先），400 发子弹，存在 120 秒，每人 1 台、全图 6 台。`l4d2_turret_*` |
| **自动回血** l4d2_auto_regen | — | 6 秒没受伤后每秒回 2 点实血，最多到 100（实血+虚血）。`l4d2_regen_*` |
| **击杀回血** l4d2_kill_si_restore_health | — | fdxx 作者。数值在 `cfg/sourcemod/l4d2_pack_fun.cfg` |

---

## 自己编译

```bash
./build.sh            # 编译全部模块
./build.sh fun        # 只编译某个模块
```

规则：`<模块>/addons/sourcemod/scripting/<子目录>/x.sp` 编译到 `<模块>/addons/sourcemod/plugins/<子目录>/x.smx`；子目录名以 `disabled_` 开头的输出到 `plugins/disabled/<名字>/`（不自动加载）。编译器在 `tools/spcomp/`（SourceMod 1.12.0.7230），Windows 下可以直接用 `tools/spcomp/spcomp.exe` 手动编译。

## 许可与致谢

本仓库编写的插件以 GPLv3 发布（见 `LICENSE`）。收录的第三方插件、扩展和 SourceMod / MetaMod 均保留原作者署名和原始许可（上游均为 GPLv3；SourceMod 的许可见 `core/addons/sourcemod/LICENSE.txt`），版权归原作者所有：

AlliedModders（SourceMod、MetaMod:Source）、Silvers（Left 4 DHooks、Target Override）、HarryPotter / fbef0102、fdxx、accelerator74、ProdigySim、Vinillia / BHaType（Actions）、nosoop（SourceScramble）、SirPlease 与 Competitive Rework 团队、fantasylidong（morzlee）与 AnneHappy 团队（夜羽真白、Caibiii、GlowingTree880 等）、Breezy（AI_HardSI 原作者）、Panxiaohai（炮台插件思路）。
