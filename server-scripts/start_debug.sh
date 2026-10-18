#!/bin/bash
# L4D2 服务器诊断启动脚本（Linux）
#
# 用法：放在服务器根目录（srcds_run、srcds_linux 所在目录），运行 ./start_debug.sh
# 它会：
#   1. 记录系统版本、GLIBC 版本、游戏版本、已安装的插件文件；
#   2. 检查 MetaMod / SourceMod / 扩展 / l4dtoolz / tickrate_enabler 缺少哪些系统库；
#   3. 启动服务器一次（不自动重启）。装了 gdb 时在 gdb 里启动，崩溃时记录崩溃位置；
#   4. 服务器退出后收集控制台输出、退出码和 SourceMod 日志。
# 所有内容写进同一个文件 debug_<时间>.log，把这个文件发出来即可。
# 如果服务器正常运行没有退出，按 Ctrl+C 结束，日志同样会生成。
# 日志里不包含 server.cfg 的内容（rcon 密码不会被记录）。

# ---- 按需修改（同目录有 start.sh 时，会自动读取里面的 -port / -tickrate / +map） ----
PORT=27015
MAP=c1m1_hotel
TICKRATE=100
EXTRA_ARGS=""        # 其他启动参数，用空格分隔
# ------------------

cd "$(dirname "$0")" || exit 1

if [ -f start.sh ]; then
	v=$(grep -oE -- '-port[[:space:]]+[0-9]+' start.sh | head -1 | awk '{print $2}'); [ -n "$v" ] && PORT=$v
	v=$(grep -oE -- '-tickrate[[:space:]]+[0-9]+' start.sh | head -1 | awk '{print $2}'); [ -n "$v" ] && TICKRATE=$v
	v=$(grep -oE -- '\+map[[:space:]]+[A-Za-z0-9_]+' start.sh | head -1 | awk '{print $2}'); [ -n "$v" ] && MAP=$v
fi
ROOT=$(pwd)
GAME="$ROOT/left4dead2"
STAMP=$(date +%Y%m%d_%H%M%S)
LOG="$ROOT/debug_$STAMP.log"
GDBLOG="$ROOT/.debug_gdb_$STAMP.txt"

section() { echo; echo "==================== $* ===================="; }

if [ ! -x "$ROOT/srcds_linux" ] || [ ! -d "$GAME" ]; then
	echo "找不到 srcds_linux 或 left4dead2 目录。请把本脚本放到服务器根目录（和 srcds_run 同一个目录）再运行。"
	exit 1
fi

export LD_LIBRARY_PATH="$ROOT:$ROOT/bin:$LD_LIBRARY_PATH"

