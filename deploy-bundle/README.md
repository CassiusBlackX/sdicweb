# SDIC 实验室服务 — 生产部署包

包含 `ccwebsite`（纯静态站点，不在本包内，继续用它自己的 `deploy.sh`）之外的所有动态服务：
`server_info`、`weekly_report`、`galene`（视频会议）、`galene-auth-bridge`（会议真实姓名网关）、
`Authelia`（统一登录网关）、`lldap`（成员目录 / 管理后台）。

全部以 podman 镜像交付；member（实验室成员）只需要一套 lldap 账号密码即可登录三个应用；
管理员在 lldap 网页里增删成员即可，不用碰任何一个服务本身。

## 管理员常见操作速查

| 要做什么 | 在哪看 |
| --- | --- |
| 新生入学 / 毕业，增删成员账号 | 本文「日常管理成员」一节 |
| 成员忘记密码 / 自助改密码 | 本文「日常管理成员」一节（`/account/`） |
| 管理员自己的密码 | lldap 管理后台（SSH 隧道），本文「日常管理成员」一节 |
| 换 server_info 的 SMTP 发信邮箱 / 收信邮箱 | 本文「编辑通知邮件（server_info）」一节 |
| 修改实验室官网内容（学生/教师信息、新闻、论文） | `../ccwebsite/README.md` |
| 推送官网改动到线上 | `../ccwebsite/README.md`「推送到生产」 |
| weekly_report 用户管理（停用/删除/改角色/重置密码） | `../weekly_report/README.md`「管理员操作」 |
| weekly_report 定时开启本周填报 | `../weekly_report/README.md`「管理员操作」 |
| 新增 / 修改 galene 会议室 | 本文「galene 会议室」一节 |
| 轮换 galene 会议室的 JWT 密钥 | `../galene-auth-bridge/README.md` |
| galene 升级后重新打 SSO 补丁 | `../galene-patch/README.md` |
| 备份 / 灾难恢复需要留哪些文件 | 本文「备份 / 灾难恢复」一节 |
| 重启某个服务 / 看日志 | 本文「重启单个服务」一节 |

## 目录结构

```
images/     6 个 podman 镜像的 .tar.gz（server-info、weekly-report、galene-auth-bridge、
            authelia、lldap 是全新构建/拉取的；galene-sdic.tar.gz 是你之前已经构建好的 galene 镜像）
scripts/    按编号顺序执行的部署脚本
nginx/      生产 nginx 要 include 的配置片段
```

## 前置条件（在你的公网 nginx 服务器上）

1. **podman** 已安装。
2. **nginx 必须编译/打包了 `http_auth_request_module`**，否则 `auth_request` 指令会直接报
   "unknown directive" 导致 nginx 启动失败。检查：
   ```
   nginx -V 2>&1 | grep -o with-http_auth_request_module
   ```
   没有输出就说明缺这个模块 —— 大多数发行版的 `nginx-full`/`nginx-extras` 包或
   nginx.org 官方 APT/YUM 仓库的包都自带；如果你用的是精简版 nginx，需要换成带这个模块的
   版本（或重新编译加上 `--with-http_auth_request_module`）。
3. 域名 `sdic.sjtu.edu.cn` 的 HTTPS 由学校网关处理，转发到这台机器的 80 端口 —— 和你之前的
   架构一致，这里不需要改。

## 部署步骤

```bash
# 1. 把整个 deploy-bundle 目录 scp 到生产服务器，例如放在 ~/sdicweb-deploy
scp -r deploy-bundle youruser@your-nginx-server:~/sdicweb-deploy
ssh youruser@your-nginx-server
cd ~/sdicweb-deploy
chmod +x scripts/*.sh

# 2. 生成这套部署专用的密钥（不要复用开发机上的任何密钥）
./scripts/00-generate-secrets.sh

# 3. 渲染配置文件 —— ADMIN_USERNAME 就是你要设的、不叫 "admin" 的管理员账号名
#    （日常登录 lldap 管理后台、以及自动成为 weekly_report 的第一个 admin 角色，都是这个用户名）
#    想要 server_info 在有人编辑内容时发邮件通知，再加上 SERVER_INFO_SMTP_* 几个变量，
#    见下面"编辑通知邮件"一节。
ADMIN_USERNAME=你的真实用户名 DOMAIN=sdic.sjtu.edu.cn ./scripts/01-render-configs.sh

# 4. 导入全部镜像
./scripts/02-load-images.sh

# 5. 先起 lldap
./scripts/03-start-lldap.sh
sleep 5

# 6. 初始化 lldap（建 lab 分组 + Authelia 用的服务账号）
ADMIN_USERNAME=你的真实用户名 ./scripts/04-bootstrap-lldap.sh

# 7. 起其余所有服务
./scripts/05-start-rest.sh

# 8. 配置 nginx
sudo cp nginx/sdic-services.conf /etc/nginx/sdic-services.conf
# 在你现有的 80 端口 server {} 块里加一行:
#   include /etc/nginx/sdic-services.conf;
sudo nginx -t && sudo systemctl reload nginx
```

