# 共享宿主机输入法到docker容器
_Exported on 3/12/2026 at 09:50:53 GMT+8 from Cursor (2.6.12)_

---

**User**

本项目用于在linux下使用docker容器启动微信开发者工具，目前使用 @tools/run-wechat-devtools-docker.sh 能成功运行。但是容器内没安装输入法，怎么共享宿主机的输入法？

---

**Cursor**

我先看一下你这边的全局规则和当前这个 Docker 启动脚本，确认容器是怎么接入宿主机桌面环境的，再给你一个适合这个项目的输入法共享方案。

脚本已经把 `DISPLAY`、`WAYLAND_DISPLAY` 和 `XDG_RUNTIME_DIR` 透传了，图形界面能出来，但输入法这类功能还差“客户端库 + 宿主机输入法服务的 socket/环境变量”两部分，我再确认一下容器基础环境。

容器镜像里目前完全没装 `fcitx/ibus` 相关运行库，所以即使把宿主机服务透传进来，应用也不会接入；下一步我看一下入口脚本，确认最合适把环境变量放在哪一层。

我再核对一下 `fcitx5` 在容器里该用哪组环境变量，避免给你一套能启动但实际不能输入中文的配置。

可以共享，但不是“宿主机装了输入法，容器里自动就能用”。对这类 `NW.js/Chromium` GUI 程序来说，需要两件事同时满足：

1. 容器里安装输入法前端模块
2. 把宿主机输入法服务的运行环境和 socket 透传进去

你这个项目当前脚本已经透传了显示相关环境，但还没透传输入法相关内容：

```84:111:tools/run-wechat-devtools-docker.sh
# 优先 Wayland（存在 WAYLAND_DISPLAY 时尝试），否则走 X11
docker_args=()

if [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ]; then
  # Wayland（实验性）：部分环境仍可能需要 XWayland
  docker_args+=(
    -e "WAYLAND_DISPLAY=${WAYLAND_DISPLAY}"
    -e "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
    -v "${XDG_RUNTIME_DIR}:${XDG_RUNTIME_DIR}"
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
  fi
```

而镜像里也没装 `fcitx/ibus` 相关包：

```50:96:docker/Dockerfile.runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    locales \
    fontconfig \
    # 中文字体
    fonts-noto-cjk \
    fonts-wqy-zenhei \
    # ...省略...
    libgtk-3-0 \
    libcurl4 \
    libnspr4 \
    libnss3 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libx11-6 \
    libx11-xcb1 \
    # ...省略...
    xdg-utils \
    && rm -rf /var/lib/apt/lists/* \
    && fc-cache -fv
```

最稳的方案是按 `fcitx5 + X11/XWayland` 来做。微信开发者工具这种 Chromium 系程序在 Linux 下走这条路通常最省事。

## 推荐做法

先在容器里装前端模块，至少加上：

```dockerfile
fcitx5 \
fcitx5-frontend-gtk3
```

然后运行容器时增加这些环境变量：

```bash
-e XMODIFIERS=@im=fcitx
-e GTK_IM_MODULE=fcitx
-e QT_IM_MODULE=fcitx
-e SDL_IM_MODULE=fcitx
```

再把宿主机运行时目录透传进去，因为 `fcitx5` 的 socket 通常在 `$XDG_RUNTIME_DIR` 下：

```bash
-e XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}
-e DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/bus
-v ${XDG_RUNTIME_DIR}:${XDG_RUNTIME_DIR}:rw
```

## 对你这个项目，脚本大致要补成这样

在 `tools/run-wechat-devtools-docker.sh` 里加一段类似：

```bash
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
  docker_args+=(
    -e "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR}"
    -e "DBUS_SESSION_BUS_ADDRESS=unix:path=${XDG_RUNTIME_DIR}/bus"
    -e "XMODIFIERS=@im=fcitx"
    -e "GTK_IM_MODULE=fcitx"
    -e "QT_IM_MODULE=fcitx"
    -e "SDL_IM_MODULE=fcitx"
    -v "${XDG_RUNTIME_DIR}:${XDG_RUNTIME_DIR}:rw"
  )
fi
```

`docker/Dockerfile.runtime` 里加：