# ---------------------------------------------------------------- 启动前检查
{
	section "基本信息"
	echo "时间: $(date '+%F %T %z')"
	echo "目录: $ROOT"
	echo "用户: $(id -un)"
	uname -a
	[ -f /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
	echo "GLIBC: $(ldd --version 2>&1 | head -1)"
	echo "CPU 核数: $(nproc 2>/dev/null)"
	free -m 2>/dev/null
	df -h "$ROOT" 2>/dev/null | tail -1

	section "32 位运行库"
	if command -v dpkg >/dev/null 2>&1; then
		dpkg -l lib32gcc-s1 lib32gcc1 lib32stdc++6 libc6-i386 2>/dev/null | grep -E '^(ii|rc|un)' || echo "（dpkg 里没有找到这些包）"
	else
		echo "（不是 Debian/Ubuntu 系统，跳过）"
	fi

	section "游戏版本 left4dead2/steam.inf"
	cat "$GAME/steam.inf" 2>/dev/null || echo "（没有 steam.inf）"

	section "addons 目录"
	ls -la "$GAME/addons" 2>&1
	for f in "$GAME"/addons/*.vdf "$GAME"/addons/metamod/*.vdf; do
		[ -f "$f" ] || continue
		echo "--- ${f#"$GAME"/}"
		cat "$f"
		echo
	done
	echo "--- addons/metamod/metaplugins.ini（非注释行）"
	grep -v '^[[:space:]]*;' "$GAME/addons/metamod/metaplugins.ini" 2>/dev/null | grep -v '^[[:space:]]*$'

	section "SourceMod 插件和扩展文件"
	if [ -d "$GAME/addons/sourcemod" ]; then
		(cd "$GAME/addons/sourcemod" && find plugins extensions -type f \( -name '*.smx' -o -name '*.so' -o -name '*.autoload' \) | sort)
	else
		echo "（没有 addons/sourcemod 目录）"
	fi

	section "依赖库检查（只列出有问题的）"
	# 服务器和插件都是 32 位程序，用 32 位动态链接器检查（普通 ldd 在部分系统上看不了 32 位库）
	LD32=""
	for l in /lib/ld-linux.so.2 /lib32/ld-linux.so.2 /usr/lib32/ld-linux.so.2; do
		[ -x "$l" ] && LD32=$l && break
	done
	if [ -z "$LD32" ]; then
		echo "找不到 32 位动态链接器 ld-linux.so.2，需要安装 32 位运行库: sudo apt install lib32gcc-s1 lib32stdc++6"
	else
		bad=0
		while IFS= read -r so; do
			problems=$("$LD32" --list "$so" 2>&1 | grep -E 'not found|wrong ELF|cannot')
			if [ -n "$problems" ]; then
				bad=1
				echo "--- ${so#"$ROOT"/}"
				echo "$problems"
			fi
		done < <(find "$GAME/addons" -type f -name '*.so' 2>/dev/null | sort)
		[ $bad -eq 0 ] && echo "全部正常"
	fi
} 2>&1 | tee "$LOG"

# ---------------------------------------------------------------- 启动服务器
# -condebug 让游戏把控制台输出逐行写进 left4dead2/console.log，崩溃也不会丢
ARGS=(-game left4dead2 -console -condebug -ip 0.0.0.0 -port "$PORT" -tickrate "$TICKRATE" +map "$MAP" +exec server.cfg)
# shellcheck disable=SC2206
[ -n "$EXTRA_ARGS" ] && ARGS+=($EXTRA_ARGS)

CONSOLE="$GAME/console.log"
CONSOLE_START=0
[ -f "$CONSOLE" ] && CONSOLE_START=$(stat -c %s "$CONSOLE")

# Ctrl+C 只结束服务器，脚本继续往下收集日志
trap 'echo; echo "（收到 Ctrl+C，正在收集日志）"' INT

{
	section "启动服务器"
	echo "命令: ./srcds_linux ${ARGS[*]}"
} | tee -a "$LOG"

START_TIME=$(date +%s)
USED_GDB=0
if command -v gdb >/dev/null 2>&1; then
	USED_GDB=1
	echo "使用 gdb 启动，崩溃时会记录崩溃位置。"
	gdb -q -batch \
		-ex "set pagination off" \
		-ex "handle SIGPIPE nostop noprint pass" \
		-ex "handle SIGUSR1 nostop noprint pass" \
		-ex "handle SIGUSR2 nostop noprint pass" \
		-ex "run" \
		-ex "set logging file $GDBLOG" \
		-ex "set logging overwrite on" \
		-ex "set logging enabled on" \
		-ex "set logging on" \
		-ex "info program" \
		-ex "bt 40" \
		-ex "info sharedlibrary" \
		--args ./srcds_linux "${ARGS[@]}"
	CODE=$?
else
	echo "没有安装 gdb，只能记录退出码，无法记录崩溃位置（安装: sudo apt install gdb）"
	./srcds_linux "${ARGS[@]}"
	CODE=$?
fi
END_TIME=$(date +%s)
trap - INT

# ---------------------------------------------------------------- 收集结果
{
	section "退出状态"
	echo "运行了 $((END_TIME - START_TIME)) 秒"
	if [ $USED_GDB -eq 1 ]; then
		echo "gdb 返回码: $CODE"
		if [ -s "$GDBLOG" ]; then
			cat "$GDBLOG"
		else
			echo "（gdb 没有记录到崩溃信息，服务器可能是正常退出）"
		fi
	elif [ $CODE -gt 128 ]; then
		echo "服务器被信号 $((CODE - 128)) 终止（返回码 $CODE；11 = 段错误崩溃，6 = abort，9 = 被系统杀掉，常见原因是内存不足）"
	else
		echo "服务器退出，返回码 $CODE"
	fi

	section "本次控制台输出 left4dead2/console.log"
	if [ -f "$CONSOLE" ]; then
		tail -c +$((CONSOLE_START + 1)) "$CONSOLE"
	else
		echo "（没有生成 console.log）"
	fi

	section "SourceMod 日志（本次启动后修改过的）"
	found=0
	if [ -d "$GAME/addons/sourcemod/logs" ]; then
		while IFS= read -r f; do
			found=1
			echo "--- ${f#"$GAME"/}（最后 150 行）"
			tail -n 150 "$f"
		done < <(find "$GAME/addons/sourcemod/logs" -type f -name '*.log' -newermt "@$START_TIME" 2>/dev/null | sort)
	fi
	[ $found -eq 0 ] && echo "本次启动没有生成或更新 SourceMod 日志（说明 SourceMod 可能根本没有加载）"

	section "系统日志里的崩溃记录（需要权限，可能为空）"
	dmesg 2>/dev/null | grep -iE 'srcds|segfault|out of memory|killed process' | tail -n 20
} 2>&1 | tee -a "$LOG"

rm -f "$GDBLOG"
echo
echo "诊断完成，请把这个文件发给我: $LOG"