完成后访问 `https://sdic.sjtu.edu.cn/server_info/`、`/weekly_report/`、`/meetings/` 应该都会跳转到
Authelia 登录页；未登录时 `https://sdic.sjtu.edu.cn/`（ccwebsite）保持公开。

## 关于管理员账号（不叫 "admin"）

第 3 步的 `ADMIN_USERNAME` 直接决定了 lldap 的初始管理员用户名 —— **这套部署自始至终都
不会创建名为 `admin` 的账号**，`01-render-configs.sh` 甚至会直接拒绝你把它设成 `admin`。
这就是你要的"不能直接用 admin"。

同一个用户名也被写进了 `weekly_report` 的 `ADMIN_USERNAME` 环境变量 —— 这样你第一次用这个
账号通过 SSO 登录 `weekly_report` 时，会直接落在一个预置好的 `role=admin` 记录上，不需要再
手动改数据库提权。`server_info` 没有管理员/普通用户的区别（所有登录用户权限一致），不需要
额外处理。

## 日常管理成员（新生入学 / 毕业）

lldap 的管理网页固定只监听 `127.0.0.1:17170`，**没有**接到公网 nginx 里 —— 管理面板不应该
挂在公网上，哪怕加了 SSO 也是不必要的攻击面。用 SSH 隧道访问：

```bash
ssh -L 8091:127.0.0.1:17170 youruser@your-nginx-server
```

然后浏览器打开 `http://localhost:8091/`，用你在第 3 步设置的管理员账号登录。

- **新增成员**：Users → Create user，设置用户名/邮箱/密码，然后把它加进 `lab` 分组。
  加完之后这个人立刻可以用这套用户名密码登录 `server_info`、`weekly_report`、`meetings`
  三个服务，全程不需要你再碰这三个服务本身。
- **删除成员**（毕业等）：Users → 选中该用户 → Delete。新登录立刻被拒绝；已经登录的旧会话
  最长约 5 分钟后失效（Authelia 对 LDAP 目录的刷新间隔，不是漏洞，是大多数 SSO 系统的常见
  行为）。
- **成员自己改密码**：不用找你 —— 访问 `https://sdic.sjtu.edu.cn/account/`（`server_info`/
  `weekly_report` 的"修改密码"按钮都直接链到这里），输入新密码两次直接生效，不需要旧密码，
  也不会有任何邮件/验证码步骤。**不要**引导成员去 Authelia 门户自带的 Change Password——那个
  功能已经在配置里关掉了（`authentication_backend.password_change.disable: true`），原因是
  它强制要求"会话提升"，会给账号邮箱发一次性验证码，而成员账号的邮箱地址通常是随便填的占位符，
  验证码永远收不到，会把人卡死。`/account/` 背后是 `password-change-bridge`，直接复用 lldap
  自带的 `lldap_set_password` 工具，用一个仅有"重置密码"权限（不是完整管理员）的专用服务账号
  `password-bridge-svc` 来改目标用户自己的密码，不涉及邮件。

## 编辑通知邮件（server_info）

`server_info` 里有人修改共享内容时会给管理员发邮件，这个功能是它本来就有的，由两组变量控制
（都在渲染出来的 `rendered/server_info.env` 里）：

- `ADMIN_EMAIL` —— 收件地址。默认等于 `SERVER_INFO_ADMIN_EMAIL`（不单独设的话又默认等于
  `ADMIN_EMAIL`，也就是你的管理员登录邮箱），可以单独指定成别的地址。
- `SMTP_HOST` / `SMTP_PORT` / `SMTP_SECURE` / `SMTP_USER` / `SMTP_PASS` / `SMTP_FROM` ——
  实际发信要用的 SMTP 账号。这组不填的话，`server_info` 只会在日志里打一行警告，不会真的
  发邮件（不影响正常使用，只是不通知）。

### 只改这一项配置（推荐，日常场景）

已经部署好、只是想换一个 SMTP 账号或收件邮箱：**直接改 `~/sdicweb-deploy/rendered/server_info.env`
这一个文件，再重启这一个容器就行**，不要重新跑整个 `01-render-configs.sh`（原因见下面的踩坑记录）：

```bash
cd ~/sdicweb-deploy
vim rendered/server_info.env   # 改 ADMIN_EMAIL / SMTP_HOST / SMTP_PORT / SMTP_SECURE / SMTP_USER / SMTP_PASS / SMTP_FROM
chmod 600 rendered/server_info.env

podman rm -f server-info
podman run -d --name server-info \
  --restart unless-stopped \
  --network sdicnet \
  -p 127.0.0.1:3000:3000 \
  --env-file rendered/server_info.env \
  -v server_info_data:/app/data:Z \
  localhost/server-info:latest
```

改完建议实际发一封测试邮件验证（比直接等真实编辑触发靠谱）：

