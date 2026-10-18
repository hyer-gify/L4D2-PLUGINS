#!/bin/bash
# L4D2 服务器诊断启动脚本（Linux）
#
# 用法：放在服务器根目录（srcds_run、srcds_linux 所在目录），运行 ./start_debug.sh
# 它会：
#   1. 记录系统版本、GLIBC、32 位运行库、游戏版本、已安装的插件文件、正在运行的服务器和端口占用；
#   2. 检查 MetaMod / SourceMod / 扩展 / l4dtoolz / tickrate_enabler 缺少哪些系统库；
#   3. 启动服务器两次，每次运行 WAIT 秒后自动停止：
#        第一次临时关闭所有插件（addons/*.vdf 临时改名，测完自动改回），
#        第二次正常加载插件。
#      装了 gdb 时在 gdb 里启动，停止或崩溃时记录每个线程停在哪里；
#   4. 收集每次的屏幕输出、控制台输出、退出原因、端口监听和 SourceMod 日志。
# 所有内容写进同一个文件 debug_<时间>.log，把这个文件发出来即可。
# 只测一种情况：./start_debug.sh vanilla（不加载插件）或 ./start_debug.sh plugins（加载插件）
# 日志里不包含 server.cfg 的内容，启动参数里的密码会被隐藏。

# ---- 按需修改（同目录有 start.sh 时，会自动读取里面的 -port / -tickrate / +map） ----
PORT=27015
MAP=c1m1_hotel
TICKRATE=100
EXTRA_ARGS=""        # 其他启动参数，用空格分隔
WAIT=60              # 每次启动后运行多少秒自动停止；0 = 不自动停止，自己按 Ctrl+C
# ------------------

cd "$(dirname "$0")" || exit 1
ROOT=$(pwd -P)
GAME="$ROOT/left4dead2"
STAMP=$(date +%Y%m%d_%H%M%S)
LOG="$ROOT/debug_$STAMP.log"

case "${1:-both}" in
	both) TESTS=(vanilla plugins) ;;
	vanilla) TESTS=(vanilla) ;;
	plugins) TESTS=(plugins) ;;
	*) echo "用法: $0 [both|vanilla|plugins]"; exit 1 ;;
esac

if [ -f start.sh ]; then
	v=$(grep -oE -- '-port[[:space:]]+[0-9]+' start.sh | head -1 | awk '{print $2}'); [ -n "$v" ] && PORT=$v
	v=$(grep -oE -- '-tickrate[[:space:]]+[0-9]+' start.sh | head -1 | awk '{print $2}'); [ -n "$v" ] && TICKRATE=$v
	v=$(grep -oE -- '\+map[[:space:]]+[A-Za-z0-9_]+' start.sh | head -1 | awk '{print $2}'); [ -n "$v" ] && MAP=$v
fi

