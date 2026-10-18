@echo off
rem L4D2 战役服务器启动脚本（Windows）。放在服务器根目录（srcds.exe 所在目录）运行。
cd /d "%~dp0"
start srcds.exe -game left4dead2 -console -port 27015 -tickrate 100 +map c1m1_hotel +exec server.cfg
