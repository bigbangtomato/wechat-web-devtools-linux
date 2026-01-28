#!/bin/bash
set -euo pipefail

WECHAT_DEVTOOLS_HOME="${WECHAT_DEVTOOLS_HOME:-/opt/wechat-devtools}"

# 数据目录：默认 /home/user/.config（可通过挂载 -v $HOME/.config/wechat-devtools-docker:/home/user/.config/... 持久化）
if [ -z "${XDG_CONFIG_HOME:-}" ]; then
  DATA_DIR="$HOME/.config"
else
  DATA_DIR="$XDG_CONFIG_HOME"
fi

# 获取 App 名称（与仓库的 bin/wechat-devtools 逻辑保持一致）
APP_NAME=$(grep -Eo 'name":".*","main' "$WECHAT_DEVTOOLS_HOME/package.nw/package.json" | head -n 1 || true)
APP_NAME=${APP_NAME//name\":\"/}
APP_NAME=${APP_NAME//\",\"main/}
if [ -z "$APP_NAME" ]; then
  APP_NAME="wechat-devtools"
fi

export WECHAT_DEVTOOLS_DIR="$WECHAT_DEVTOOLS_HOME/nwjs"
export APPDATA="$DATA_DIR/$APP_NAME"
export USERPROFILE="$APPDATA"
export PATH="$WECHAT_DEVTOOLS_HOME/node/bin:$WECHAT_DEVTOOLS_HOME/nwjs:$PATH"

mkdir -p "$APPDATA"

#
# DevTools 会尝试从 $APPDATA/WeappPlugin 加载扩展与 inspector。
# 初次启动/插件损坏时，这个目录可能不存在或缺少 manifest.json，从而弹窗“清单不存在/扩展出错”。
# 这里做一个兜底：如果 WeappPlugin 清单不存在，就回退到内置 ideplugin。
#
EXTENSION1="--load-extension=$WECHAT_DEVTOOLS_HOME/nwjs/package.nw/js/ideplugin"
INSPECTOR1="--custom-devtools-frontend=file://$WECHAT_DEVTOOLS_HOME/package.nw/js/ideplugin/inspector"

EXTENSION2="--load-extension=$APPDATA/WeappPlugin"
INSPECTOR2="--custom-devtools-frontend=file://$APPDATA/WeappPlugin/inspector/"

EXTENSION_FLAGS=("$EXTENSION1" "$INSPECTOR1")
if [ -f "$APPDATA/WeappPlugin/manifest.json" ] || [ -f "$APPDATA/WeappPlugin/inspector/manifest.json" ]; then
  EXTENSION_FLAGS=("$EXTENSION2" "$INSPECTOR2")
fi

# 容器内 Chromium sandbox 通常不可用，默认加上 --no-sandbox。
# 同时禁用 GPU（容器里常见缺 GL/驱动），避免启动阶段报错或黑屏。
DEFAULT_FLAGS=(--no-sandbox --disable-dev-shm-usage --disable-gpu --disable-software-rasterizer)

exec "$WECHAT_DEVTOOLS_HOME/nwjs/nw" "$WECHAT_DEVTOOLS_HOME/package.nw" "${DEFAULT_FLAGS[@]}" "${EXTENSION_FLAGS[@]}" "$@"

