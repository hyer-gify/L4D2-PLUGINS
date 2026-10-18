#!/bin/bash
# L4D2 战役服务器启动脚本（Linux）。放在服务器根目录（srcds_run 所在目录）运行。
# -tickrate 100 需要 tickrate_enabler；+sv_setmax 不需要，人数由 server.cfg 的 sv_maxplayers 控制。
cd "$(dirname "$0")"
./srcds_run -game left4dead2 -console -port 27015 -tickrate 100 +map c1m1_hotel +exec server.cfg
