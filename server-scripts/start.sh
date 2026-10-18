#!/bin/bash
# L4D2 战役服务器启动脚本（Linux）。放在服务器根目录（srcds_run 所在目录）运行。
# -tickrate 100 需要 tickrate_enabler；人数由 server.cfg 的 sv_maxplayers 控制。
# -ip 0.0.0.0：Ubuntu 默认把主机名解析到 127.0.1.1，不加这个参数服务器只监听本机，外面的玩家连不进来。
# 同一台机器开多个服务器时，每个改成不同的 -port。
cd "$(dirname "$0")"
# start_debug.sh 被强行中断时会留下临时改名的插件加载文件，这里改回来
for f in left4dead2/addons/*.vdf.debug_off; do [ -f "$f" ] && mv -n "$f" "${f%.debug_off}"; done
# 启动参数里的 +map、+exec 由 left4dead2/cfg/valve.rc 里的 stuffcmds 执行。
# 这个文件丢了，服务器会停在 "Network: IP ..." 之后不加载地图，谁都进不去，这里自动补上。
[ -f left4dead2/cfg/valve.rc ] || { mkdir -p left4dead2/cfg && printf 'exec autoexec.cfg\nstuffcmds\n' > left4dead2/cfg/valve.rc; }
./srcds_run -game left4dead2 -console -ip 0.0.0.0 -port 27015 -tickrate 100 +map c1m1_hotel +exec server.cfg
