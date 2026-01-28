#!/bin/bash

root_dir=$(cd `dirname $0`/.. && pwd -P)
echo "$(id -u):$(id -g)"

#
# 说明：
# - 旧逻辑在宿主机调用 node 来解析 arch；为了做到“宿主机只依赖 docker”，这里改为用 uname 判断。
# - 本项目现阶段仅明确支持 x64 与 loongarch64 两种 arch（与 parse-config.js 的校验保持一致）。
#
uname_m=$(uname -m)
arch=""
case "$uname_m" in
  x86_64)
    arch="x64"
    ;;
  loongarch64)
    arch="loongarch64"
    ;;
  *)
    echo "Unsupported arch: $uname_m (only x86_64 and loongarch64 are supported)" >&2
    exit 1
    ;;
esac

image="msojocs/wechat-devtools-build:v1.0.6"
if [ "$arch" == "loongarch64" ]; then
    image="msojocs/wechat-devtools-build:loong64-v1.0.0"
fi
docker run --rm -i \
    -u "$(id -u):$(id -g)" \
    -e "ACTION_MODE=${ACTION_MODE:-false}" \
    -e "http_proxy=${http_proxy:-${HTTP_PROXY:-}}" \
    -e "https_proxy=${https_proxy:-${HTTPS_PROXY:-}}" \
    -e "all_proxy=${all_proxy:-${ALL_PROXY:-}}" \
    -e "no_proxy=${no_proxy:-${NO_PROXY:-}}" \
    -e "npm_config_proxy=${npm_config_proxy:-${NPM_CONFIG_PROXY:-${http_proxy:-${HTTP_PROXY:-}}}}" \
    -e "npm_config_https_proxy=${npm_config_https_proxy:-${NPM_CONFIG_HTTPS_PROXY:-${https_proxy:-${HTTPS_PROXY:-}}}}" \
    -e "HTTP_PROXY=${HTTP_PROXY:-}" \
    -e "HTTPS_PROXY=${HTTPS_PROXY:-}" \
    -e "ALL_PROXY=${ALL_PROXY:-}" \
    -e "NO_PROXY=${NO_PROXY:-}" \
    -w /workspace \
    -v "$root_dir:/workspace" \
    $image \
    bash ./tools/setup-wechat-devtools.sh $@