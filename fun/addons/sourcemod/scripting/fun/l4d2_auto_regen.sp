/**
 * L4D2 Auto Regen - 自动回血
 *
 * 生还者一段时间没有受伤后，开始自动缓慢回复实血。
 *   - 实血 + 虚血不会超过上限；
 *   - 可选：倒地时也慢慢回复倒地血量；
 *   - 可选：只在安全屋外生效 / 黑白时不回血。
 *
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
	name = "[L4D2] Auto Regen",
	author = "L4D2-PLUGINS",
	description = "生还者脱战后自动回血",
	version = PLUGIN_VERSION,
	url = "https://github.com/hyer-gify/L4D2-PLUGINS"
};

ConVar g_cvEnable, g_cvDelay, g_cvAmount, g_cvInterval, g_cvMax, g_cvIncap, g_cvIncapAmount, g_cvBlackWhite, g_cvBots, g_cvMaxIncaps;

float g_fLastHurt[MAXPLAYERS + 1];
Handle g_hTimer;

public void OnPluginStart()
{
	CreateConVar("l4d2_regen_version", PLUGIN_VERSION, "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_regen_enable", "1", "是否启用自动回血", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDelay = CreateConVar("l4d2_regen_delay", "6.0", "最后一次受伤后多少秒开始回血", FCVAR_NOTIFY, true, 0.0);
	g_cvAmount = CreateConVar("l4d2_regen_amount", "2", "每次回复多少实血", FCVAR_NOTIFY, true, 1.0, true, 100.0);
	g_cvInterval = CreateConVar("l4d2_regen_interval", "1.0", "回血间隔（秒）", FCVAR_NOTIFY, true, 0.1, true, 30.0);
	g_cvMax = CreateConVar("l4d2_regen_max", "100", "最多回到多少血（实血+虚血，不会超过角色血量上限）", FCVAR_NOTIFY, true, 1.0, true, 1000.0);
	g_cvIncap = CreateConVar("l4d2_regen_incap", "0", "倒地时是否也回复倒地血量", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvIncapAmount = CreateConVar("l4d2_regen_incap_amount", "3", "倒地时每次回复多少倒地血量", FCVAR_NOTIFY, true, 1.0, true, 100.0);
	g_cvBlackWhite = CreateConVar("l4d2_regen_black_white", "0", "黑白（最后一条命）时是否继续回血", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvBots = CreateConVar("l4d2_regen_bots", "1", "电脑队友是否也回血", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	AutoExecConfig(true, "l4d2_auto_regen");

	g_cvMaxIncaps = FindConVar("survivor_max_incapacitated_count");
	g_cvInterval.AddChangeHook(OnIntervalChanged);

	HookEvent("player_hurt", Event_PlayerHurt);
	HookEvent("player_spawn", Event_PlayerSpawn);
}

public void OnMapStart()
{
	for (int i = 1; i <= MaxClients; i++)
		g_fLastHurt[i] = 0.0;
	StartTimer();
}

public void OnMapEnd()
{
	g_hTimer = null;
}

void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	StartTimer();
}

void StartTimer()
{
	delete g_hTimer;
	g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Regen, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0)
		g_fLastHurt[client] = GetGameTime();
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0)
		g_fLastHurt[client] = GetGameTime();
}

Action Timer_Regen(Handle timer)
{
	if (!g_cvEnable.BoolValue)
		return Plugin_Continue;

	float now = GetGameTime();
	float delay = g_cvDelay.FloatValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
			continue;
		if (IsFakeClient(i) && !g_cvBots.BoolValue)
			continue;
		if (now - g_fLastHurt[i] < delay)
			continue;
		if (L4D_IsPlayerHangingFromLedge(i))
			continue;

		if (L4D_IsPlayerIncapacitated(i))
		{
			if (!g_cvIncap.BoolValue || L4D_IsPlayerPinned(i))
				continue;
			int health = GetClientHealth(i) + g_cvIncapAmount.IntValue;
			int incapMax = 300;
			ConVar cv = FindConVar("survivor_incap_health");
			if (cv != null)
				incapMax = cv.IntValue;
			SetEntityHealth(i, health > incapMax ? incapMax : health);
			continue;
		}

		if (!g_cvBlackWhite.BoolValue && g_cvMaxIncaps != null && GetEntProp(i, Prop_Send, "m_currentReviveCount") >= g_cvMaxIncaps.IntValue)
			continue;

		int maxHealth = GetEntProp(i, Prop_Data, "m_iMaxHealth");
		int cap = g_cvMax.IntValue;
		if (cap > maxHealth)
			cap = maxHealth;

		int health = GetClientHealth(i);
		float temp = L4D_GetTempHealth(i);
		int room = cap - health - RoundToCeil(temp);
		if (room <= 0)
			continue;

		int add = g_cvAmount.IntValue;
		if (add > room)
			add = room;
		SetEntityHealth(i, health + add);
	}
	return Plugin_Continue;
}
