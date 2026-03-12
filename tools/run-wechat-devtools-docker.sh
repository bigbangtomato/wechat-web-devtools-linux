#!/bin/bash
#
# 在 Docker 容器内运行“微信开发者工具”（GUI）
#
# 依赖：宿主机仅需 docker；GUI 通过 X11（默认）或 Wayland（实验性）转发
#
set -euo pipefail

root_dir=$(cd "$(dirname "$0")/.." && pwd -P)

IMAGE="${WECHAT_DEVTOOLS_IMAGE:-wechat-devtools-runtime:local}"
SETUP_ARGS="${SETUP_ARGS:-}"
# 默认使用本机 HTTP 代理（按你的要求）
WECHAT_DEVTOOLS_PROXY="${WECHAT_DEVTOOLS_PROXY:-http://localhost:8118}"

usage() {
  cat <<EOF
用法：
  $0 [--build] [--] [devtools-args...]

环境变量：
  WECHAT_DEVTOOLS_IMAGE  运行的镜像名（默认：${IMAGE}）
  SETUP_ARGS             构建阶段传给 tools/setup-wechat-devtools.sh 的参数（如：version=latest）
  WECHAT_DEVTOOLS_PROXY  代理（可选），默认：http://localhost:8118

示例：
  $0 --build
  $0 -- --disable-gpu
  WECHAT_DEVTOOLS_PROXY=http://localhost:8118 $0 --build
EOF
}

DO_BUILD=false
if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
if [ "${1:-}" = "--build" ]; then
  DO_BUILD=true
  shift
fi
if [ "${1:-}" = "--" ]; then
  shift
fi

if [ "$DO_BUILD" = "true" ]; then
  build_args=()

  # 代理透传：优先使用 WECHAT_DEVTOOLS_PROXY，否则透传宿主机已有的 *_PROXY
  if [ -n "$WECHAT_DEVTOOLS_PROXY" ]; then
    build_args+=(--build-arg "http_proxy=${WECHAT_DEVTOOLS_PROXY}")
    build_args+=(--build-arg "https_proxy=${WECHAT_DEVTOOLS_PROXY}")
    build_args+=(--build-arg "all_proxy=${WECHAT_DEVTOOLS_PROXY}")
    build_args+=(--build-arg "npm_config_proxy=${WECHAT_DEVTOOLS_PROXY}")
    build_args+=(--build-arg "npm_config_https_proxy=${WECHAT_DEVTOOLS_PROXY}")
  else
    # 兼容大小写
    for k in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
      v="${!k:-}"
      if [ -n "$v" ]; then
        build_args+=(--build-arg "${k}=${v}")
      fi
    done
  fi

  # 如果代理指向本机（localhost/127.0.0.1），构建阶段需要使用 host network 才能访问宿主机代理端口
  if [ -n "$WECHAT_DEVTOOLS_PROXY" ] && echo "$WECHAT_DEVTOOLS_PROXY" | grep -Eq '(localhost|127\\.0\\.0\\.1)'; then
    build_args+=(--network=host)
  else
    # 若用户通过环境变量设置了 localhost 代理，同样启用 host 网络
    if echo "${ALL_PROXY:-}${all_proxy:-}${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" | grep -Eq '(localhost|127\\.0\\.0\\.1)'; then
      build_args+=(--network=host)
    fi
  fi

  docker build \
    -f "$root_dir/docker/Dockerfile.runtime" \
    --build-arg "SETUP_ARGS=${SETUP_ARGS}" \
    "${build_args[@]}" \
    -t "$IMAGE" \
    "$root_dir"
fi

# 优先 Wayland（存在 WAYLAND_DISPLAY 时尝试），否则走 X11
docker_args=()
runtime_dir_mounted=false

mount_runtime_dir() {
  if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ] && [ "$runtime_dir_mounted" != "true" ]; then
    docker_args+=(
      -e "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
      -v "${XDG_RUNTIME_DIR}:${XDG_RUNTIME_DIR}:rw"
    )
    runtime_dir_mounted=true
  fi
}

if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
  # Wayland（实验性）：部分环境仍可能需要 XWayland
  mount_runtime_dir
  docker_args+=(
    -e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
  )
fi

if [ -n "${DISPLAY:-}" ] && [ -S "/tmp/.X11-unix/X0" ]; then
  XAUTH="${XAUTHORITY:-${HOME}/.Xauthority}"
  if [ -f "$XAUTH" ]; then
    docker_args+=(
      -e "DISPLAY=${DISPLAY}"
      -e "XAUTHORITY=/tmp/.Xauthority"
      -v "/tmp/.X11-unix:/tmp/.X11-unix:rw"
      -v "${XAUTH}:/tmp/.Xauthority:ro"
    )
  else
    docker_args+=(
      -e "DISPLAY=${DISPLAY}"
      -v "/tmp/.X11-unix:/tmp/.X11-unix:rw"
    )
  fi
