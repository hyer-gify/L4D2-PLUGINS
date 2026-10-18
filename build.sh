#!/usr/bin/env bash
# 编译本仓库所有插件源码（SourceMod 1.12 编译器位于 tools/spcomp）。
# 用法: ./build.sh [模块名...]    例如 ./build.sh basic fun
# 规则: <模块>/addons/sourcemod/scripting/<子目录>/xxx.sp
#   -> <模块>/addons/sourcemod/plugins/<子目录>/xxx.smx
# 其中子目录名 "disabled_<名字>" 会输出到 plugins/disabled/<名字>/（不会被自动加载，由模式切换插件按需加载）。
set -u
cd "$(dirname "$0")"
ROOT=$(pwd)
SPCOMP="$ROOT/tools/spcomp/spcomp64"
[ "$(uname -m)" = "x86_64" ] || SPCOMP="$ROOT/tools/spcomp/spcomp"
INC="$ROOT/core/addons/sourcemod/scripting/include"
MODULES=("$@")
[ ${#MODULES[@]} -eq 0 ] && MODULES=(basic advanced fun)
fail=0; ok=0
LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
for mod in "${MODULES[@]}"; do
  base="$ROOT/$mod/addons/sourcemod"
  for sub in "$base"/scripting/*/; do
    [ -d "$sub" ] || continue
    name=$(basename "$sub")
    out="$base/plugins/$name"
    case "$name" in disabled_*) out="$base/plugins/disabled/${name#disabled_}";; esac
    mkdir -p "$out"
    for sp in "$sub"*.sp; do
      [ -f "$sp" ] || continue
      smx="$out/$(basename "${sp%.sp}").smx"
      if "$SPCOMP" "$sp" -i"$INC" -i"$sub" -i"$sub/include" -o"$smx" -v0 >"$LOG" 2>&1; then
        ok=$((ok+1)); grep -i "warning [0-9]" "$LOG" | grep -v "CreateDialog" | sed "s|^|[warn] |" || true
      else
        fail=$((fail+1)); echo "[FAIL] $sp"; cat "$LOG"
      fi
    done
  done
done
echo "编译完成: 成功 $ok, 失败 $fail"
[ $fail -eq 0 ]
