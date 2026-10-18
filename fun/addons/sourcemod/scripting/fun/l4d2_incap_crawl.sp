/**
 * L4D2 Incapped Crawl - 倒地爬行
 *
 * 倒地后按住前进键可以慢慢爬行。
 * 使用游戏内置的 survivor_allow_crawling / survivor_crawl_speed，
 * 并通过 left4dhooks 的动画钩子把第三人称动作改成爬行动作（游戏模型自带，不需要额外文件）。
 * 思路参考 SilverShot 的 Incapped Crawling（https://forums.alliedmods.net/showthread.php?p=1291797），代码为本仓库重新编写。
 *
 * 依赖: left4dhooks
 * License: GPLv3
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
	name = "[L4D2] Incapped Crawl",
	author = "L4D2-PLUGINS",
	description = "倒地后可以爬行",
	version = PLUGIN_VERSION,
	url = "https://github.com/hyer-gify/L4D2-PLUGINS"
};

ConVar g_cvEnable, g_cvSpeed, g_cvHurt, g_cvSpit, g_cvAnim, g_cvHint;
ConVar g_cvAllowCrawling, g_cvCrawlSpeed;

bool g_bCrawling[MAXPLAYERS + 1];
bool g_bHooked[MAXPLAYERS + 1];
bool g_bHinted[MAXPLAYERS + 1];
float g_fHurtAccum[MAXPLAYERS + 1];

public void OnPluginStart()
{
	g_cvAllowCrawling = FindConVar("survivor_allow_crawling");
	g_cvCrawlSpeed = FindConVar("survivor_crawl_speed");
	if (g_cvAllowCrawling == null || g_cvCrawlSpeed == null)
		SetFailState("找不到 survivor_allow_crawling / survivor_crawl_speed，本插件只支持 L4D2。");

	CreateConVar("l4d2_crawl_version", PLUGIN_VERSION, "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_crawl_enable", "1", "是否允许倒地爬行", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvSpeed = CreateConVar("l4d2_crawl_speed", "15", "爬行速度（写入 survivor_crawl_speed，官方默认 15）", FCVAR_NOTIFY, true, 0.0, true, 200.0);
	g_cvHurt = CreateConVar("l4d2_crawl_hurt", "2", "爬行时每秒额外损失的倒地血量（0=不损失）", FCVAR_NOTIFY, true, 0.0, true, 100.0);
	g_cvSpit = CreateConVar("l4d2_crawl_spit", "1", "站在 Spitter 酸液里时是否允许爬行", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAnim = CreateConVar("l4d2_crawl_anim", "1", "第三人称是否播放爬行动作（0=只移动不换动作）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvHint = CreateConVar("l4d2_crawl_hint", "1", "倒地时是否提示可以爬行（每张图每人一次）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d2_incap_crawl");

	g_cvEnable.AddChangeHook(OnCvarChanged);
	g_cvSpeed.AddChangeHook(OnCvarChanged);

	HookEvent("player_incapacitated", Event_Incapped);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	CreateTimer(0.2, Timer_Hurt, _, TIMER_REPEAT);
}

public void OnPluginEnd()
{
	g_cvAllowCrawling.RestoreDefault();
	g_cvCrawlSpeed.RestoreDefault();
}

public void OnConfigsExecuted()
{
	ApplyCvars();
}

void OnCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ApplyCvars();
}

void ApplyCvars()
{
	g_cvAllowCrawling.SetBool(g_cvEnable.BoolValue);
	g_cvCrawlSpeed.SetInt(g_cvSpeed.IntValue);
}

public void OnMapStart()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		g_bHooked[i] = false;	// 换图时 left4dhooks 会清掉所有动画钩子
		g_bHinted[i] = false;
		g_bCrawling[i] = false;
	}
}

public void OnClientDisconnect(int client)
{
	g_bHooked[client] = false;
	g_bCrawling[client] = false;
	g_bHinted[client] = false;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for (int i = 1; i <= MaxClients; i++)
		g_bCrawling[i] = false;
}

void Event_Incapped(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != 2)
		return;

	if (!g_bHooked[client] && AnimHookEnable(client, OnAnimPre))
		g_bHooked[client] = true;

	if (g_cvEnable.BoolValue && g_cvHint.BoolValue && !g_bHinted[client] && !IsFakeClient(client))
	{
		g_bHinted[client] = true;
		PrintHintText(client, "倒地后按住【前进】可以爬行");
	}
}

bool CanCrawl(int client)
{
	if (!g_cvEnable.BoolValue)
		return false;
	if (!IsPlayerAlive(client) || GetClientTeam(client) != 2)
		return false;
	if (!L4D_IsPlayerIncapacitated(client) || L4D_IsPlayerHangingFromLedge(client))
		return false;
	if (L4D_IsPlayerPinned(client))
		return false;
	if (!g_cvSpit.BoolValue && IsInSpit(client))
		return false;
	return true;
}

bool IsInSpit(int client)
{
	// m_itTimer 是 Spitter 酸液伤害计时器，仍在计时说明正站在酸液里
	return GetEntPropFloat(client, Prop_Send, "m_itTimer", 1) > GetGameTime();
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
	if (!IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client) || !L4D_IsPlayerIncapacitated(client))
	{
		g_bCrawling[client] = false;
		return Plugin_Continue;
	}

	if (!CanCrawl(client))
	{
		g_bCrawling[client] = false;
		// 被控或在酸液里时禁止前进，避免借游戏内置爬行逃脱
		if (g_cvEnable.BoolValue && (buttons & IN_FORWARD))
		{
			buttons &= ~IN_FORWARD;
			vel[0] = 0.0;
			return Plugin_Changed;
		}
		return Plugin_Continue;
	}

	g_bCrawling[client] = (buttons & IN_FORWARD) != 0;
	return Plugin_Continue;
}

Action OnAnimPre(int client, int &sequence)
{
	if (!g_cvAnim.BoolValue || !g_bCrawling[client])
		return Plugin_Continue;

	sequence = L4D2_ACT_TERROR_INCAP_CRAWL;
	return Plugin_Changed;
}

Action Timer_Hurt(Handle timer)
{
	float hurt = g_cvHurt.FloatValue;
	if (hurt <= 0.0)
		return Plugin_Continue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bCrawling[i] || !IsClientInGame(i) || !IsPlayerAlive(i))
			continue;

		g_fHurtAccum[i] += hurt * 0.2;
		int dmg = RoundToFloor(g_fHurtAccum[i]);
		if (dmg <= 0)
			continue;
		g_fHurtAccum[i] -= float(dmg);

		int health = GetClientHealth(i) - dmg;
		if (health < 1)
			health = 1;	// 爬行本身不会把人爬死
		SetEntityHealth(i, health);
	}
	return Plugin_Continue;
}