fi

# 透传宿主机 ibus 会话环境，适配 ibus + rime 等输入法方案
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
  mount_runtime_dir
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    docker_args+=(-e "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS}")
  elif [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
    docker_args+=(-e "DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/bus")
  fi
fi
host_ibus_address="$(ibus address 2>/dev/null || true)"
if [ -n "$host_ibus_address" ] && [ "$host_ibus_address" != "(null)" ]; then
  docker_args+=(-e "IBUS_ADDRESS=${host_ibus_address}")
  if echo "$host_ibus_address" | grep -Eq '^unix:path='; then
    ibus_socket_path="${host_ibus_address#unix:path=}"
    ibus_socket_path="${ibus_socket_path%%,*}"
    ibus_socket_dir="$(dirname "$ibus_socket_path")"
    if [ -d "$ibus_socket_dir" ]; then
      docker_args+=(-v "${ibus_socket_dir}:${ibus_socket_dir}:rw")
    fi
  fi
fi
docker_args+=(
  -e "GTK_IM_MODULE=ibus"
  -e "QT_IM_MODULE=ibus"
  -e "XMODIFIERS=@im=ibus"
)

# 常见 Chromium/NWJS 运行建议
docker_args+=(
  --ipc=host
  -v "/dev/shm:/dev/shm"
)

# 运行时代理（如需联网下载插件等）：同样透传
if [ -n "$WECHAT_DEVTOOLS_PROXY" ]; then
  docker_args+=(-e "http_proxy=${WECHAT_DEVTOOLS_PROXY}" -e "https_proxy=${WECHAT_DEVTOOLS_PROXY}" -e "all_proxy=${WECHAT_DEVTOOLS_PROXY}")
  docker_args+=(-e "HTTP_PROXY=${WECHAT_DEVTOOLS_PROXY}" -e "HTTPS_PROXY=${WECHAT_DEVTOOLS_PROXY}" -e "ALL_PROXY=${WECHAT_DEVTOOLS_PROXY}")
  docker_args+=(-e "npm_config_proxy=${WECHAT_DEVTOOLS_PROXY}" -e "npm_config_https_proxy=${WECHAT_DEVTOOLS_PROXY}")
  if echo "$WECHAT_DEVTOOLS_PROXY" | grep -Eq '(localhost|127\\.0\\.0\\.1)'; then
    docker_args+=(--network=host)
  fi
else
  for k in http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    v="${!k:-}"
    if [ -n "$v" ]; then
      docker_args+=(-e "${k}=${v}")
      if echo "$v" | grep -Eq '(localhost|127\\.0\\.0\\.1)'; then
        docker_args+=(--network=host)
      fi
    fi
  done
fi

# GPU（可选）：存在 /dev/dri 时挂载
if [ -d "/dev/dri" ]; then
  docker_args+=(--device /dev/dri)
fi

# 持久化配置目录（容器内 user 为 /home/user）
mkdir -p "$root_dir/.docker-config"
docker_args+=(
  -v "$root_dir/.docker-config:/home/user/.config:rw"
)

# 有交互终端则分配 TTY；否则避免报错 "the input device is not a TTY"
tty_flags=(-i)
if [ -t 0 ] && [ -t 1 ]; then
  tty_flags=(-it)
fi

exec docker run "${tty_flags[@]}" \
  -v /run/dbus/system_bus_socket:/run/dbus/system_bus_socket:ro \
  -v /home/data/code/:/code \
  --name=wechat-dev-tool \
  --security-opt apparmor=unconfined \
  "${docker_args[@]}" \
  "$IMAGE" \
  "$@"

# exec docker run --rm -it -e DISPLAY=:0 -e XAUTHORITY=/tmp/.Xauthority -v /tmp/.X11-unix:/tmp/.X11-unix:rw -v /run/user/1000/gdm/Xauthority:/tmp/.Xauthority:ro --ipc=host -v /dev/shm:/dev/shm -e http_proxy=http://localhost:8118 -e https_proxy=http://localhost:8118 -e all_proxy=http://localhost:8118 -e HTTP_PROXY=http://localhost:8118 -e HTTPS_PROXY=http://localhost:8118 -e ALL_PROXY=http://localhost:8118 -e npm_config_proxy=http://localhost:8118 -e npm_config_https_proxy=http://localhost:8118 --network=host --device /dev/dri -v /home/data/code/github/wechat-web-devtools-linux/.docker-config:/home/user/.config:rw wechat-devtools-runtime:local