```dockerfile
fcitx5 \
fcitx5-frontend-gtk3 \
```

## 两个关键注意点

1. 容器用户 UID 最好和宿主机一致  
不然即使挂载了 `$XDG_RUNTIME_DIR`，也可能没权限访问 `fcitx5` socket。你这个镜像里 `useradd -m -s /bin/bash user` 默认大概率是 `1000`，如果宿主机用户不是 `1000`，还要额外处理 UID/GID。

2. Wayland 原生输入法不要优先折腾  
这个项目是 `NW.js`，实际更适合跑在 `XWayland/X11` 路径上。强行走 Wayland IME 往往还要加 Chromium/Ozone 参数，稳定性未必更好。

## 如果你宿主机用的是 `ibus`

那就不是 `fcitx` 这套变量了，而是：

- 安装：`ibus ibus-gtk3`
- 环境变量：
  - `GTK_IM_MODULE=ibus`
  - `QT_IM_MODULE=ibus`
  - `XMODIFIERS=@im=ibus`
- 同样透传 `XDG_RUNTIME_DIR` 和 session dbus

如果你愿意，我可以直接帮你把这两个文件改好，按 `fcitx5` 方案落地。

---

**User**

为什么推荐“fcitx5”？比“ibus”更好吗？

---

**Cursor**

不是绝对“更好”，而是对你这个场景更合适。

你这里不是单纯比较桌面输入法，而是比较“宿主机输入法共享给 Docker 里的 `NW.js/Chromium` 应用”哪套更省事。这个场景下我更偏向 `fcitx5`，主要是这几个原因：

- 对中文输入体验，`fcitx5` 通常更强。拼音、Rime、词库、候选框体验、可扩展性，一般都比 `ibus` 更受中文用户欢迎。
- 对 `Chromium/Electron/NW.js + X11/XWayland`，`fcitx5` 的资料和成功案例更多，配置路径也更清晰。官方文档里就专门提到这类应用走 XWayland 时，用 `GTK_IM_MODULE=fcitx` 这条路最常见。
- 容器场景里，`fcitx5` 的“宿主机跑服务，容器装 frontend 模块并挂 socket”这套做法更常见，排障经验也更多。

但这不等于 `ibus` 差。`ibus` 的优势也很明确：

- 和 GNOME 集成更紧，Ubuntu 默认就是它。
- 如果你宿主机现在本来就在用 `ibus`，那继续共享 `ibus` 往往是改动最小的方案。
- 你不需要为了容器专门把宿主机输入法体系切到 `fcitx5`。

所以更准确地说：

- 如果你宿主机已经在用 `ibus`：优先先试 `ibus`，因为最省改动。
- 如果你宿主机本来就是 `fcitx5`，或者你更看重中文输入体验和后续长期使用：`fcitx5` 通常更值得。

还有一个容易混淆的点：框架叫 `fcitx5`，但很多环境变量值仍然写 `fcitx`，比如：

```bash
XMODIFIERS=@im=fcitx
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
```

不是写成 `fcitx5`。

如果你愿意，我下一步可以先帮你判断宿主机当前到底在用 `fcitx5` 还是 `ibus`，然后按那一套给这个项目出最省事的修改方案。

---

**User**

但是宿主机安装的是ibus + rime，容器安装fcitx5能用吗？

---

**Cursor**

一般**不能直接用**。如果宿主机是 `ibus + rime`，而容器里只装 `fcitx5`，这不算“共享宿主机输入法”，因为两边协议不一致。

核心区别是：

- 宿主机真正提供服务的是 `ibus-daemon`
- 容器里的应用如果加载的是 `fcitx` 前端模块，它会去找 `fcitx5` 的服务
- `rime` 只是输入引擎，不负责应用和输入法框架之间的通信

所以这两种搭配里，只有一种是对的：

- 宿主机 `ibus` + 容器 `ibus` 前端模块
- 宿主机 `fcitx5` + 容器 `fcitx` 前端模块

而这个搭配通常**不对**：

- 宿主机 `ibus` + 容器 `fcitx5`

原因很简单：容器里的应用要跟谁说话，取决于它加载的输入法前端模块；这个模块必须和宿主机正在跑的输入法框架匹配。

