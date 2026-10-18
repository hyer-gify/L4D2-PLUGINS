/**
 * L4D2 Magnum Railgun - 马格南电磁炮
 *
 * 马格南手枪开火时额外射出一道电磁光束：
 *   - 光束沿准星方向直线飞行，被墙体挡住为止，穿透路径上所有感染者（普通、特感、Witch、Tank）；
 *   - 每个被击中的目标受到额外伤害，特感会被击退硬直；
 *   - 可选蓄能：按住【装弹】键蓄能再开火，伤害按蓄能时间放大。
 * 玩家可用 !railgun 开关自己的电磁炮。
 *
 * 依赖: left4dhooks（击退硬直）
 * License: GPLv3
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define PLUGIN_VERSION "1.0.0"
#define BEAM_SPRITE "materials/sprites/laserbeam.vmt"
#define HALO_SPRITE "materials/sprites/glow01.vmt"
#define SOUND_FIRE "weapons/defibrillator/defibrillator_use.wav"
#define SOUND_CHARGED "ui/beep07.wav"
#define MAX_HITS 64

public Plugin myinfo =
{
	name = "[L4D2] Magnum Railgun",
	author = "L4D2-PLUGINS",
	description = "马格南手枪变成穿透电磁炮",
	version = PLUGIN_VERSION,
	url = "https://github.com/hyer-gify/L4D2-PLUGINS"
};

ConVar g_cvEnable, g_cvDefaultOn, g_cvDamageSI, g_cvDamageCommon, g_cvDamageWitch, g_cvDamageTank,
	g_cvRange, g_cvMaxHits, g_cvCooldown, g_cvStagger, g_cvFriendly, g_cvChargeTime, g_cvChargeMult,
	g_cvColor, g_cvWidth, g_cvAdminFlag;

int g_iBeamSprite, g_iHaloSprite;
bool g_bEnabled[MAXPLAYERS + 1];
float g_fNextShot[MAXPLAYERS + 1];
float g_fChargeStart[MAXPLAYERS + 1];
bool g_bChargedNotified[MAXPLAYERS + 1];

int g_iHits[MAX_HITS];
int g_iHitCount;
int g_iShooter;

public void OnPluginStart()
{
	CreateConVar("l4d2_railgun_version", PLUGIN_VERSION, "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_railgun_enable", "1", "是否启用马格南电磁炮", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDefaultOn = CreateConVar("l4d2_railgun_default_on", "1", "玩家进服时电磁炮默认开启", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvDamageSI = CreateConVar("l4d2_railgun_damage_si", "250", "对特感的额外伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvDamageCommon = CreateConVar("l4d2_railgun_damage_common", "100", "对普通感染者的额外伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvDamageWitch = CreateConVar("l4d2_railgun_damage_witch", "150", "对 Witch 的额外伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvDamageTank = CreateConVar("l4d2_railgun_damage_tank", "120", "对 Tank 的额外伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvRange = CreateConVar("l4d2_railgun_range", "3000", "光束最大距离", FCVAR_NOTIFY, true, 100.0, true, 10000.0);
	g_cvMaxHits = CreateConVar("l4d2_railgun_max_hits", "0", "一发最多穿透多少个目标（0=不限）", FCVAR_NOTIFY, true, 0.0, true, float(MAX_HITS));
	g_cvCooldown = CreateConVar("l4d2_railgun_cooldown", "0.0", "两发电磁炮之间的冷却（秒），冷却中开火只是普通子弹", FCVAR_NOTIFY, true, 0.0, true, 60.0);
	g_cvStagger = CreateConVar("l4d2_railgun_stagger", "1", "被击中的特感是否被击退硬直（Tank 除外）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvFriendly = CreateConVar("l4d2_railgun_friendly_fire", "0", "光束是否伤害队友（伤害为特感伤害的 10%）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvChargeTime = CreateConVar("l4d2_railgun_charge_time", "1.5", "按住装弹键蓄满能所需秒数（0=关闭蓄能）", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	g_cvChargeMult = CreateConVar("l4d2_railgun_charge_mult", "3.0", "蓄满能时的伤害倍率", FCVAR_NOTIFY, true, 1.0, true, 20.0);
	g_cvColor = CreateConVar("l4d2_railgun_color", "0 180 255", "光束颜色 R G B", FCVAR_NOTIFY);
	g_cvWidth = CreateConVar("l4d2_railgun_width", "3.0", "光束宽度", FCVAR_NOTIFY, true, 0.5, true, 30.0);
	g_cvAdminFlag = CreateConVar("l4d2_railgun_access", "", "使用电磁炮需要的管理员权限字母（留空=所有人）", FCVAR_NOTIFY);
	AutoExecConfig(true, "l4d2_magnum_railgun");

	RegConsoleCmd("sm_railgun", Cmd_Railgun, "开关自己的马格南电磁炮");
	RegConsoleCmd("sm_dcp", Cmd_Railgun, "开关自己的马格南电磁炮");

	HookEvent("weapon_fire", Event_WeaponFire);

	for (int i = 1; i <= MaxClients; i++)
		g_bEnabled[i] = true;
}

public void OnMapStart()
{
	g_iBeamSprite = PrecacheModel(BEAM_SPRITE, true);
	g_iHaloSprite = PrecacheModel(HALO_SPRITE, true);
	PrecacheSound(SOUND_FIRE, true);
	PrecacheSound(SOUND_CHARGED, true);
}

public void OnClientPutInServer(int client)
{
	g_bEnabled[client] = g_cvDefaultOn.BoolValue;
	g_fNextShot[client] = 0.0;
	g_fChargeStart[client] = 0.0;
	g_bChargedNotified[client] = false;
}

bool HasAccess(int client)
{
	char flags[32];
	g_cvAdminFlag.GetString(flags, sizeof(flags));
	if (flags[0] == '\0' || IsFakeClient(client))
		return true;
	int need = ReadFlagString(flags);
	return (GetUserFlagBits(client) & (need | ADMFLAG_ROOT)) != 0;
}

Action Cmd_Railgun(int client, int args)
{
	if (client == 0)
		return Plugin_Handled;
	if (!HasAccess(client))
	{
		PrintToChat(client, "\x04[电磁炮]\x01 你没有使用权限。");
		return Plugin_Handled;
	}
	g_bEnabled[client] = !g_bEnabled[client];
	PrintToChat(client, "\x04[电磁炮]\x01 马格南电磁炮已%s", g_bEnabled[client] ? "\x05开启" : "\x03关闭");
	if (g_bEnabled[client] && g_cvChargeTime.FloatValue > 0.0)
		PrintToChat(client, "\x04[电磁炮]\x01 按住【装弹】键蓄能，再开火造成 %.1f 倍伤害。", g_cvChargeMult.FloatValue);
	return Plugin_Handled;
}

bool IsHoldingMagnum(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon <= MaxClients || !IsValidEntity(weapon))
		return false;
	char cls[32];
	GetEntityClassname(weapon, cls, sizeof(cls));
	return StrEqual(cls, "weapon_pistol_magnum");
}

// 蓄能：按住装弹键
public void OnPlayerRunCmdPost(int client, int buttons)
{
	if (g_cvChargeTime.FloatValue <= 0.0 || !g_bEnabled[client] || !IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
		return;

	if ((buttons & IN_RELOAD) && IsHoldingMagnum(client))
	{
		if (g_fChargeStart[client] == 0.0)
		{
			g_fChargeStart[client] = GetGameTime();
			g_bChargedNotified[client] = false;
		}
		else if (!g_bChargedNotified[client] && GetGameTime() - g_fChargeStart[client] >= g_cvChargeTime.FloatValue)
		{
			g_bChargedNotified[client] = true;
			if (!IsFakeClient(client))
			{
				EmitSoundToClient(client, SOUND_CHARGED);
				PrintHintText(client, "电磁炮蓄能完成！");
			}
		}
	}
	else if (!(buttons & IN_ATTACK))
	{
		// 松开装弹键后保留蓄能，直到开火或切枪
		if (!IsHoldingMagnum(client))
			g_fChargeStart[client] = 0.0;
	}
}

void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnable.BoolValue)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != 2 || !g_bEnabled[client])
		return;

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));
	if (!StrEqual(weapon, "pistol_magnum"))
		return;
	if (!HasAccess(client))
		return;

	float now = GetGameTime();
	if (now < g_fNextShot[client])
		return;
	g_fNextShot[client] = now + g_cvCooldown.FloatValue;

	float mult = 1.0;
	float chargeTime = g_cvChargeTime.FloatValue;
	if (chargeTime > 0.0 && g_fChargeStart[client] > 0.0)
	{
		float ratio = (now - g_fChargeStart[client]) / chargeTime;
		if (ratio > 1.0)
			ratio = 1.0;
		mult = 1.0 + (g_cvChargeMult.FloatValue - 1.0) * ratio;
	}
	g_fChargeStart[client] = 0.0;
	g_bChargedNotified[client] = false;

	FireRailgun(client, mult);
}

bool TraceFilter_World(int entity, int contentsMask)
{
	return entity == 0 || entity > MaxClients && !IsInfectedEntity(entity) && !IsSurvivorProp(entity);
}

bool IsSurvivorProp(int entity)
{
	// 光束不被武器、道具这类小物体挡住，只被世界和大型物体挡住
	char cls[32];
	GetEntityClassname(entity, cls, sizeof(cls));
	return strncmp(cls, "weapon_", 7) == 0 || StrEqual(cls, "survivor_death_model");
}

bool IsInfectedEntity(int entity)
{
	if (entity <= 0 || !IsValidEntity(entity))
		return false;
	if (entity <= MaxClients)
		return IsClientInGame(entity) && GetClientTeam(entity) == 3;
	char cls[16];
	GetEntityClassname(entity, cls, sizeof(cls));
	return StrEqual(cls, "infected") || StrEqual(cls, "witch");
}

void FireRailgun(int client, float mult)
{
	float start[3], ang[3], dir[3], end[3];
	GetClientEyePosition(client, start);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);

	end = dir;
	ScaleVector(end, g_cvRange.FloatValue);
	AddVectors(start, end, end);

	// 光束终点：第一次撞到世界或大型物体的位置
	Handle tr = TR_TraceRayFilterEx(start, end, MASK_SHOT, RayType_EndPoint, TraceFilter_World);
	if (TR_DidHit(tr))
		TR_GetEndPosition(end, tr);
	delete tr;

	// 收集光束路径上的所有实体
	g_iHitCount = 0;
	g_iShooter = client;
	TR_EnumerateEntities(start, end, PARTITION_SOLID_EDICTS | PARTITION_NON_STATIC_EDICTS, RayType_EndPoint, Enumerate_Hit);

	int maxHits = g_cvMaxHits.IntValue;
	int done = 0;
	for (int i = 0; i < g_iHitCount; i++)
	{
		if (maxHits > 0 && done >= maxHits)
			break;
		if (DamageTarget(client, g_iHits[i], dir, mult))
			done++;
	}

	DrawBeam(client, start, end, mult);
}

bool Enumerate_Hit(int entity)
{
	if (g_iHitCount >= MAX_HITS)
		return false;
	if (entity == g_iShooter || entity <= 0)
		return true;

	bool candidate = IsInfectedEntity(entity);
	if (!candidate && g_cvFriendly.BoolValue && entity <= MaxClients && IsClientInGame(entity) && GetClientTeam(entity) == 2 && IsPlayerAlive(entity))
		candidate = true;
	if (!candidate)
		return true;

	// 包围盒相交不代表真的打中，用实体自身的碰撞再判一次
	TR_ClipCurrentRayToEntity(MASK_SHOT, entity);
	if (TR_DidHit())
		g_iHits[g_iHitCount++] = entity;
	return true;
}

bool DamageTarget(int client, int target, const float dir[3], float mult)
{
	if (!IsValidEntity(target))
		return false;

	float damage;
	bool stagger = false;
	if (target <= MaxClients)
	{
		if (!IsClientInGame(target) || !IsPlayerAlive(target))
			return false;
		int team = GetClientTeam(target);
		if (team == 2)
			damage = g_cvDamageSI.FloatValue * 0.1;
		else if (GetEntProp(target, Prop_Send, "m_isGhost"))
			return false;
		else if (GetEntProp(target, Prop_Send, "m_zombieClass") == 8)
			damage = g_cvDamageTank.FloatValue;
		else
		{
			damage = g_cvDamageSI.FloatValue;
			stagger = g_cvStagger.BoolValue;
		}
	}
	else
	{
		char cls[16];
		GetEntityClassname(target, cls, sizeof(cls));
		damage = StrEqual(cls, "witch") ? g_cvDamageWitch.FloatValue : g_cvDamageCommon.FloatValue;
	}

	damage *= mult;
	if (damage <= 0.0)
		return false;

	float pos[3];
	GetEntPropVector(target, Prop_Data, "m_vecAbsOrigin", pos);
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	SDKHooks_TakeDamage(target, client, client, damage, DMG_BULLET, weapon > MaxClients ? weapon : -1, dir, pos);

	if (stagger && IsClientInGame(target) && IsPlayerAlive(target))
	{
		float src[3];
		GetClientAbsOrigin(client, src);
		L4D_StaggerPlayer(target, client, src);
	}

	TE_SetupSparks(pos, dir, 4, 2);
	TE_SendToAll();
	return true;
}

void DrawBeam(int client, const float start[3], const float end[3], float mult)
{
	char buffer[32], parts[3][8];
	g_cvColor.GetString(buffer, sizeof(buffer));
	int color[4] = {0, 180, 255, 230};
	if (ExplodeString(buffer, " ", parts, sizeof(parts), sizeof(parts[])) == 3)
	{
		color[0] = StringToInt(parts[0]);
		color[1] = StringToInt(parts[1]);
		color[2] = StringToInt(parts[2]);
	}

	// 从枪口略下方出发，避免第一人称挡住视线
	float from[3];
	from = start;
	from[2] -= 6.0;

	float width = g_cvWidth.FloatValue * (mult > 1.0 ? 1.0 + (mult - 1.0) * 0.5 : 1.0);
	TE_SetupBeamPoints(from, end, g_iBeamSprite, g_iHaloSprite, 0, 0, 0.35, width, width * 0.3, 1, 0.8, color, 0);
	TE_SendToAll();

	int core[4] = {255, 255, 255, 200};
	TE_SetupBeamPoints(from, end, g_iBeamSprite, g_iHaloSprite, 0, 0, 0.2, width * 0.35, width * 0.1, 1, 0.0, core, 0);
	TE_SendToAll();

	float normal[3] = {0.0, 0.0, 1.0};
	TE_SetupSparks(end, normal, 8, 3);
	TE_SendToAll();

	EmitSoundToAll(SOUND_FIRE, client, SNDCHAN_AUTO, SNDLEVEL_NORMAL, SND_NOFLAGS, 0.6);
}
