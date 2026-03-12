# Docker 容器共享宿主机 `ibus` 输入法总结

## 背景

本项目通过 `tools/run-wechat-devtools-docker.sh` 在 Linux 下以 Docker 容器方式运行微信开发者工具 GUI。

宿主机环境为：

- 桌面会话：X11
- 输入法框架：`ibus`
- 输入引擎：`rime`

目标是让容器内运行的微信开发者工具直接复用宿主机输入法，而不是在容器内再启动一套独立输入法。

## 初始现象

- 容器内 GUI 可以正常显示
- 宿主机可以正常切换到中文输入
- 但容器内微信开发者工具无法输入中文

排查过程中还出现过如下现象：

```bash
docker exec wechat-dev-tool ibus engine
```

输出：

```text
(process:511): IBUS-CRITICAL **: ... ibus_bus_get_global_engine: assertion 'IBUS_IS_BUS (bus)' failed
No engine is set.
```

## 关键结论

### 1. 容器内不需要启动 `ibus-daemon`

本方案是“共享宿主机输入法”，不是“容器内独立运行输入法”。

因此应由宿主机提供：

- `ibus-daemon`
- `ibus-rime`

容器内只需要提供 `ibus` 客户端能力，并接入宿主机会话。

### 2. 仅透传 `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS` 不够

要让容器里的 GUI 程序真正使用宿主机 `ibus`，至少需要：

- `GTK_IM_MODULE=ibus`
- `QT_IM_MODULE=ibus`
- `XMODIFIERS=@im=ibus`
- `XDG_RUNTIME_DIR`
- `DBUS_SESSION_BUS_ADDRESS`

### 3. Ubuntu 上还会被 AppArmor 拦截

即使容器中已经能看到宿主机的 session dbus socket，Docker 默认的 AppArmor 策略仍可能阻止容器访问宿主机会话总线。

实际报错类似：

```text
An AppArmor policy prevents this sender from sending this message to this recipient
```

因此运行容器时还需要：

```bash
--security-opt apparmor=unconfined
```

### 4. `ibus` 还依赖私有地址 `IBUS_ADDRESS`

这次问题的最终根因不只是 session dbus。

`ibus` 客户端还需要宿主机的私有连接地址，通常可以通过：

```bash
ibus address
```

获取，例如：

```text
unix:path=/home/joseph/.cache/ibus/dbus-XXXX,guid=YYYY
```

如果容器里没有这个地址及对应 socket，通常会出现：

- `ibus engine` 无法获取当前 engine
- GUI 程序无法真正使用宿主机输入法

## 最终修改

### `docker/Dockerfile.runtime`

增加 `ibus` 客户端依赖：

```dockerfile
ibus
ibus-gtk3
```

### `tools/run-wechat-devtools-docker.sh`

增加以下透传逻辑：

- 透传 `XDG_RUNTIME_DIR`
- 透传 `DBUS_SESSION_BUS_ADDRESS`
- 透传 `GTK_IM_MODULE=ibus`
- 透传 `QT_IM_MODULE=ibus`
- 透传 `XMODIFIERS=@im=ibus`
- 自动读取宿主机 `IBUS_ADDRESS`
- 自动挂载 `IBUS_ADDRESS` 对应的宿主机 `ibus` socket 目录
- 增加 `--security-opt apparmor=unconfined`

### `README.MD`

补充了容器共享宿主机 `ibus` 会话的说明。

## 验证方式

### 1. 重建并启动

首次引入 `ibus` 依赖后，需要重建镜像：

```bash
tools/run-wechat-devtools-docker.sh --build
```

之后每次重启容器：

```bash
docker rm -f wechat-dev-tool
tools/run-wechat-devtools-docker.sh
```

### 2. 检查环境变量

```bash
docker exec wechat-dev-tool bash -lc 'env | sed -n "/^IBUS/p;/^DBUS_SESSION_BUS_ADDRESS=/p;/^XDG_RUNTIME_DIR=/p;/^GTK_IM_MODULE=/p;/^QT_IM_MODULE=/p;/^XMODIFIERS=/p"'
```

### 3. 检查宿主机 `ibus` 服务是否可见

```bash
docker exec wechat-dev-tool bash -lc 'dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames'
```

输出中应能看到：

```text
org.freedesktop.IBus
```

### 4. 检查当前 engine

在宿主机切换到中文输入法后执行：

```bash
docker exec wechat-dev-tool ibus engine
```

常见结果：

- `rime`：说明容器已读取到宿主机当前中文输入引擎
- `xkb:us::eng`：说明容器能连上 `ibus`，但宿主机当前是英文状态

### 5. 最终以 GUI 实测为准

在微信开发者工具内任意文本输入框测试：

1. 宿主机切换到 `rime`
2. 在容器内输入拼音
3. 候选词正常弹出
4. 中文可正常上屏

满足以上条件即可认为共享成功。

## 注意事项

### 1. 宿主机必须已经启动 `ibus`

宿主机至少需要保证：

- `ibus-daemon` 正常运行
- 当前桌面会话存在 `XDG_RUNTIME_DIR`
- `ibus address` 能返回非空地址

### 2. 容器用户需要能访问宿主机会话资源

如果后续出现能看到环境变量但仍无法输入的情况，需要优先排查：

- UID/GID 是否与宿主机用户匹配
- `XDG_RUNTIME_DIR` 挂载后的权限是否可访问
- `IBUS_ADDRESS` 对应 socket 是否存在

### 3. `ibus engine` 只是辅助检查

真正是否可用，最终仍以微信开发者工具 GUI 中能否正常输入中文为准。
