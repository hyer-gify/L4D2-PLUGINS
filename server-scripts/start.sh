#!/bin/bash
# L4D2 战役服务器启动脚本（Linux）。放在服务器根目录（srcds_run 所在目录）运行。
# -tickrate 100 需要 tickrate_enabler；人数由 server.cfg 的 sv_maxplayers 控制。
# -ip 0.0.0.0：Ubuntu 默认把主机名解析到 127.0.1.1，不加这个参数服务器只监听本机，外面的玩家连不进来。
# 同一台机器开多个服务器时，每个改成不同的 -port。
cd "$(dirname "$0")"
./srcds_run -game left4dead2 -console -ip 0.0.0.0 -port 27015 -tickrate 100 +map c1m1_hotel +exec server.cfg