section() { echo; echo "==================== $* ===================="; }
redact() { sed -E 's/((rcon_password|sv_password|sv_setsteamaccount)[[:space:]]+)[^[:space:]]+/\1***/g'; }
clean() { sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\r$//' | redact; }
# 列出监听中的端口；$1 = 过滤用的正则，$2 = 用 udp 还是 tcp
listening() {
	if command -v ss >/dev/null 2>&1; then
		ss -"${2:0:1}"lnp 2>/dev/null | grep -E "$1"
	elif command -v netstat >/dev/null 2>&1; then
		netstat -"${2:0:1}"lnp 2>/dev/null | grep -E "$1"
	fi
}

if [ ! -x "$ROOT/srcds_linux" ] || [ ! -d "$GAME" ]; then
	echo "找不到 srcds_linux 或 left4dead2 目录。请把本脚本放到服务器根目录（和 srcds_run 同一个目录）再运行。"
	exit 1
fi

# 上次诊断被强行中断时留下的临时改名，先改回来
for f in "$GAME"/addons/*.vdf.debug_off; do
	[ -f "$f" ] && mv -n "$f" "${f%.debug_off}"
done

TMPD=$(mktemp -d "$ROOT/.debug_tmp_XXXXXX")
DISABLED=()
restore_addons() {
	local f
	for f in "${DISABLED[@]}"; do
		[ -f "$f.debug_off" ] && mv -n "$f.debug_off" "$f"
	done
	DISABLED=()
}
trap 'restore_addons; rm -rf "$TMPD"' EXIT
trap 'exit 1' HUP TERM

if ! command -v gdb >/dev/null 2>&1 && [ -t 0 ]; then
	echo "没有安装 gdb。装了 gdb 才能看到服务器卡在哪一步、崩在哪里。"
	read -r -p "现在用 sudo apt install gdb 安装吗？[Y/n] " ans
	case "$ans" in
		[nN]*) ;;
		*) sudo apt-get install -y gdb ;;
	esac
fi
HAVE_GDB=0
GDB_LOGGING="set logging on"
if command -v gdb >/dev/null 2>&1; then
	HAVE_GDB=1
	# gdb 12 起改名为 set logging enabled
	[ "$(gdb --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)" -ge 12 ] 2>/dev/null && GDB_LOGGING="set logging enabled on"
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
	echo "gdb: $([ $HAVE_GDB -eq 1 ] && gdb --version | head -1 || echo 没有安装)"
	echo "诊断项目: ${TESTS[*]}，每次运行 ${WAIT} 秒"

	section "32 位运行库"
	if command -v dpkg >/dev/null 2>&1; then
		dpkg -l lib32gcc-s1 lib32gcc1 lib32stdc++6 libc6-i386 2>/dev/null | grep -E '^(ii|rc|un)' || echo "（dpkg 里没有找到这些包）"
	else
		echo "（不是 Debian/Ubuntu 系统，跳过）"
	fi

	section "Steam 运行库 steamclient.so"
	for f in "$HOME/.steam/sdk32/steamclient.so" "$ROOT/bin/steamclient.so" "$ROOT/steamclient.so"; do
		if [ -e "$f" ]; then ls -laL "$f"; else echo "没有 $f"; fi
	done

	section "域名解析"
	echo "本机名 $(hostname): $(getent hosts "$(hostname)" | head -1)"
	t0=$(date +%s)
	r=$(timeout 10 getent hosts steamcommunity.com | head -1)
	echo "steamcommunity.com: ${r:-解析失败} （用了 $(( $(date +%s) - t0 )) 秒）"

	section "游戏版本 left4dead2/steam.inf"
	cat "$GAME/steam.inf" 2>/dev/null || echo "（没有 steam.inf）"

	section "正在运行的 L4D2 服务器"
	found=0
	for p in $(pgrep -x srcds_linux 2>/dev/null); do
		found=1
		echo "PID $p  目录 $(readlink "/proc/$p/cwd" 2>/dev/null)"
		echo "    参数: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | redact)"
	done
	[ $found -eq 0 ] && echo "（没有）"

	section "端口占用（27000-27099）"
	listening ':270[0-9][0-9][[:space:]]' udp || echo "（UDP 没有）"
	listening ':270[0-9][0-9][[:space:]]' tcp || echo "（TCP 没有）"

	section "本机防火墙"
	if command -v ufw >/dev/null 2>&1; then
		sudo -n ufw status 2>&1 | head -20
	else
		echo "（没有 ufw）"
	fi
	sudo -n iptables -S INPUT 2>&1 | head -20

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

# 找本次启动的 srcds_linux（目录是本目录，且不是启动前就在运行的）
find_new_srcds() {
	local p
	for p in $(pgrep -x srcds_linux 2>/dev/null); do
		case " $BEFORE " in *" $p "*) continue ;; esac
		[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$ROOT" ] && { echo "$p"; return; }
	done
}

# 运行满 WAIT 秒后记录端口并停止服务器（gdb 会在这时记录每个线程停在哪里）
watcher() {
	local name=$1 p="" i
	for i in $(seq 1 30); do
		p=$(find_new_srcds)
		[ -n "$p" ] && break
		sleep 1
	done
	[ -n "$p" ] || return
	sleep "$WAIT"
	kill -0 "$p" 2>/dev/null || return
	{
		listening "pid=$p,|:$PORT[[:space:]]" udp
		grep -qi ":$(printf '%04X' "$PORT") " /proc/net/udp 2>/dev/null && echo "UDP 端口 $PORT 正在监听（/proc/net/udp）"
	} > "$TMPD/ports_$name.txt"
	echo "运行满 $WAIT 秒，脚本自动停止了服务器" > "$TMPD/autostop_$name.txt"
	kill -INT "$p" 2>/dev/null
	sleep 20
	kill -0 "$p" 2>/dev/null && kill -KILL "$p" 2>/dev/null
}

run_test() {
	local name=$1 title termlog="$TMPD/term_$1.txt" gdblog="$TMPD/gdb_$1.txt"
	local cstart=0 t0 t1 code wpid cmd
	if [ "$name" = vanilla ]; then
		title="不加载插件"
		local f
		for f in "$GAME"/addons/*.vdf; do
			[ -f "$f" ] || continue
			mv "$f" "$f.debug_off" && DISABLED+=("$f")
		done
	else
		title="加载插件"
	fi
	[ -f "$CONSOLE" ] && cstart=$(stat -c %s "$CONSOLE")

	{
		section "启动服务器：$title"
		[ "$name" = vanilla ] && echo "临时关闭: ${DISABLED[*]##*/}"
		echo "命令: ./srcds_linux ${ARGS[*]}"
		if [ "$WAIT" -gt 0 ]; then
			echo "运行 $WAIT 秒后自动停止，中途想停就按 Ctrl+C。"
		else
			echo "不会自动停止，看完按 Ctrl+C。"
		fi
	} | tee -a "$LOG"

	if [ $HAVE_GDB -eq 1 ]; then
		cmd=(gdb -q -batch
			-ex "set pagination off" -ex "set confirm off"
			-ex "handle SIGPIPE nostop noprint pass"
			-ex "handle SIGUSR1 nostop noprint pass"
			-ex "handle SIGUSR2 nostop noprint pass"
			-ex "run"
			-ex "set logging file $gdblog" -ex "set logging overwrite on" -ex "set logging redirect on"
			-ex "$GDB_LOGGING"
			-ex "info program" -ex "bt 40" -ex "info threads" -ex "thread apply all bt 25"
			-ex "info sharedlibrary"
			--args ./srcds_linux "${ARGS[@]}")
	else
		cmd=(./srcds_linux "${ARGS[@]}")
	fi

	BEFORE=$(pgrep -x srcds_linux 2>/dev/null | tr '\n' ' ')
	wpid=""
	if [ "$WAIT" -gt 0 ]; then
		watcher "$name" &
		wpid=$!
	fi
	t0=$(date +%s)
	trap 'echo; echo "（收到 Ctrl+C）"' INT
	if command -v script >/dev/null 2>&1 && [ -t 0 ] && [ -t 1 ]; then
		# script 用一个伪终端运行服务器，屏幕上的输出原样记下来
		SHELL=/bin/bash script -q -e -c "$(printf '%q ' "${cmd[@]}")" "$termlog"
		code=$?
	else
		"${cmd[@]}" 2>&1 | tee -i "$termlog"
		code=${PIPESTATUS[0]}
	fi
	trap - INT
	t1=$(date +%s)
	[ -n "$wpid" ] && kill "$wpid" 2>/dev/null
	wait 2>/dev/null
	restore_addons

	{
		section "结果：$title"
		echo "运行了 $((t1 - t0)) 秒"
		cat "$TMPD/autostop_$name.txt" 2>/dev/null
		if [ $HAVE_GDB -eq 1 ]; then
			echo "gdb 返回码: $code"
		elif [ "$code" -gt 128 ]; then
			echo "服务器被信号 $((code - 128)) 终止（返回码 $code；2 = Ctrl+C 或脚本自动停止，11 = 段错误崩溃，6 = abort，9 = 被强制结束或内存不足）"
		else
			echo "服务器退出，返回码 $code"
		fi

		section "屏幕输出：$title（最后 250 行）"
		if [ -s "$termlog" ]; then grep -avE '^Script (started|done) on' "$termlog" | clean | tail -n 250; else echo "（没有记录）"; fi

		section "控制台 console.log：$title（最后 250 行）"
		if [ -f "$CONSOLE" ]; then tail -c +$((cstart + 1)) "$CONSOLE" | clean | tail -n 250; else echo "（没有生成 console.log）"; fi

		if [ $HAVE_GDB -eq 1 ]; then
			section "gdb：服务器停在哪里（$title）"
			if [ -s "$gdblog" ]; then cat "$gdblog"; else echo "（gdb 没有记录，服务器可能自己正常退出了）"; fi
		fi

		section "停止前的端口监听：$title"
		if [ -s "$TMPD/ports_$name.txt" ]; then cat "$TMPD/ports_$name.txt"; else echo "（没有记录到，服务器可能提前退出了，或者没有监听 $PORT 端口）"; fi

		section "SourceMod 日志：$title（这次运行期间修改过的）"
		local found=0 f
		if [ -d "$GAME/addons/sourcemod/logs" ]; then
			while IFS= read -r f; do
				found=1
				echo "--- ${f#"$GAME"/}（最后 150 行）"
				tail -n 150 "$f"
			done < <(find "$GAME/addons/sourcemod/logs" -type f -name '*.log' -newermt "@$t0" 2>/dev/null | sort)
		fi
		[ $found -eq 0 ] && echo "没有生成或更新 SourceMod 日志（SourceMod 没有加载，或者地图没有开始加载）"
	} 2>&1 | tee -a "$LOG"
}

[ $HAVE_GDB -eq 1 ] || echo "没有安装 gdb，只能记录退出码，无法记录服务器停在哪里（安装: sudo apt install gdb）"
for t in "${TESTS[@]}"; do
	run_test "$t"
done

{
	section "系统日志里的崩溃记录（需要权限，可能为空）"
	dmesg 2>/dev/null | grep -iE 'srcds|segfault|out of memory|killed process' | tail -n 20
} 2>&1 | tee -a "$LOG"

echo
echo "诊断完成，请把这个文件发给我: $LOG"