对你当前情况，更合适的是容器里装 `ibus` 相关包，而不是 `fcitx5`。大致思路是：

- 安装 `ibus`、`ibus-gtk3`
- 透传：
  - `XDG_RUNTIME_DIR`
  - `DBUS_SESSION_BUS_ADDRESS`
  - `GTK_IM_MODULE=ibus`
  - `QT_IM_MODULE=ibus`
  - `XMODIFIERS=@im=ibus`

如果你在容器里装 `fcitx5`，只有两种可能：

- 你同时在容器里自己启动一套 `fcitx5`，那是“容器内独立输入法”，不是共享宿主机的 `ibus+rime`
- 只装 `fcitx5` 不启动 daemon，还想连宿主机 `ibus`，通常不行

结论就是：**宿主机是 `ibus+rime` 时，容器应优先接 `ibus`，不要装 `fcitx5` 来对接宿主机。**

如果你愿意，我可以下一步直接帮你把这个项目改成 `ibus` 透传方案。

---

**User**

把这个项目改成 ibus 透传方案。

---

**Cursor**

我准备把运行脚本和运行时镜像改成 `ibus` 透传：容器内补 `ibus` 客户端依赖，并把宿主机的 session dbus、`XDG_RUNTIME_DIR` 和 IM 环境变量带进去。

我顺手看下文档里有没有运行说明，避免只改脚本不改说明。

我开始改文件了：镜像里补 `ibus` 客户端依赖，脚本里把 `XDG_RUNTIME_DIR` / session dbus 和 `ibus` 环境变量透传进去，并补一小段使用说明。

---

**User**

似乎因网络中断了，请继续。

---

**Cursor**

我继续把收尾和校验做完，重点检查这次改动有没有脚本语法问题，以及是否还需要补一个兼容性说明。

改动已经落下并通过了基础校验；我再看一眼最终 diff，确认没有遗漏。

已经继续完成了，项目现在改成了 `ibus` 透传方案。

我改了三处：
- `docker/Dockerfile.runtime`：增加 `ibus` 和 `ibus-gtk3`，让容器内的 GUI 应用具备 `ibus` 客户端支持。
- `tools/run-wechat-devtools-docker.sh`：透传 `XDG_RUNTIME_DIR`、`DBUS_SESSION_BUS_ADDRESS`，并默认注入 `GTK_IM_MODULE=ibus`、`QT_IM_MODULE=ibus`、`XMODIFIERS=@im=ibus`。
- `README.MD`：补了一条说明，标明默认适配宿主机 `ibus + rime`。

基础校验已做：
- `bash -n tools/run-wechat-devtools-docker.sh` 通过
- 相关文件没有 linter 报错

你现在需要重新构建镜像后再运行，因为运行时镜像依赖变了：

```bash
tools/run-wechat-devtools-docker.sh --build
tools/run-wechat-devtools-docker.sh
```

如果重建后还是不能输入，最常见原因是容器用户对宿主机的 `XDG_RUNTIME_DIR` 没权限访问。那时我可以继续帮你把脚本改成按宿主机 UID/GID 启动容器。

---

**User**

重启后，怎么确定是否能共享宿主机的输入法？

---

**Cursor**

最可靠的判断方式是看 3 层：`环境变量`、`session dbus`、`实际输入效果`。

## 先看容器里有没有拿到输入法环境

先启动一次：

```bash
tools/run-wechat-devtools-docker.sh
```

然后另开一个终端检查容器：

```bash
docker exec wechat-dev-tool bash -lc 'echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"; echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS"; echo "GTK_IM_MODULE=$GTK_IM_MODULE"; echo "QT_IM_MODULE=$QT_IM_MODULE"; echo "XMODIFIERS=$XMODIFIERS"; test -S "$XDG_RUNTIME_DIR/bus" && echo "session bus socket: ok" || echo "session bus socket: missing"'
```

你应该至少看到：

```bash
GTK_IM_MODULE=ibus
QT_IM_MODULE=ibus
XMODIFIERS=@im=ibus
session bus socket: ok
```

如果这里就不对，说明还没真正透传成功。

## 再看权限是否可能有问题

继续执行：

```bash
docker exec wechat-dev-tool bash -lc 'id; ls -ld "$XDG_RUNTIME_DIR"; ls -l "$XDG_RUNTIME_DIR/bus"'
```

