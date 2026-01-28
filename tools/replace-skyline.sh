#!/bin/bash
set -ex
root_dir=$(cd `dirname $0`/.. && pwd -P)
srcdir=$root_dir
tmp_dir="$root_dir/tmp"
cache_dir="$root_dir/cache"
nwjs_dir="$root_dir/nwjs"
package_dir="$root_dir/package.nw"

shared_memory_version="v1.0.3"
skyline_version="v1.0.4"

download() {
  # 用 curl + 重试，支持走代理（ALL_PROXY/HTTPS_PROXY/http_proxy 等）；
  # 也支持用 GITHUB_PROXY_PREFIX 做 URL 前缀代理（例如 https://ghproxy.com/）
  local url="$1"
  local out="$2"

  if [ -n "${GITHUB_PROXY_PREFIX:-}" ]; then
    url="${GITHUB_PROXY_PREFIX}${url}"
  fi

  mkdir -p "$(dirname "$out")"
  curl -fL --retry 6 --retry-delay 2 --connect-timeout 20 --max-time 600 \
    -o "$out" \
    "$url"
}

cd "$package_dir/node_modules"
rm sharedMemory/sharedMemory.node
download \
  "https://github.com/msojocs/skyline-shared-memory/releases/download/$shared_memory_version/skyline-sharedMemory-linux-x86_64-$shared_memory_version.node" \
  "sharedMemory/sharedMemory.node"

cd skyline-addon
rm build/skyline.node
download \
  "https://github.com/msojocs/skyline-client-server/releases/download/$skyline_version/skyline-client-linux-x86_64-$skyline_version.node" \
  "build/skyline.node"
rm build/icudtl.dat
rm -rf bundle

mv ${package_dir}/js/extensions/inject/documentstart/index.js ${package_dir}/js/extensions/inject/documentstart/index.js.bak
cp ${srcdir}/res/scripts/document_start.js ${package_dir}/js/extensions/inject/documentstart/index.js
cat ${package_dir}/js/extensions/inject/documentstart/index.js.bak >> ${package_dir}/js/extensions/inject/documentstart/index.js
rm ${package_dir}/js/extensions/inject/documentstart/index.js.bak

mv ${package_dir}/js/extensions/skyline/index.js ${package_dir}/js/extensions/skyline/index.js.bak
cp ${srcdir}/res/scripts/skyline.js ${package_dir}/js/extensions/skyline/index.js
cat ${package_dir}/js/extensions/skyline/index.js.bak >> ${package_dir}/js/extensions/skyline/index.js
rm ${package_dir}/js/extensions/skyline/index.js.bak