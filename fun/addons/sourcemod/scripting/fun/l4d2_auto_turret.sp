/**
 * L4D2 Auto Turret - 自动炮台
 *
 * 生还者输入 !turret 在面前放下一台自动机枪，它会自动转向并射击范围内可见的感染者。
 *   - 弹药耗尽或到达存在时间后自动消失；
 *   - 每人可放置数量、全图最大数量、伤害、射速、射程都可以用 cvar 调整；
 *   - !removeturret 收回自己放置的炮台；管理员可用 sm_removeallturrets 清除全部。
 * 思路参考 Panxiaohai 的 Intelligent Machine Gun / Machine Gun System，代码为本仓库重新编写。
 *
 * License: GPLv3
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "1.0.0"
#define MAX_TURRETS 32
#define MODEL_TURRET "models/w_models/weapons/50cal.mdl"
#define MODEL_TURRET_MINIGUN "models/w_models/weapons/w_minigun.mdl"
#define SOUND_SHOOT "weapons/50cal/50cal_shoot.wav"
#define SOUND_DEPLOY "items/itempickup.wav"
#define SOUND_EMPTY "weapons/clipempty_rifle.wav"
#define BEAM_SPRITE "materials/sprites/laserbeam.vmt"
#define THINK_INTERVAL 0.1

public Plugin myinfo =
{
	name = "[L4D2] Auto Turret",
	author = "L4D2-PLUGINS",
	description = "可放置的自动机枪炮台",
	version = PLUGIN_VERSION,
	url = "https://github.com/hyer-gify/L4D2-PLUGINS"
};

ConVar g_cvEnable, g_cvPerPlayer, g_cvMaxTotal, g_cvAmmo, g_cvLifetime, g_cvRange, g_cvFireRate,
	g_cvDamageCommon, g_cvDamageSI, g_cvDamageTank, g_cvDamageWitch, g_cvAttackWitch, g_cvAccess, g_cvModel, g_cvCooldown;

enum struct Turret
{
	int ref;		// 炮台实体引用
	int owner;		// 放置者 userid
	int ammo;
	float expire;
	int target;		// 当前目标实体引用
	float fireAccum;
	float nextSound;
}

Turret g_Turrets[MAX_TURRETS];
int g_iBeamSprite;
float g_fNextDeploy[MAXPLAYERS + 1];

public void OnPluginStart()
{
	CreateConVar("l4d2_turret_version", PLUGIN_VERSION, "插件版本", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnable = CreateConVar("l4d2_turret_enable", "1", "是否允许放置自动炮台", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvPerPlayer = CreateConVar("l4d2_turret_per_player", "1", "每名玩家同时最多放置几台", FCVAR_NOTIFY, true, 1.0, true, float(MAX_TURRETS));
	g_cvMaxTotal = CreateConVar("l4d2_turret_max", "6", "全图同时最多几台", FCVAR_NOTIFY, true, 1.0, true, float(MAX_TURRETS));
	g_cvAmmo = CreateConVar("l4d2_turret_ammo", "400", "每台炮台的子弹数", FCVAR_NOTIFY, true, 1.0);
	g_cvLifetime = CreateConVar("l4d2_turret_lifetime", "120", "炮台存在时间（秒，0=直到子弹打完）", FCVAR_NOTIFY, true, 0.0);
	g_cvRange = CreateConVar("l4d2_turret_range", "900", "索敌范围", FCVAR_NOTIFY, true, 100.0, true, 4000.0);
	g_cvFireRate = CreateConVar("l4d2_turret_fire_rate", "8", "每秒射击次数", FCVAR_NOTIFY, true, 1.0, true, 30.0);
	g_cvDamageCommon = CreateConVar("l4d2_turret_damage_common", "25", "每发对普通感染者的伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvDamageSI = CreateConVar("l4d2_turret_damage_si", "20", "每发对特感的伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvDamageTank = CreateConVar("l4d2_turret_damage_tank", "12", "每发对 Tank 的伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvDamageWitch = CreateConVar("l4d2_turret_damage_witch", "15", "每发对 Witch 的伤害", FCVAR_NOTIFY, true, 0.0);
	g_cvAttackWitch = CreateConVar("l4d2_turret_attack_witch", "0", "是否主动攻击 Witch（默认不打，免得惊扰）", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvAccess = CreateConVar("l4d2_turret_access", "", "放置炮台需要的管理员权限字母（留空=所有人）", FCVAR_NOTIFY);
	g_cvModel = CreateConVar("l4d2_turret_model", "0", "炮台外观：0=重机枪 1=加特林", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvCooldown = CreateConVar("l4d2_turret_cooldown", "30", "同一玩家两次放置之间的冷却（秒）", FCVAR_NOTIFY, true, 0.0);
	AutoExecConfig(true, "l4d2_auto_turret");

	RegConsoleCmd("sm_turret", Cmd_Turret, "在面前放置一台自动炮台");
	RegConsoleCmd("sm_pt", Cmd_Turret, "在面前放置一台自动炮台");
	RegConsoleCmd("sm_removeturret", Cmd_RemoveTurret, "收回自己放置的炮台");
	RegAdminCmd("sm_removeallturrets", Cmd_RemoveAll, ADMFLAG_GENERIC, "清除所有炮台");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundStart, EventHookMode_PostNoCopy);

	for (int i = 0; i < MAX_TURRETS; i++)
		g_Turrets[i].ref = INVALID_ENT_REFERENCE;
}

public void OnPluginEnd()
{
	RemoveAllTurrets();
}

public void OnMapStart()
{
	PrecacheModel(MODEL_TURRET, true);
	PrecacheModel(MODEL_TURRET_MINIGUN, true);
	PrecacheSound(SOUND_SHOOT, true);
	PrecacheSound(SOUND_DEPLOY, true);
	PrecacheSound(SOUND_EMPTY, true);
	g_iBeamSprite = PrecacheModel(BEAM_SPRITE, true);

	for (int i = 0; i < MAX_TURRETS; i++)
		g_Turrets[i].ref = INVALID_ENT_REFERENCE;
	for (int i = 1; i <= MaxClients; i++)
		g_fNextDeploy[i] = 0.0;

	CreateTimer(THINK_INTERVAL, Timer_Think, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	RemoveAllTurrets();
}

bool HasAccess(int client)
{
	char flags[32];
	g_cvAccess.GetString(flags, sizeof(flags));
	if (flags[0] == '\0')
		return true;
	return (GetUserFlagBits(client) & (ReadFlagString(flags) | ADMFLAG_ROOT)) != 0;
}

int CountTurrets(int userid)
{
	int count = 0;
	for (int i = 0; i < MAX_TURRETS; i++)
	{
		if (EntRefToEntIndex(g_Turrets[i].ref) == INVALID_ENT_REFERENCE)
			continue;
		if (userid == 0 || g_Turrets[i].owner == userid)
			count++;
	}
	return count;
}

Action Cmd_Turret(int client, int args)
{
	if (client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	if (!g_cvEnable.BoolValue)
	{
		PrintToChat(client, "\x04[炮台]\x01 服务器未开启自动炮台。");
		return Plugin_Handled;
	}
	if (!HasAccess(client))
	{
		PrintToChat(client, "\x04[炮台]\x01 你没有放置炮台的权限。");
		return Plugin_Handled;
	}
	if (GetClientTeam(client) != 2 || !IsPlayerAlive(client) || GetEntProp(client, Prop_Send, "m_isIncapacitated"))
	{
		PrintToChat(client, "\x04[炮台]\x01 只有站着的生还者才能放置炮台。");
		return Plugin_Handled;
	}

	float now = GetGameTime();
	if (now < g_fNextDeploy[client] && !CheckCommandAccess(client, "sm_removeallturrets", ADMFLAG_GENERIC))
	{
		PrintToChat(client, "\x04[炮台]\x01 冷却中，还需 %.0f 秒。", g_fNextDeploy[client] - now);
		return Plugin_Handled;
	}

	int userid = GetClientUserId(client);
	if (CountTurrets(userid) >= g_cvPerPlayer.IntValue)
	{
		PrintToChat(client, "\x04[炮台]\x01 你最多只能放置 %d 台，可用 !removeturret 收回。", g_cvPerPlayer.IntValue);
		return Plugin_Handled;
	}
	if (CountTurrets(0) >= g_cvMaxTotal.IntValue)
	{
		PrintToChat(client, "\x04[炮台]\x01 全图炮台已达上限 %d 台。", g_cvMaxTotal.IntValue);
		return Plugin_Handled;
	}

	float pos[3], ang[3];
	if (!FindDeployPosition(client, pos, ang))
	{
		PrintToChat(client, "\x04[炮台]\x01 这里放不下，换个平地试试。");
		return Plugin_Handled;
	}

	int slot = -1;
	for (int i = 0; i < MAX_TURRETS; i++)
	{
		if (EntRefToEntIndex(g_Turrets[i].ref) == INVALID_ENT_REFERENCE)
		{
			slot = i;
			break;
		}
	}
	if (slot == -1)
		return Plugin_Handled;

	int ent = CreateEntityByName("prop_dynamic_override");
	if (ent == -1)
		return Plugin_Handled;
	DispatchKeyValue(ent, "model", g_cvModel.IntValue == 1 ? MODEL_TURRET_MINIGUN : MODEL_TURRET);
	DispatchKeyValue(ent, "solid", "0");
	DispatchKeyValue(ent, "targetname", "l4d2_auto_turret");
	TeleportEntity(ent, pos, ang, NULL_VECTOR);
	DispatchSpawn(ent);
	SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
	SetEntProp(ent, Prop_Send, "m_glowColorOverride", 0x00C8FF);	// 橙黄色轮廓（BGR）
	SetEntProp(ent, Prop_Send, "m_nGlowRange", 1500);

	g_Turrets[slot].ref = EntIndexToEntRef(ent);
	g_Turrets[slot].owner = userid;
	g_Turrets[slot].ammo = g_cvAmmo.IntValue;
	g_Turrets[slot].expire = g_cvLifetime.FloatValue > 0.0 ? now + g_cvLifetime.FloatValue : 0.0;
	g_Turrets[slot].target = INVALID_ENT_REFERENCE;
	g_Turrets[slot].fireAccum = 0.0;
	g_Turrets[slot].nextSound = 0.0;

	g_fNextDeploy[client] = now + g_cvCooldown.FloatValue;
	EmitSoundToAll(SOUND_DEPLOY, ent);
	PrintToChatAll("\x04[炮台]\x01 \x05%N\x01 放置了一台自动炮台（%d 发子弹）。", client, g_Turrets[slot].ammo);
	return Plugin_Handled;
}

bool TraceFilter_NoPlayers(int entity, int contentsMask)
{
	return entity == 0 || entity > MaxClients;
}

bool FindDeployPosition(int client, float pos[3], float ang[3])
{
	float eye[3], eyeAng[3], fwd[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, eyeAng);
	eyeAng[0] = 0.0;
	GetAngleVectors(eyeAng, fwd, NULL_VECTOR, NULL_VECTOR);

	// 面前 50 单位处向下找地面
	float origin[3], probe[3], down[3];
	GetClientAbsOrigin(client, origin);
	probe = fwd;
	ScaleVector(probe, 50.0);
	AddVectors(origin, probe, probe);
	probe[2] += 40.0;

	// 先确认面前没有墙
	Handle tr = TR_TraceRayFilterEx(eye, probe, MASK_SOLID, RayType_EndPoint, TraceFilter_NoPlayers);
	bool blocked = TR_DidHit(tr);
	delete tr;
	if (blocked)
		return false;

	down = probe;
	down[2] -= 200.0;
	tr = TR_TraceRayFilterEx(probe, down, MASK_SOLID, RayType_EndPoint, TraceFilter_NoPlayers);
	bool hit = TR_DidHit(tr);
	if (hit)
		TR_GetEndPosition(pos, tr);
	delete tr;
	if (!hit || FloatAbs(pos[2] - origin[2]) > 60.0)
		return false;

	ang[0] = 0.0;
	ang[1] = eyeAng[1];
	ang[2] = 0.0;
	return true;
}

Action Cmd_RemoveTurret(int client, int args)
{
	if (client == 0)
		return Plugin_Handled;
	int userid = GetClientUserId(client);
	int removed = 0;
	for (int i = 0; i < MAX_TURRETS; i++)
	{
		if (g_Turrets[i].owner == userid && EntRefToEntIndex(g_Turrets[i].ref) != INVALID_ENT_REFERENCE)
		{
			RemoveTurret(i);
			removed++;
		}
	}
	PrintToChat(client, "\x04[炮台]\x01 已收回 %d 台炮台。", removed);
	return Plugin_Handled;
}

Action Cmd_RemoveAll(int client, int args)
{
	RemoveAllTurrets();
	ReplyToCommand(client, "[炮台] 已清除所有炮台。");
	return Plugin_Handled;
}

void RemoveTurret(int slot)
{
	int ent = EntRefToEntIndex(g_Turrets[slot].ref);
	if (ent != INVALID_ENT_REFERENCE)
	{
		float pos[3], dir[3] = {0.0, 0.0, 1.0};
		GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", pos);
		TE_SetupSparks(pos, dir, 8, 4);
		TE_SendToAll();
		RemoveEntity(ent);
	}
	g_Turrets[slot].ref = INVALID_ENT_REFERENCE;
	g_Turrets[slot].target = INVALID_ENT_REFERENCE;
}

void RemoveAllTurrets()
{
	for (int i = 0; i < MAX_TURRETS; i++)
		RemoveTurret(i);
}

// ---------------------------------------------------------------------------
// 索敌与射击
// ---------------------------------------------------------------------------

Action Timer_Think(Handle timer)
{
	float now = GetGameTime();
	for (int i = 0; i < MAX_TURRETS; i++)
	{
		int ent = EntRefToEntIndex(g_Turrets[i].ref);
		if (ent == INVALID_ENT_REFERENCE)
			continue;

		if (g_Turrets[i].expire > 0.0 && now >= g_Turrets[i].expire)
		{
			NotifyOwner(i, "你的炮台到时间了。");
			RemoveTurret(i);
			continue;
		}
		TurretThink(i, ent, now);
	}
	return Plugin_Continue;
}

void NotifyOwner(int slot, const char[] msg)
{
	int owner = GetClientOfUserId(g_Turrets[slot].owner);
	if (owner > 0 && IsClientInGame(owner) && !IsFakeClient(owner))
		PrintToChat(owner, "\x04[炮台]\x01 %s", msg);
}

void GetMuzzle(int ent, float muzzle[3])
{
	GetEntPropVector(ent, Prop_Data, "m_vecAbsOrigin", muzzle);
	muzzle[2] += 50.0;
}

bool GetTargetPoint(int target, float point[3])
{
	if (target <= MaxClients)
	{
		GetClientEyePosition(target, point);
		point[2] -= 15.0;
		return true;
	}
	GetEntPropVector(target, Prop_Data, "m_vecAbsOrigin", point);
	point[2] += 45.0;
	return true;
}

bool IsValidTarget(int target)
{
	if (target <= 0 || !IsValidEntity(target))
		return false;

	if (target <= MaxClients)
	{
		if (!IsClientInGame(target) || GetClientTeam(target) != 3 || !IsPlayerAlive(target))
			return false;
		if (GetEntProp(target, Prop_Send, "m_isGhost"))
			return false;
		return true;
	}

	char cls[16];
	GetEntityClassname(target, cls, sizeof(cls));
	if (StrEqual(cls, "infected"))
		return GetEntProp(target, Prop_Data, "m_iHealth") > 0;
	if (StrEqual(cls, "witch"))
		return g_cvAttackWitch.BoolValue && GetEntProp(target, Prop_Data, "m_iHealth") > 0;
	return false;
}

int g_iTraceIgnore;
bool TraceFilter_Turret(int entity, int contentsMask)
{
	if (entity == g_iTraceIgnore)
		return false;
	if (entity >= 1 && entity <= MaxClients)
		return GetClientTeam(entity) != 2;	// 子弹穿过生还者
	return true;
}

bool CanSee(int ent, const float muzzle[3], int target)
{
	float point[3];
	GetTargetPoint(target, point);
	g_iTraceIgnore = ent;
	Handle tr = TR_TraceRayFilterEx(muzzle, point, MASK_SHOT, RayType_EndPoint, TraceFilter_Turret);
	bool visible = !TR_DidHit(tr) || TR_GetEntityIndex(tr) == target;
	delete tr;
	return visible;
}

int FindTurretTarget(int ent, const float muzzle[3])
{
	float range = g_cvRange.FloatValue;
	float best = range * range;
	int bestTarget = -1;
	float point[3];

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidTarget(i))
			continue;
		GetTargetPoint(i, point);
		float d = GetVectorDistance(muzzle, point, true);
		if (d > range * range)
			continue;
		// 特感优先：距离按七折比较（平方后为 0.49）
		d *= 0.49;
		if (d < best && CanSee(ent, muzzle, i))
		{
			best = d;
			bestTarget = i;
		}
	}

	int other = -1;
	while ((other = FindEntityByClassname(other, "infected")) != -1)
		CheckEntityTarget(ent, muzzle, other, best, bestTarget);
	if (g_cvAttackWitch.BoolValue)
	{
		other = -1;
		while ((other = FindEntityByClassname(other, "witch")) != -1)
			CheckEntityTarget(ent, muzzle, other, best, bestTarget);
	}
	return bestTarget;
}

void CheckEntityTarget(int ent, const float muzzle[3], int other, float &best, int &bestTarget)
{
	if (!IsValidTarget(other))
		return;
	float point[3];
	GetTargetPoint(other, point);
	float d = GetVectorDistance(muzzle, point, true);
	if (d < best && CanSee(ent, muzzle, other))
	{
		best = d;
		bestTarget = other;
	}
}

void TurretThink(int slot, int ent, float now)
{
	float muzzle[3];
	GetMuzzle(ent, muzzle);

	int target = EntRefToEntIndex(g_Turrets[slot].target);
	float range = g_cvRange.FloatValue;
	if (target != INVALID_ENT_REFERENCE)
	{
		float point[3];
		GetTargetPoint(target, point);
		if (!IsValidTarget(target) || GetVectorDistance(muzzle, point) > range || !CanSee(ent, muzzle, target))
			target = INVALID_ENT_REFERENCE;
	}
	if (target == INVALID_ENT_REFERENCE)
	{
		target = FindTurretTarget(ent, muzzle);
		g_Turrets[slot].target = target > 0 ? EntIndexToEntRef(target) : INVALID_ENT_REFERENCE;
		g_Turrets[slot].fireAccum = 0.0;
		if (target <= 0)
			return;
	}

	// 转向目标（只转水平方向，模型本身朝向 +X）
	float point[3], dir[3], ang[3];
	GetTargetPoint(target, point);
	SubtractVectors(point, muzzle, dir);
	GetVectorAngles(dir, ang);
	float bodyAng[3];
	bodyAng[1] = ang[1];
	TeleportEntity(ent, NULL_VECTOR, bodyAng, NULL_VECTOR);

	g_Turrets[slot].fireAccum += g_cvFireRate.FloatValue * THINK_INTERVAL;
	while (g_Turrets[slot].fireAccum >= 1.0)
	{
		g_Turrets[slot].fireAccum -= 1.0;
		if (g_Turrets[slot].ammo <= 0)
			break;
		FireShot(slot, ent, muzzle, target, now);
		if (!IsValidTarget(target))
			break;
	}

	if (g_Turrets[slot].ammo <= 0)
	{
		EmitSoundToAll(SOUND_EMPTY, ent);
		NotifyOwner(slot, "你的炮台子弹打光了。");
		RemoveTurret(slot);
	}
}

void FireShot(int slot, int ent, const float muzzle[3], int target, float now)
{
	g_Turrets[slot].ammo--;

	float point[3], dir[3];
	GetTargetPoint(target, point);
	// 加一点散布
	point[0] += GetRandomFloat(-6.0, 6.0);
	point[1] += GetRandomFloat(-6.0, 6.0);
	point[2] += GetRandomFloat(-6.0, 6.0);
	SubtractVectors(point, muzzle, dir);
	NormalizeVector(dir, dir);

	float damage;
	if (target <= MaxClients)
		damage = GetEntProp(target, Prop_Send, "m_zombieClass") == 8 ? g_cvDamageTank.FloatValue : g_cvDamageSI.FloatValue;
	else
	{
		char cls[16];
		GetEntityClassname(target, cls, sizeof(cls));
		damage = StrEqual(cls, "witch") ? g_cvDamageWitch.FloatValue : g_cvDamageCommon.FloatValue;
	}

	int owner = GetClientOfUserId(g_Turrets[slot].owner);
	int attacker = (owner > 0 && IsClientInGame(owner)) ? owner : ent;
	SDKHooks_TakeDamage(target, ent, attacker, damage, DMG_BULLET, -1, dir, point);

	int color[4] = {255, 200, 80, 180};
	TE_SetupBeamPoints(muzzle, point, g_iBeamSprite, 0, 0, 0, 0.08, 1.2, 0.6, 1, 0.0, color, 0);
	TE_SendToAll();

	if (now >= g_Turrets[slot].nextSound)
	{
		g_Turrets[slot].nextSound = now + 0.12;
		EmitSoundToAll(SOUND_SHOOT, ent, SNDCHAN_WEAPON, SNDLEVEL_GUNFIRE, SND_NOFLAGS, 0.5);
	}
}
