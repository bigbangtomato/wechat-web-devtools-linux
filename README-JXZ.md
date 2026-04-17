# Docker 容器启动问题处理记录

## 问题现象

在宿主机上执行：

```bash
docker start wechat-dev-tool
```

容器启动失败，Docker 报错类似：

```text
error mounting "/run/user/1000/gdm/Xauthority" to rootfs at "/tmp/.Xauthority"
```

## 根因分析

问题不是镜像构建失败，也不是容器入口脚本损坏，而是旧容器创建时绑定了一个已经不适用的 X11 鉴权文件路径：

```text
/run/user/1000/gdm/Xauthority
```

这个路径是旧图形会话环境遗留下来的路径，更偏向 `gdm` 场景。当前宿主机使用的是 `lightdm`，该路径后来已经不是可用的 Xauthority 文件，导致 Docker 在启动旧容器时，挂载阶段就直接失败。

## 为什么挂载到 `/tmp/.Xauthority`

本次修复后，容器使用的是：

- 宿主机源文件：`/home/joseph/.Xauthority`
- 容器内目标文件：`/tmp/.Xauthority`
- 环境变量：`XAUTHORITY=/tmp/.Xauthority`

这样做的原因如下：

1. `Xauthority` 的关键是“容器内程序能读到这份认证文件”，并不要求容器内路径必须和宿主机完全一致。
2. 容器内运行用户是 `user`，其家目录是 `/home/user`，不是 `/home/joseph`，因此没必要把宿主机用户名路径原样暴露到容器里。
3. `/tmp/.Xauthority` 是一个稳定且通用的容器内挂载目标，不依赖容器内是否存在 `/home/joseph` 目录。
4. 这种写法能避免脚本和宿主机用户名强耦合，换机器或换用户名时更稳。

所以本质上是把宿主机上的认证文件“映射”到容器内一个固定位置，然后让容器内程序通过 `XAUTHORITY` 去读取它。

## 本次处理过程

本次通过 `ssh self` 登录宿主机排查并处理，步骤如下：

1. 检查 `wechat-dev-tool` 容器状态，发现容器存在，但旧容器无法正常启动。
2. 复现 `docker start wechat-dev-tool`，确认报错发生在容器初始化挂载阶段。
3. 检查旧容器配置，确认它把宿主机的 `/run/user/1000/gdm/Xauthority` 绑定到了容器内 `/tmp/.Xauthority`。
4. 结合当前宿主机使用 `lightdm` 的事实，判断旧容器绑定的是失效路径。
5. 修改 `tools/run-wechat-devtools-docker.sh` 的 X11 鉴权文件选择逻辑，新增 `resolve_xauth()`，优先使用稳定的 `~/.Xauthority`，其次才使用当前会话里的 `XAUTHORITY`。
6. 按要求不保留旧容器备份，直接删除旧的 `wechat-dev-tool` 容器。
7. 使用修正后的脚本重新创建同名容器。
8. 检查新容器挂载，确认已经变为：

```text
/home/joseph/.Xauthority -> /tmp/.Xauthority
```

9. 执行 `docker stop wechat-dev-tool` 后再次 `docker start wechat-dev-tool`，确认容器可以正常启动。

## 最终结论

这次故障的根因是“旧容器绑定了不适用于当前 `lightdm` 环境的 Xauthority 路径”，不是镜像本身的问题。

修复方式是：

- 更新 `tools/run-wechat-devtools-docker.sh`
- 在 X11 场景下优先挂载宿主机的 `~/.Xauthority`
- 删除旧容器并重新创建

这样之后，`docker start wechat-dev-tool` 已可正常工作。
