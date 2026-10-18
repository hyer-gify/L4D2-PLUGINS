/**
 * L4D2 Hostname - 中文服务器名
 *
 * 引擎执行 cfg 文件时，会把中文等非 ASCII 字符当成命令结束，所以 server.cfg 里写不了中文服务器名。
 * 本插件在每张地图的配置执行完以后，从 configs/hostname.txt 读取服务器名并设置 hostname。
 *   - 文件用 UTF-8 编码，第一行不是空行、也不以 // 开头的内容就是服务器名；
 *   - 文件不存在或没有内容时什么都不做，沿用 server.cfg 里的 hostname；
 *   - 管理员命令 sm_hostname_reload 立即重新读取。
 *
 * License: GPLv3
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "1.0.0"

public Plugin myinfo =
{
	name = "[L4D2] Hostname",
	author = "L4D2-PLUGINS",
	description = "从 configs/hostname.txt 读取服务器名，支持中文",
	version = PLUGIN_VERSION,
	url = "https://github.com/hyer-gify/L4D2-PLUGINS"
};

ConVar g_cvHostname;
char g_sPath[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
	g_cvHostname = FindConVar("hostname");
	BuildPath(Path_SM, g_sPath, sizeof(g_sPath), "configs/hostname.txt");
	RegAdminCmd("sm_hostname_reload", Cmd_Reload, ADMFLAG_CONFIG, "重新读取 configs/hostname.txt");
}

public void OnConfigsExecuted()
{
	char name[256];
	ApplyHostname(name, sizeof(name));
}

Action Cmd_Reload(int client, int args)
{
	char name[256];
	if (ApplyHostname(name, sizeof(name)))
		ReplyToCommand(client, "[SM] hostname: %s", name);
	else
		ReplyToCommand(client, "[SM] %s 不存在或没有内容，hostname 没有改动", g_sPath);
	return Plugin_Handled;
}

bool ApplyHostname(char[] name, int maxlen)
{
	File file = OpenFile(g_sPath, "r");
	if (file == null)
		return false;

	char line[256];
	int start;
	bool found;
	while (file.ReadLine(line, sizeof(line)))
	{
		// 跳过 Windows 记事本保存时加在开头的 UTF-8 BOM
		start = ((line[0] & 0xFF) == 0xEF && (line[1] & 0xFF) == 0xBB && (line[2] & 0xFF) == 0xBF) ? 3 : 0;
		TrimString(line[start]);
		if (line[start] == '\0' || (line[start] == '/' && line[start + 1] == '/'))
			continue;
		found = true;
		break;
	}
	delete file;

	if (!found)
		return false;
	g_cvHostname.SetString(line[start]);
	strcopy(name, maxlen, line[start]);
	return true;
}