```bash
podman exec server-info node -e "
require('/app/src/mailer').notifyDocumentEdited({
  editor: { display_name: '测试', username: 'test' },
  diff: 'test diff',
  editedAt: new Date().toISOString(),
}).then(r => console.log(r));
"
```
看到 `{ sent: true }` 就是成功了；`sent: false` 的话 `reason` 字段会说明原因（`no-admin-email` /
`no-smtp` / `send-error`，后者会带 `error.message`，常见的是密码错、或者 SMTP 服务商需要"授权码"
而不是登录密码）。

改完别忘了同步更新 `secrets.env` 里对应的几行（见下一节），不然下次做灾难恢复、从零全量渲染时，
这次改的值会丢。

### 全量重新渲染（`01-render-configs.sh`，仅用于首次部署 / 灾难恢复）

`01-render-configs.sh` 会读 `secrets.env`（`source secrets.env`）里的
`SERVER_INFO_ADMIN_EMAIL` / `SERVER_INFO_SMTP_*`，所以只要这几个值已经写进了 `secrets.env`
（见下一节），直接：

```bash
ADMIN_USERNAME=你的真实用户名 ./scripts/01-render-configs.sh
podman restart server-info
```

就会带上正确的 SMTP 配置，不需要每次在命令行上重新敲一遍那一长串变量。

> **踩坑记录**：`01-render-configs.sh` 是"全量重新渲染"——它会**无条件重新生成**
> `rendered/weekly_report.env` 里的 `ADMIN_PASSWORD`（`openssl rand` 现场生成的随机值，不是从
> `secrets.env` 读的），也会重写 nginx / Authelia / galene 的配置文件。生产环境下 `weekly_report`
> 的真实管理员登录早就切到 SSO 了（见 `../weekly_report/README.md`），这个字段基本是废弃的初始
> 引导密码，所以实际影响不大；但如果你的部署还没切 SSO、还在用这个密码登录，全量重新渲染会在你
> 没注意到的情况下把它换掉。这就是为什么上面"只改这一项"的直接编辑法是日常场景下更安全的选择——
> 全量渲染只在第一次部署或者需要从 `secrets.env` 灾难恢复整套配置时才用。

### 让这几个值在灾难恢复时也不丢：写进 `secrets.env`

`secrets.env` 本来只存"随机生成的密钥"，SMTP 账号是外部提供的、不是生成的，所以
`00-generate-secrets.sh` 不会自动写这几行。想让它们在全量重新渲染时也生效，手动追加到
`secrets.env` 末尾（该文件已经是 `chmod 600`，只有部署账号自己能读）：

```bash
cat >> ~/sdicweb-deploy/secrets.env <<'EOF'

# 非随机生成，是外部提供的真实 SMTP 账号，手动记录以便灾难恢复时全量渲染不丢失。
SERVER_INFO_ADMIN_EMAIL=cassiusx@qq.com
SERVER_INFO_SMTP_HOST=mail.hust.edu.cn
SERVER_INFO_SMTP_PORT=465
SERVER_INFO_SMTP_SECURE=true
SERVER_INFO_SMTP_USER=u202215479@hust.edu.cn
SERVER_INFO_SMTP_PASS=你的SMTP密码或授权码
SERVER_INFO_SMTP_FROM=u202215479@hust.edu.cn
EOF
```

## galene 会议室

- 4 个默认房间 `room0`～`room3` 的密码框已经完全失效（`authServer`/`authKeys` 机制），进
  `/meetings/` 之前必须先过 Authelia 登录；登录后显示的参会人名字强制是 SSO 里的真实用户名，
  没法冒充别人。
- 想加更多房间：在 `~/sdicweb-deploy/rendered/galene/groups/` 里照抄一份 `room0.json`
  改文件名和 `description`（`authServer`/`authKeys` 原样保留），galene 容器会在下次重启时
  读取新文件（或者看 galene 是否支持热加载分组目录，不确定的话 `podman restart galene`
  最保险）。

## 备份 / 灾难恢复

需要备份的状态：
- `~/sdicweb-deploy/secrets.env`（所有密钥，丢了要重新生成整套部署）
- `~/sdicweb-deploy/rendered/`（渲染后的配置，含密钥的明文副本）
- podman 卷 `server_info_data`、`weekly_report_data`（`podman volume export` 可以导出）
- `~/sdicweb-deploy/data/lldap`（成员目录数据库）
- `~/sdicweb-deploy/data/authelia`（如果你后续把 authelia 的 config 目录换成挂载卷而不是
  直接用 rendered/authelia，注意 db.sqlite3 在 rendered/authelia 下，也要备份）

## 重启单个服务

```bash
cd ~/sdicweb-deploy
podman restart lldap        # 或 authelia / server-info / weekly-report / galene / galene-auth-bridge
podman logs -f <容器名>      # 排查问题
```

## 修改配置后重新生效

改了 `rendered/` 下的任何文件后：
```bash
podman restart authelia     # Authelia 的 configuration.yml 不会热加载
podman restart server-info  # 或对应容器
```
