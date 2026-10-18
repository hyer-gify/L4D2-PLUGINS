/**
 * L4D2 Mode Switcher - 战役难度模式切换（原版 / 药役 / Anne 风格 ...）
 *
 * 玩家输入 !mode 打开菜单，选择模式或参数后发起游戏内原生投票，通过后立即切换：
 *   1. 还原上一个模式用 sm_mode_cvar 改过的 cvar；
 *   2. 卸载上一个模式独有的插件，加载新模式需要的插件（插件放在 plugins/disabled/ 下，不会被自动加载）；
 *   3. 延迟执行新模式的 cfg（等新加载的插件建好 cvar 和命令）。
 * 每次换图后会重新确认插件已加载并再次执行当前模式 cfg，服务器重启后恢复上次的模式。
 *
 * 配置文件: addons/sourcemod/configs/l4d2_modes.cfg
 * 投票界面依赖 l4d2_nativevote（基础模块自带）；没有它时自动退回 SourceMod 菜单投票。
 *
 * License: GPLv3
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#undef REQUIRE_PLUGIN
#include <l4d2_nativevote>

#define PLUGIN_VERSION "1.0.0"
#define CONFIG_FILE "configs/l4d2_modes.cfg"
#define STATE_FILE "data/l4d2_mode_switcher.txt"

public Plugin myinfo =
{
	name = "L4D2 Mode Switcher",
	author = "L4D2-PLUGINS",
	description = "投票切换战役模式（原版 / 药役 / Anne 风格）并管理对应插件和 cvar",
	version = PLUGIN_VERSION,
	url = "https://github.com/hyer-gify/L4D2-PLUGINS"
};

ConVar g_cvVoteTime, g_cvVoteRatio, g_cvCooldown, g_cvApplyDelay, g_cvRestartOnSwitch, g_cvDefaultMode, g_cvRemember, g_cvAdminInstant;

KeyValues g_kvModes;
char g_sCurrentMode[64];
float g_fLastVote;
bool g_bNativeVote;

// cvar 名 -> 被模式第一次修改前的值，切换模式时还原
StringMap g_smOriginal;
ArrayList g_aOriginalNames;

// 当前模式下通过投票选中的参数：组名 -> 命令；换图后重放，切换模式时清空
StringMap g_smOptions;
ArrayList g_aOptionGroups;

// 发起中的投票
char g_sPendingType[16];	// "mode" / "option"
char g_sPendingKey[64];
char g_sPendingGroup[64];

public void OnPluginStart()
{
	CreateConVar("l4d2_mode_switcher_version", PLUGIN_VERSION, "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvVoteTime = CreateConVar("l4d2_mode_vote_time", "20", "投票持续时间（秒）", FCVAR_NONE, true, 5.0, true, 60.0);
	g_cvVoteRatio = CreateConVar("l4d2_mode_vote_ratio", "0.5", "赞成票占参与投票真人玩家的比例超过该值即通过", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvCooldown = CreateConVar("l4d2_mode_vote_cooldown", "30", "两次投票之间的冷却时间（秒）", FCVAR_NONE, true, 0.0);
	g_cvApplyDelay = CreateConVar("l4d2_mode_apply_delay", "1.0", "加载插件后延迟多少秒执行模式 cfg", FCVAR_NONE, true, 0.1, true, 10.0);
	g_cvRestartOnSwitch = CreateConVar("l4d2_mode_restart_on_switch", "0", "切换模式后是否重开当前章节，让物品规则立刻生效（0=否 1=是）", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDefaultMode = CreateConVar("l4d2_mode_default", "normal", "服务器启动时使用的模式（l4d2_modes.cfg 里的键名）");
	g_cvRemember = CreateConVar("l4d2_mode_remember", "1", "服务器重启后是否恢复上一次的模式（0=使用 l4d2_mode_default）", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvAdminInstant = CreateConVar("l4d2_mode_admin_instant", "1", "管理员（权限 c）在菜单中选择时是否跳过投票直接生效", FCVAR_NONE, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d2_mode_switcher");

	RegConsoleCmd("sm_mode", Cmd_Mode, "打开模式切换菜单");
	RegConsoleCmd("sm_modes", Cmd_Mode, "打开模式切换菜单");
	RegConsoleCmd("sm_moshi", Cmd_Mode, "打开模式切换菜单");
	RegAdminCmd("sm_setmode", Cmd_SetMode, ADMFLAG_CONFIG, "sm_setmode <模式键名> - 直接切换模式");
	RegAdminCmd("sm_mode_reload", Cmd_Reload, ADMFLAG_CONFIG, "重新读取 l4d2_modes.cfg");
	RegServerCmd("sm_mode_cvar", Cmd_ModeCvar, "sm_mode_cvar <cvar> <值> - 修改 cvar，并在切换模式时自动还原");
	RegServerCmd("sm_mode_resetcvar", Cmd_ModeResetCvar, "sm_mode_resetcvar <cvar> [cvar...] - 把 cvar 恢复为游戏默认值");

	g_smOriginal = new StringMap();
	g_aOriginalNames = new ArrayList(ByteCountToCells(128));
	g_smOptions = new StringMap();
	g_aOptionGroups = new ArrayList(ByteCountToCells(64));

	LoadModes();
}

public void OnAllPluginsLoaded()
{
	g_bNativeVote = LibraryExists("l4d2_nativevote") || GetFeatureStatus(FeatureType_Native, "L4D2NativeVote_IsAllowNewVote") == FeatureStatus_Available;
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "l4d2_nativevote"))
		g_bNativeVote = true;
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "l4d2_nativevote"))
		g_bNativeVote = false;
}

public void OnPluginEnd()
{
	RestoreOriginalCvars();
}

// ---------------------------------------------------------------------------
// 配置与状态
// ---------------------------------------------------------------------------

bool LoadModes()
{
	delete g_kvModes;
	g_kvModes = new KeyValues("Modes");

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CONFIG_FILE);
	if (!g_kvModes.ImportFromFile(path))
	{
		LogError("无法读取模式配置: %s", path);
		return false;
	}
	return true;
}

bool JumpToMode(const char[] key)
{
	g_kvModes.Rewind();
	if (!g_kvModes.JumpToKey("modes"))
		return false;
	return g_kvModes.JumpToKey(key);
}

bool ModeExists(const char[] key)
{
	bool ok = JumpToMode(key);
	g_kvModes.Rewind();
	return ok;
}

void GetModeString(const char[] key, const char[] field, char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	if (JumpToMode(key))
		g_kvModes.GetString(field, buffer, maxlen);
	g_kvModes.Rewind();
}

bool ModeAllowsOptions(const char[] key)
{
	bool allow = false;
	if (JumpToMode(key))
		allow = g_kvModes.GetNum("options", 0) != 0;
	g_kvModes.Rewind();
	return allow;
}

void SaveState()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), STATE_FILE);
	File f = OpenFile(path, "w");
	if (f == null)
		return;
	f.WriteLine("%s", g_sCurrentMode);
	delete f;
}

void ReadState(char[] buffer, int maxlen)
{
	buffer[0] = '\0';
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), STATE_FILE);
	File f = OpenFile(path, "r");
	if (f == null)
		return;
	if (f.ReadLine(buffer, maxlen))
		TrimString(buffer);
	delete f;
}

// ---------------------------------------------------------------------------
// 模式应用
// ---------------------------------------------------------------------------

public void OnConfigsExecuted()
{
	if (g_sCurrentMode[0] == '\0')
	{
		char mode[64];
		if (g_cvRemember.BoolValue)
			ReadState(mode, sizeof(mode));
		if (mode[0] == '\0' || !ModeExists(mode))
			g_cvDefaultMode.GetString(mode, sizeof(mode));
		if (!ModeExists(mode))
		{
			LogError("默认模式 \"%s\" 不存在于 %s", mode, CONFIG_FILE);
			return;
		}
		ApplyMode(mode, false);
		return;
	}

	// 换图：插件仍在，但插件自己的 cfg 可能把参数改回默认，重新执行一次
	LoadModePlugins(g_sCurrentMode);
	CreateTimer(g_cvApplyDelay.FloatValue, Timer_ExecModeCfg, _, TIMER_FLAG_NO_MAPCHANGE);
}

void ApplyMode(const char[] mode, bool announce)
{
	char oldMode[64];
	strcopy(oldMode, sizeof(oldMode), g_sCurrentMode);

	RestoreOriginalCvars();
	g_smOptions.Clear();
	g_aOptionGroups.Clear();

	if (oldMode[0] != '\0')
		UnloadModePlugins(oldMode, mode);

	strcopy(g_sCurrentMode, sizeof(g_sCurrentMode), mode);
	SaveState();

	char reset[PLATFORM_MAX_PATH];
	g_kvModes.Rewind();
	g_kvModes.GetString("reset_cfg", reset, sizeof(reset), "");
	if (reset[0] != '\0')
		ServerCommand("exec \"%s\"", reset);

	LoadModePlugins(mode);
	CreateTimer(g_cvApplyDelay.FloatValue, Timer_ExecModeCfg, announce, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ExecModeCfg(Handle timer, bool announce)
{
	char cfg[PLATFORM_MAX_PATH];
	GetModeString(g_sCurrentMode, "cfg", cfg, sizeof(cfg));
	if (cfg[0] != '\0')
		ServerCommand("exec \"%s\"", cfg);

	// 重放本模式下投票选中的参数
	char group[64], cmd[256];
	for (int i = 0; i < g_aOptionGroups.Length; i++)
	{
		g_aOptionGroups.GetString(i, group, sizeof(group));
		if (g_smOptions.GetString(group, cmd, sizeof(cmd)))
			ServerCommand("%s", cmd);
	}

	if (announce)
	{
		char name[64];
		GetModeString(g_sCurrentMode, "name", name, sizeof(name));
		PrintToChatAll("\x04[模式]\x01 已切换为 \x05%s", name);
		if (g_cvRestartOnSwitch.BoolValue)
		{
			PrintToChatAll("\x04[模式]\x01 3 秒后重开本章节以应用物品规则。");
			CreateTimer(3.0, Timer_RestartMap, _, TIMER_FLAG_NO_MAPCHANGE);
		}
		else
		{
			PrintToChatAll("\x04[模式]\x01 特感与 AI 立即生效，物品规则从下一回合开始生效。");
		}
	}
	return Plugin_Stop;
}

Action Timer_RestartMap(Handle timer)
{
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	ServerCommand("changelevel %s", map);
	return Plugin_Stop;
}

int GetModePlugins(const char[] mode, char[][] list, int maxCount, int maxlen)
{
	char buffer[2048];
	GetModeString(mode, "plugins", buffer, sizeof(buffer));
	if (buffer[0] == '\0')
		return 0;
	int count = ExplodeString(buffer, ";", list, maxCount, maxlen);
	for (int i = 0; i < count; i++)
		TrimString(list[i]);
	return count;
}

void LoadModePlugins(const char[] mode)
{
	char list[32][PLATFORM_MAX_PATH];
	int count = GetModePlugins(mode, list, sizeof(list), sizeof(list[]));
	bool loaded = false;
	for (int i = 0; i < count; i++)
	{
		if (list[i][0] != '\0' && FindPluginByFile(list[i]) == null)
		{
			ServerCommand("sm plugins load \"%s\"", list[i]);
			loaded = true;
		}
	}

	// left4dhooks 只在地图开始时检查哪些插件用到了它的回调（L4D_OnSpawnSpecial 等），
	// 地图中途加载的插件要让它重新检查一次，否则这些回调到下一张图才会生效。
	if (loaded && CommandExists("sm_l4dd_reload"))
		ServerCommand("sm_l4dd_reload");
}

void UnloadModePlugins(const char[] oldMode, const char[] newMode)
{
	char oldList[32][PLATFORM_MAX_PATH], newList[32][PLATFORM_MAX_PATH];
	int oldCount = GetModePlugins(oldMode, oldList, sizeof(oldList), sizeof(oldList[]));
	int newCount = GetModePlugins(newMode, newList, sizeof(newList), sizeof(newList[]));

	// 倒序卸载，让依赖其他插件的插件先卸载
	for (int i = oldCount - 1; i >= 0; i--)
	{
		bool keep = false;
		for (int j = 0; j < newCount; j++)
		{
			if (StrEqual(oldList[i], newList[j], false))
			{
				keep = true;
				break;
			}
		}
		if (!keep && oldList[i][0] != '\0')
			ServerCommand("sm plugins unload \"%s\"", oldList[i]);
	}
}

// ---------------------------------------------------------------------------
// cvar 记录与还原
// ---------------------------------------------------------------------------

Action Cmd_ModeCvar(int args)
{
	if (args < 2)
	{
		PrintToServer("用法: sm_mode_cvar <cvar> <值>");
		return Plugin_Handled;
	}

	char name[128], value[256];
	GetCmdArg(1, name, sizeof(name));
	GetCmdArg(2, value, sizeof(value));

	ConVar cv = FindConVar(name);
	if (cv == null)
	{
		LogMessage("sm_mode_cvar: 找不到 cvar \"%s\"（对应插件可能未加载）", name);
		return Plugin_Handled;
	}

	char original[256];
	if (!g_smOriginal.GetString(name, original, sizeof(original)))
	{
		cv.GetString(original, sizeof(original));
		g_smOriginal.SetString(name, original);
		g_aOriginalNames.PushString(name);
	}

	cv.SetString(value, true, false);
	return Plugin_Handled;
}

Action Cmd_ModeResetCvar(int args)
{
	char name[128];
	for (int i = 1; i <= args; i++)
	{
		GetCmdArg(i, name, sizeof(name));
		ConVar cv = FindConVar(name);
		if (cv != null)
			cv.RestoreDefault(true, false);
	}
	return Plugin_Handled;
}

void RestoreOriginalCvars()
{
	char name[128], value[256];
	for (int i = 0; i < g_aOriginalNames.Length; i++)
	{
		g_aOriginalNames.GetString(i, name, sizeof(name));
		if (!g_smOriginal.GetString(name, value, sizeof(value)))
			continue;
		ConVar cv = FindConVar(name);
		if (cv != null)
			cv.SetString(value, true, false);
	}
	g_smOriginal.Clear();
	g_aOriginalNames.Clear();
}

// ---------------------------------------------------------------------------
// 命令
// ---------------------------------------------------------------------------

Action Cmd_Reload(int client, int args)
{
	if (LoadModes())
		ReplyToCommand(client, "[模式] 已重新读取 %s", CONFIG_FILE);
	else
		ReplyToCommand(client, "[模式] 读取 %s 失败，请检查文件格式", CONFIG_FILE);
	return Plugin_Handled;
}

Action Cmd_SetMode(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "用法: sm_setmode <模式键名>，当前模式: %s", g_sCurrentMode);
		ListModesToConsole(client);
		return Plugin_Handled;
	}

	char mode[64];
	GetCmdArg(1, mode, sizeof(mode));
	if (!ModeExists(mode))
	{
		ReplyToCommand(client, "[模式] 不存在模式 \"%s\"", mode);
		ListModesToConsole(client);
		return Plugin_Handled;
	}

	ApplyMode(mode, true);
	return Plugin_Handled;
}

void ListModesToConsole(int client)
{
	g_kvModes.Rewind();
	if (!g_kvModes.JumpToKey("modes") || !g_kvModes.GotoFirstSubKey())
	{
		g_kvModes.Rewind();
		return;
	}
	char key[64], name[64];
	do
	{
		g_kvModes.GetSectionName(key, sizeof(key));
		g_kvModes.GetString("name", name, sizeof(name));
		ReplyToCommand(client, "  %s - %s", key, name);
	} while (g_kvModes.GotoNextKey());
	g_kvModes.Rewind();
}

Action Cmd_Mode(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[模式] 当前模式: %s", g_sCurrentMode);
		ListModesToConsole(client);
		return Plugin_Handled;
	}
	ShowMainMenu(client);
	return Plugin_Handled;
}

// ---------------------------------------------------------------------------
// 菜单
// ---------------------------------------------------------------------------

void ShowMainMenu(int client)
{
	char curName[64];
	GetModeString(g_sCurrentMode, "name", curName, sizeof(curName));

	Menu menu = new Menu(MainMenu_Handler);
	menu.SetTitle("模式切换\n当前: %s\n ", curName);
	menu.AddItem("modes", "切换模式");
	menu.AddItem("options", "调整参数（特感数量 / 刷新时间）", ModeAllowsOptions(g_sCurrentMode) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.Display(client, MENU_TIME_FOREVER);
}

int MainMenu_Handler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[16];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "modes"))
			ShowModeMenu(client);
		else
			ShowOptionGroupMenu(client);
	}
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

void ShowModeMenu(int client)
{
	Menu menu = new Menu(ModeMenu_Handler);
	menu.SetTitle("选择模式");
	menu.ExitBackButton = true;

	g_kvModes.Rewind();
	if (g_kvModes.JumpToKey("modes") && g_kvModes.GotoFirstSubKey())
	{
		char key[64], name[64], display[160], desc[96];
		do
		{
			g_kvModes.GetSectionName(key, sizeof(key));
			g_kvModes.GetString("name", name, sizeof(name));
			g_kvModes.GetString("desc", desc, sizeof(desc));
			if (desc[0] != '\0')
				FormatEx(display, sizeof(display), "%s%s\n   %s", name, StrEqual(key, g_sCurrentMode) ? "（当前）" : "", desc);
			else
				FormatEx(display, sizeof(display), "%s%s", name, StrEqual(key, g_sCurrentMode) ? "（当前）" : "");
			menu.AddItem(key, display, StrEqual(key, g_sCurrentMode) ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
		} while (g_kvModes.GotoNextKey());
	}
	g_kvModes.Rewind();
	menu.Display(client, MENU_TIME_FOREVER);
}

int ModeMenu_Handler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char key[64];
		menu.GetItem(item, key, sizeof(key));
		RequestChange(client, "mode", key, "");
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
		ShowMainMenu(client);
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

void ShowOptionGroupMenu(int client)
{
	Menu menu = new Menu(OptionGroup_Handler);
	menu.SetTitle("调整参数");
	menu.ExitBackButton = true;

	g_kvModes.Rewind();
	if (g_kvModes.JumpToKey("options") && g_kvModes.GotoFirstSubKey())
	{
		char group[64];
		do
		{
			g_kvModes.GetSectionName(group, sizeof(group));
			menu.AddItem(group, group);
		} while (g_kvModes.GotoNextKey());
	}
	g_kvModes.Rewind();
	menu.Display(client, MENU_TIME_FOREVER);
}

int OptionGroup_Handler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char group[64];
		menu.GetItem(item, group, sizeof(group));
		ShowOptionMenu(client, group);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
		ShowMainMenu(client);
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

void ShowOptionMenu(int client, const char[] group)
{
	Menu menu = new Menu(Option_Handler);
	menu.SetTitle("%s", group);
	menu.ExitBackButton = true;

	g_kvModes.Rewind();
	if (g_kvModes.JumpToKey("options") && g_kvModes.JumpToKey(group) && g_kvModes.GotoFirstSubKey(false))
	{
		char label[64], info[160];
		do
		{
			g_kvModes.GetSectionName(label, sizeof(label));
			FormatEx(info, sizeof(info), "%s\n%s", group, label);
			menu.AddItem(info, label);
		} while (g_kvModes.GotoNextKey(false));
	}
	g_kvModes.Rewind();
	menu.Display(client, MENU_TIME_FOREVER);
}

int Option_Handler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[160], parts[2][64];
		menu.GetItem(item, info, sizeof(info));
		ExplodeString(info, "\n", parts, sizeof(parts), sizeof(parts[]));
		RequestChange(client, "option", parts[1], parts[0]);
	}
	else if (action == MenuAction_Cancel && item == MenuCancel_ExitBack)
		ShowOptionGroupMenu(client);
	else if (action == MenuAction_End)
		delete menu;
	return 0;
}

bool GetOptionCommand(const char[] group, const char[] label, char[] cmd, int maxlen)
{
	cmd[0] = '\0';
	g_kvModes.Rewind();
	bool ok = g_kvModes.JumpToKey("options") && g_kvModes.JumpToKey(group);
	if (ok)
		g_kvModes.GetString(label, cmd, maxlen);
	g_kvModes.Rewind();
	return ok && cmd[0] != '\0';
}

// ---------------------------------------------------------------------------
// 投票
// ---------------------------------------------------------------------------

void RequestChange(int client, const char[] type, const char[] key, const char[] group)
{
	if (StrEqual(type, "option") && !ModeAllowsOptions(g_sCurrentMode))
	{
		PrintToChat(client, "\x04[模式]\x01 当前模式不支持调整参数。");
		return;
	}

	if (g_cvAdminInstant.BoolValue && CheckCommandAccess(client, "sm_setmode", ADMFLAG_CONFIG))
	{
		PrintToChatAll("\x04[模式]\x01 管理员 \x05%N\x01 直接执行了更改。", client);
		CommitChange(type, key, group);
		return;
	}

	float now = GetEngineTime();
	float cd = g_cvCooldown.FloatValue;
	if (g_fLastVote > 0.0 && now - g_fLastVote < cd)
	{
		PrintToChat(client, "\x04[模式]\x01 投票冷却中，请 %.0f 秒后再试。", cd - (now - g_fLastVote));
		return;
	}

	char text[192];
	if (StrEqual(type, "mode"))
	{
		char name[64];
		GetModeString(key, "name", name, sizeof(name));
		FormatEx(text, sizeof(text), "切换为 %s 模式?", name);
	}
	else
		FormatEx(text, sizeof(text), "%s 改为 %s?", group, key);

	strcopy(g_sPendingType, sizeof(g_sPendingType), type);
	strcopy(g_sPendingKey, sizeof(g_sPendingKey), key);
	strcopy(g_sPendingGroup, sizeof(g_sPendingGroup), group);

	int[] clients = new int[MaxClients];
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			clients[count++] = i;
	}

	if (g_bNativeVote)
	{
		if (!L4D2NativeVote_IsAllowNewVote())
		{
			PrintToChat(client, "\x04[模式]\x01 当前已有投票在进行。");
			return;
		}
		L4D2NativeVote vote = L4D2NativeVote(NativeVote_Handler);
		vote.SetDisplayText("%s", text);
		vote.Initiator = client;
		if (!vote.DisplayVote(clients, count, g_cvVoteTime.IntValue))
		{
			PrintToChat(client, "\x04[模式]\x01 发起投票失败。");
			return;
		}
	}
	else
	{
		if (IsVoteInProgress())
		{
			PrintToChat(client, "\x04[模式]\x01 当前已有投票在进行。");
			return;
		}
		Menu menu = new Menu(MenuVote_Handler);
		menu.SetTitle("%s", text);
		menu.AddItem("yes", "同意");
		menu.AddItem("no", "反对");
		menu.ExitButton = false;
		menu.DisplayVote(clients, count, g_cvVoteTime.IntValue);
	}

	g_fLastVote = now;
	PrintToChatAll("\x04[模式]\x01 \x05%N\x01 发起投票: %s", client, text);
}

void NativeVote_Handler(L4D2NativeVote vote, VoteAction action, int param1, int param2)
{
	if (action != VoteAction_End)
		return;

	int voted = vote.YesCount + vote.NoCount;
	if (voted > 0 && float(vote.YesCount) / float(voted) > g_cvVoteRatio.FloatValue)
	{
		vote.SetPass("正在切换...");
		CommitChange(g_sPendingType, g_sPendingKey, g_sPendingGroup);
	}
	else
	{
		vote.SetFail();
		PrintToChatAll("\x04[模式]\x01 投票未通过。");
	}
}

int MenuVote_Handler(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_End)
		delete menu;
	else if (action == MenuAction_VoteEnd)
	{
		int votes, totalVotes;
		GetMenuVoteInfo(param2, votes, totalVotes);
		char info[8];
		menu.GetItem(param1, info, sizeof(info));
		float yesRatio = float(votes) / float(totalVotes);
		if (StrEqual(info, "no"))
			yesRatio = 1.0 - yesRatio;
		if (yesRatio > g_cvVoteRatio.FloatValue)
		{
			PrintToChatAll("\x04[模式]\x01 投票通过。");
			CommitChange(g_sPendingType, g_sPendingKey, g_sPendingGroup);
		}
		else
			PrintToChatAll("\x04[模式]\x01 投票未通过。");
	}
	else if (action == MenuAction_VoteCancel && param1 == VoteCancel_NoVotes)
		PrintToChatAll("\x04[模式]\x01 无人投票，已取消。");
	return 0;
}

void CommitChange(const char[] type, const char[] key, const char[] group)
{
	if (StrEqual(type, "mode"))
	{
		if (ModeExists(key))
			ApplyMode(key, true);
		return;
	}

	char cmd[256];
	if (!GetOptionCommand(group, key, cmd, sizeof(cmd)))
		return;

	if (g_aOptionGroups.FindString(group) == -1)
		g_aOptionGroups.PushString(group);
	g_smOptions.SetString(group, cmd);
	ServerCommand("%s", cmd);
	PrintToChatAll("\x04[模式]\x01 %s 已改为 \x05%s", group, key);
}