重点看两点：
- 容器里的用户 UID/GID
- `$XDG_RUNTIME_DIR` 和 `bus` 的属主/权限

如果容器用户和宿主机实际登录用户 UID 不一致，常见现象就是：
- 环境变量都在
- `bus` 文件也存在
- 但应用就是调不起输入法

这种情况通常就是权限问题。

## 最后做真实输入测试

这个才是最终判定标准。

在微信开发者工具里找一个确定能输入文字的地方，比如：
- 项目搜索框
- 设置里的文本输入框
- 新建项目时的目录/名称输入框

然后测试：

1. 在宿主机上切换到中文输入法
2. 在容器里的微信开发者工具输入框里输入拼音
3. 看是否出现 Rime 候选词
4. 选词后看中文是否真正进入输入框

判定结果很简单：

- 能弹出候选框，能上屏中文：说明共享成功
- 不能切中文，只能英文：通常是 `ibus/dbus` 没通
- 能切换但没有候选框、不能上屏：通常是 Chromium/NW.js 对输入法前端没接好
- 候选框出现但位置怪异：通常是 GUI/窗口系统兼容问题，不一定是透传失败

## 我建议你按这个顺序排查

1. 先跑上面的 `docker exec` 环境检查
2. 再做界面实际输入测试
3. 如果失败，把这两类结果告诉我：
- 环境检查输出
- 真实输入时的现象

如果你愿意，我下一步可以直接帮你加一个 `--check-ime` 之类的脚本自检逻辑，启动后自动提示输入法透传状态。

---

**User**

容器内，需要启动ibus吗？

---

**Cursor**

通常**不需要**。

你现在做的是“共享宿主机的 `ibus + rime`”，不是在容器里再单独跑一套输入法。所以容器内只需要：

- 有 `ibus` 客户端相关库
- 能访问宿主机的 session dbus
- 有正确的 IM 环境变量

真正应该运行的是宿主机上的：
- `ibus-daemon`
- `ibus-rime`

容器里的微信开发者工具通过 `GTK_IM_MODULE=ibus`、`QT_IM_MODULE=ibus`、`XMODIFIERS=@im=ibus` 去连宿主机那套服务。

## 什么时候才需要在容器里启动 `ibus`

只有一种情况：

- 你想让容器自己独立运行一套输入法，不依赖宿主机

那就需要在容器里安装并启动：
- `ibus-daemon`
- 对应引擎，比如 `ibus-rime`

但这已经不是“共享宿主机输入法”了，而且会更麻烦：
- 要在容器里配输入法
- 要持久化词库/配置
- 还要处理 dbus 会话

## 对你当前方案，结论就是

- 宿主机：启动并正常使用 `ibus + rime`
- 容器：**不用启动 `ibus-daemon`**
- 容器只做“客户端接入宿主机 ibus 服务”

如果你愿意，我可以再帮你补一个容器内的检查命令，用来确认它是不是已经连上宿主机的 `ibus`。

---

**User**

但是，宿主机切换到中文后，容器内还是无法输入中文

---

**Cursor**

我先做现场排查，确认问题是出在 `ibus` 环境没透传、`dbus` 权限不通，还是 Wayland/X11 路径不对。

宿主机当前其实是纯 `X11` 会话，不是 Wayland，这反而缩小了范围；我接着看容器里 `ibus` 环境、用户 UID 和 GTK 输入模块是否齐。

环境变量和 session bus 都已经进容器了，说明问题更可能在“应用是否真的连上宿主机的 `ibus` 服务”这一层，我继续验证这一步。

容器这边已经能访问 `session bus`，但总线上看不到 `org.freedesktop.IBus`，这说明更像是“宿主机当前会话里根本没有启动 `ibus-daemon` / 没挂到这个 dbus 上”。我去核对宿主机本身的 `ibus` 状态。

现在基本能确定根因在“容器连不到宿主机会话总线”，而不是 `ibus` 包没装。我再把 `dbus-send` 的真实报错拿出来，看是权限还是地址问题。

原因已经定位到了，不是“宿主机没切到中文”，也不是“容器里缺 `ibus` 包”，而是 **AppArmor 把容器访问宿主机 session dbus 拦住了**。

