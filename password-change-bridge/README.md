# password-change-bridge

让实验室成员自助修改自己的 lldap 密码，不需要旧密码，也没有邮件/验证码步骤——因为默认场景
（Authelia 自带的 Change Password 功能）在这里走不通，见下文。

## 为什么需要这个东西

Authelia 自带一个改密码功能，但要求"会话提升"（session elevation），会给账号邮箱发一次性验证码；
lldap 里每个成员的邮箱地址通常是随便填的占位符（不是真实可收信的邮箱），验证码永远收不到，会把人
卡死在那个流程里，所以生产部署里直接把它关掉了
（`authentication_backend.password_change.disable: true`）。

lldap 自己也有一个支持免验证码改密码的网页，但它是个假设部署在域名根路径（`/`）的编译产物（WASM
前端），和 ccwebsite 已经占用了根路径冲突，不方便直接暴露出来。

于是这个服务复用 lldap 官方自带的 `lldap_set_password` 命令行工具（管理员平时改密码用的同一个
工具，走 OPAQUE 协议，不是明文改库）,只做一件事：把已登录用户自己的密码改成新值。

## 工作原理

- 只监听 `127.0.0.1`，只能通过 nginx 到达；nginx 的 `auth_request` 网关保证到这里的请求都已经过
  Authelia 验证，并把验证过的身份写进 `Remote-User`/`Remote-Name` 请求头（客户端自己带的同名头会
  被网关覆盖，没法伪造）——这个服务无条件信任这两个头，只允许改**当前登录用户自己**的密码,不接受
  改别人密码的请求。
- `GET /` 返回一个改密码的简单表单（新密码 + 确认新密码，不问旧密码）。
- `POST /` 校验两次输入一致、长度 ≥ 8 位，然后调用 `lldap_set_password --username <当前登录用户>
  --password <新密码>`，用一个专用的 lldap 服务账号鉴权。
- 用户入口是 `https://<域名>/account/`，`server_info`/`weekly_report` 的"修改密码"按钮都直接链到
  这里（对 SSO 登录的用户；非 SSO 的独立部署走各自应用自己的改密码表单，不经过这里）。

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `LLDAP_BASE_URL` | lldap 的内部地址，默认 `http://lldap:17170`（podman 网络内部容器名）。 |
| `LLDAP_ADMIN_USERNAME` | **不是真正的 lldap 管理员**，是一个专门为这个服务建的、仅有"重置密码"权限（`lldap_password_manager` 组）的服务账号，实际部署里叫 `password-bridge-svc`。变量名沿用了 `lldap_set_password` 工具本身的命名习惯，容易让人误以为要填全量 admin，注意区分。 |
| `LLDAP_ADMIN_PASSWORD` | 上面这个服务账号的密码，由 `../deploy-bundle/scripts/00-generate-secrets.sh` 生成（`PASSWORD_BRIDGE_LDAP_PASS`），`04-bootstrap-lldap.sh` 负责把 lldap 里这个账号的实际密码同步成这个值。 |
| `LLDAP_SET_PASSWORD_BIN` | `lldap_set_password` 二进制的路径，默认 `/usr/local/bin/lldap_set_password`（`Containerfile` 里直接从 lldap 官方镜像 `COPY --from` 出来的，不需要手动安装）。 |
| `PORT` / `HOST` | 监听端口/地址，默认 `8095` / `0.0.0.0`（容器内必须 `0.0.0.0`，真正的访问限制由 podman 的 `-p 127.0.0.1:...` 提供）。 |

## 为什么这个服务账号改不了管理员的密码

`password-bridge-svc` 只在 `lldap_password_manager` 组里，不在 `lldap_admin` 组——lldap 对这种
范围受限的账号会拒绝它去改一个 `lldap_admin` 组成员的密码（实测返回 401）。也就是说，就算这个服务
本身被攻破，攻击者也改不了任何管理员账号的密码，影响面止步于普通成员账号。**这也意味着管理员自己
的账号不能通过 `/account/` 自助改密码**，需要用真正的 lldap 管理员账号登录 lldap 管理后台
（`http://localhost:8091/` via SSH 隧道，见 `../deploy-bundle/README.md`）手动改。

## 本地开发 / 单独测试

```bash
LLDAP_BASE_URL=http://localhost:17170 \
LLDAP_ADMIN_USERNAME=password-bridge-svc \
LLDAP_ADMIN_PASSWORD=<该服务账号密码> \
node server.js
```

需要 lldap 本身在跑，且 `lldap_set_password` 二进制在 `PATH` 里或用
`LLDAP_SET_PASSWORD_BIN` 指定路径（本地没有 lldap 官方镜像里那个二进制的话，从
`docker.io/lldap/lldap:stable` 镜像里 `podman cp` 一份出来即可，`Containerfile` 里的
`COPY --from=lldapbin` 就是这么做的）。
