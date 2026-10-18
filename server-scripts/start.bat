@echo off
rem L4D2 战役服务器启动脚本（Windows）。放在服务器根目录（srcds.exe 所在目录）运行。
cd /d "%~dp0"
rem 启动参数里的 +map、+exec 由 left4dead2\cfg\valve.rc 里的 stuffcmds 执行，文件丢了地图不会加载，这里自动补上。
if not exist "left4dead2\cfg\valve.rc" (
	(echo exec autoexec.cfg& echo stuffcmds)> "left4dead2\cfg\valve.rc"
)
start srcds.exe -game left4dead2 -console -ip 0.0.0.0 -port 27015 -tickrate 100 +map c1m1_hotel +exec server.cfg