我实际检查到的是：

- 宿主机 `ibus-daemon` 正常在跑，当前引擎就是 `rime`
- 容器里这些环境变量都已经有了：`GTK_IM_MODULE=ibus`、`QT_IM_MODULE=ibus`、`XMODIFIERS=@im=ibus`
- 容器里也能看到宿主机的 `/run/user/1000/bus`
- 但容器访问 session dbus 时返回了这个错误：

```text
An AppArmor policy prevents this sender from sending this message to this recipient
```

这就解释了为什么“宿主机切到中文，容器里还是不能输入中文”：
容器拿到了 bus socket，但被 Docker 默认的 AppArmor 策略挡住了，连不上宿主机的 `org.freedesktop.IBus`。

最直接的解决办法是在 `docker run` 里给这个容器加：

```bash
--security-opt apparmor=unconfined
```

这通常就能让容器正常访问宿主机 session dbus，从而共享 `ibus + rime`。

加完后不用重建镜像，只需要重启容器。验证是否成功可以看这两个结果：

```bash
docker exec wechat-dev-tool ibus engine
```

正常的话应返回类似：

```text
rime
```

或者：

```bash
docker exec wechat-dev-tool dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply /org/freedesktop/DBus org.freedesktop.DBus.ListNames
```

输出里应能看到：

```text
org.freedesktop.IBus
```

如果你愿意，我现在可以直接帮你把 `tools/run-wechat-devtools-docker.sh` 改成自动带上 `--security-opt apparmor=unconfined`。

---

**User**

请修改

---

**Cursor**

我把启动脚本加上 `AppArmor` 放行，并顺手补一条说明，避免下次重建或换机器后又踩到同一个问题。

我再做个快速校验，确认脚本语法没问题。

已经改好了。

现在 `tools/run-wechat-devtools-docker.sh` 会自动带上：

```bash
--security-opt apparmor=unconfined
```

这样容器访问宿主机 session dbus 时，不会再被默认 AppArmor 策略拦住；`README.MD` 里我也补了对应说明。

脚本语法已检查通过。你现在只需要重新启动容器即可，不用重建镜像：

```bash
docker rm -f wechat-dev-tool
tools/run-wechat-devtools-docker.sh
```

启动后建议立刻验证一下：

```bash
docker exec wechat-dev-tool ibus engine
```

如果透传成功，通常会看到 `rime`，或者至少不再出现之前那个 AppArmor 拒绝错误。  
如果你愿意，我下一步可以继续帮你现场验证一遍。

---

**User**

执行“docker exec wechat-dev-tool ibus engine”，输出：
(process:511): IBUS-CRITICAL **: 01:12:36.571: ibus_bus_get_global_engine: assertion 'IBUS_IS_BUS (bus)' failed
No engine is set.

---

**Cursor**

我继续排查这个现象，先确认当前容器是不是已经按新脚本重启，以及 `docker exec` 里连 session dbus 时还报不报 AppArmor 拒绝。

我再确认一下这个输出是不是“真失败”，还是 `ibus engine` 这个命令本身不适合拿来判断 GUI 容器。顺便查一下 `NW.js/Chromium + ibus` 在容器里还需要哪些额外变量。

环境和 dbus 现在都通了，`NW.js` 进程也确实拿到了 `ibus` 变量；我怀疑剩下的问题在 GTK 输入模块缓存或 `NW.js/Chromium` 对 `ibus` 的兼容层上，再核对一下 GTK3 是否真的能加载 `im-ibus.so`。

我查到一个关键点：`ibus engine` 这个命令本身并不适合拿来判断图形应用容器是否“已经能用输入法”。我刚在你的环境里验证到 `org.freedesktop.IBus` 已经能从容器访问到了。

我又发现一个潜在问题：宿主机是 Ubuntu 24.04 上的 `ibus 1.5.29`，容器现在是 Ubuntu 22.04，里面的 `ibus` 只有 `1.5.26`。我去确认一下这个版本差异会不会导致客户端连上总线但取不到 engine。

这个输出现在说明的不是“总线不通”，而是“**容器里的 `ibus` 客户端没能正确读到宿主机当前 engine**”。

