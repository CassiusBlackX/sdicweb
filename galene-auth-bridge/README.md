# galene-auth-bridge

给 [galene](https://galene.org/)（视频会议）用的一个极简网关：把 Authelia 已经验证过的身份签成一个
短期 JWT，让参会者在会议里显示的名字必须是 SSO 里的真实姓名，改不了、也冒充不了别人。

## 工作原理

1. 用户访问 `/meetings/` 下的某个房间，先经过 nginx 的 `auth_request` / Authelia 网关，只有登录
   用户才能到这一步。
2. galene 前端按房间配置里的 `authServer` 字段（指向 `/meetings-auth`，最终由 nginx 转发到这个
   服务），把请求发到这里，同时带上 nginx 转发的 `Remote-User`/`Remote-Name` 请求头（已验证身份，
   见 `src/middleware/auth.js` 类似的信任模型——这个服务同样只监听 `127.0.0.1`，只能通过 nginx
   到达，因此无条件信任这两个头是安全的）。
3. 本服务用房间号 + 用户名签一个 60 秒有效期的 HS256 JWT（`sub` 字段就是真实姓名，`aud` 绑定到
   具体房间），galene 用房间配置里同一个密钥（`authKeys`）验证这个 JWT，验证通过后参会者的显示
   名字就被锁定成了 JWT 里的 `sub`，客户端 JS 传的任何用户名参数都不会被采用。

## 环境变量

| 变量 | 说明 |
| --- | --- |
| `GALENE_JWT_SECRET` | 签名密钥，base64url 编码。**必须和 galene 每个房间配置文件（`rendered/galene/groups/*.json`）里 `authKeys[0].k` 的值完全一致**，否则 galene 验签会失败，参会者进不去房间。 |
| `GALENE_AUD_HOST` | 签发的 JWT 里 `aud` 字段用的域名，要和实际访问域名一致（默认 `sdic.sjtu.edu.cn`）。 |
| `PORT` | 监听端口，默认 `8090`。 |
| `HOST` | 默认 `0.0.0.0`（容器内必须如此，真正的访问限制由 podman 的 `-p 127.0.0.1:...` 提供）。 |

## 怎么改 / 轮换密钥

`GALENE_JWT_SECRET` 由 `../deploy-bundle/scripts/00-generate-secrets.sh` 统一生成，写在
`secrets.env` 里；`01-render-configs.sh` 会把同一个值同时写进：

- `rendered/galene-auth-bridge.env`（这个服务自己用）
- `rendered/galene/groups/room0.json` ~ `room3.json`（galene 每个房间用来验签）

**这两处必须始终保持一致**，所以如果要单独轮换这个密钥（不太必要，除非怀疑泄露），不要只改
`galene-auth-bridge.env`：要么整体重新跑一遍 `01-render-configs.sh`（会连带重新渲染其他所有服务
的配置，其他服务不受影响，只是文件会被覆盖重写成相同内容），要么手动同步改这两处文件，改完都要
重启对应容器（`podman restart galene-auth-bridge galene`）才生效。

## 本地开发 / 单独测试

```bash
GALENE_JWT_SECRET=$(openssl rand -base64 32 | tr -d '=' | tr '/+' '_-') \
GALENE_AUD_HOST=localhost \
node server.js
```

没有任何依赖（纯 Node 内置 `http`/`crypto`），可以直接跑，不需要 `npm install`。
