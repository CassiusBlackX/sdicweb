# galene-patch

给上游 [galene](https://galene.org/) 视频会议镜像打的两个静态文件补丁，让 SSO 登录状态和会议室里的
"退出登录"按钮行为一致。不是一个独立运行的服务，只是一个在 galene 镜像基础上再叠一层的
`Containerfile`。

## 补丁内容

- `galene.html` —— 上游原版页面，这里的版本只多了一行 `<script>` 标签，加载下面这个文件。
- `sso-logout-hook.js` —— galene 自带的"退出登录"按钮（`#disconnectbutton`，来自 `galene.js`）
  原本只会断开当前这一路会议的 WebSocket 连接，不会动 Authelia 的登录会话，导致退出后立刻重新进
  任意房间都会用同一个身份"秒重连"，看起来完全没有真正登出。这个补丁给按钮再加一个事件监听（不
  替换 galene 自己的处理逻辑，那个仍然会先执行、正常断开会议），额外调用
  `/authelia/api/logout` 结束真正的 SSO 会话，再跳转回 `/meetings/`。

## 什么时候需要重新打这个补丁

**每次上游 galene 镜像重新构建/更新之后**（比如升级 galene 版本、改了原版 `galene.html` 之类），
必须重新执行下面的步骤，否则跑的还是没打补丁的旧内容。

```bash
# 1. 确保未打补丁的上游镜像已经加载/构建为 localhost/galene-sdic:latest
podman images | grep galene-sdic

# 2. 在这个目录下重新构建，直接覆盖同一个 tag
cd galene-patch
podman build -t localhost/galene-sdic:latest .

# 3. 验证补丁生效（能在容器里看到多出来的 <script> 标签）
podman run --rm --entrypoint cat localhost/galene-sdic:latest /galene/static/galene.html | grep sso-logout-hook
```

打完补丁之后的 `localhost/galene-sdic:latest` 就是最终要导出、放进
`../deploy-bundle/images/galene-sdic.tar.gz` 的镜像（`podman save`），部署脚本
（`../deploy-bundle/scripts/02-load-images.sh` 之后的 `05-start-rest.sh`）直接假设这个 tag
已经是打过补丁的版本，不会在生产服务器上重复这一步。

## 如果 galene 前端还有别的行为需要改

思路一样：改 `galene.html`（引入新脚本 / 内联改动）或者加新的 JS 文件，在 `Containerfile` 里加一行
`COPY`，然后按上面的步骤重新构建、重新打包。