我刚核对过两件关键事实：

- 容器已经能访问宿主机 session dbus，`org.freedesktop.IBus` 在容器里是可见的
- 宿主机 `ibus` 版本是 `1.5.29`，容器里是 `1.5.26`

所以目前最可疑的根因是：**`ibus` 客户端/daemon 跨版本兼容问题**。也就是：

- 宿主机 daemon 正常
- 容器能连上它
- 但容器里的旧版 `ibus` 客户端拿不到 `GlobalEngine`，于是就出现了你看到的：
  - `IBUS_IS_BUS (bus) failed`
  - `No engine is set`

这也和“实际还是不能输入中文”是吻合的。

最合理的下一步是把运行时镜像的 `ibus` 版本对齐到宿主机，最简单的方法就是把 `docker/Dockerfile.runtime` 从 `ubuntu:22.04` 升到 `ubuntu:24.04`，然后重建镜像。

如果你同意，我下一步直接帮你改成 `Ubuntu 24.04` 运行时镜像，尽量让容器里的 `ibus` 跟宿主机一致。

---

**User**

先不升级，继续排查其他原因。

---

**Cursor**

我换个方向排查：不再盯着版本号，而是确认 `ibus` 客户端是否缺了它真正要连的“私有 socket / 地址信息”，因为 `ibus` 不只是用 session dbus。

我已经找到一个很可疑的点：宿主机有 `~/.config/ibus/bus/...` 地址文件，但容器里这个目录是空的；这说明容器虽然连到了 session dbus，却可能没拿到 `ibus` 自己的私有地址信息。

我做一个最小化实验，不改代码，直接临时起一个测试容器，把宿主机的 `IBUS_ADDRESS` 和对应 socket 目录带进去，看 `ibus` 命令能不能恢复正常。

根因基本确认了：`ibus` 不光依赖 session dbus，还依赖它自己的私有地址 `IBUS_ADDRESS`。我做了个临时容器实验，把宿主机 `IBUS_ADDRESS` 和对应 socket 目录挂进去后，容器里的 `ibus engine` 就恢复正常了。

我把这个修复补进脚本了：现在会自动抓宿主机 `IBUS_ADDRESS`，并把对应的 `ibus` 私有 socket 目录也挂进容器。接下来做一次语法校验。

已经继续改好了，新的根因不是单纯 `dbus`，而是容器里缺少宿主机 `ibus` 的**私有地址**。

我把 `tools/run-wechat-devtools-docker.sh` 补成了两件事：
- 自动读取宿主机 `ibus address`
- 自动把这个地址对应的 `ibus` socket 目录挂进容器，并注入 `IBUS_ADDRESS`

脚本语法和 lint 都通过了。

这次修改后要**重启容器**才能生效，不需要重建镜像：

```bash
docker rm -f wechat-dev-tool
tools/run-wechat-devtools-docker.sh
```

然后验证时请注意：

```bash
docker exec wechat-dev-tool ibus engine
```

如果宿主机当前是英文输入状态，看到 `xkb:us::eng` 是正常的；先把宿主机切到中文 `rime`，再执行一次，预期应变成 `rime`，至少也不该再出现之前那种 `IBUS-CRITICAL` / `No engine is set`。

最终还是以 GUI 实测为准：在微信开发者工具输入框里能弹候选词并上屏中文，才算彻底通了。  
如果你重启后愿意，我可以继续帮你现场验一次结果。

---

**User**

这次成功了，请输出一份markdown总结文档

---

**Cursor**

我先看一下仓库里的文档目录和命名风格，然后新增一份简洁的 Markdown 总结，方便后续复用。

我看一眼现有文档格式，尽量保持和仓库里的说明风格一致。

我新增一份独立总结文档，内容会覆盖问题现象、排查结论、最终方案和验证方式。

文档已经加上了，我再做一个快速检查，确认没有明显格式问题。

总结文档已生成：`docs/docker-ibus-input-method.MD`

文档包含了：
- 问题背景和现象
- 排查过程中的关键结论
- 最终生效的修改点
- 验证命令与 GUI 验证方法
- 后续排障注意事项

如果你愿意，我还可以顺手把这份文档在 `README.MD` 里加一个入口链接。

