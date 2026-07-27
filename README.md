# sdicweb

实验室 web 基础设施的总仓库（umbrella repo）。

## 目录结构

技术栈彼此独立、有独立提交历史的项目，作为 **git submodule** 接入：

- `ccwebsite/` — 实验室官网（Astro/Node），远程：`https://sdic.sjtu.edu.cn/git/ccwebsite.git`
- `weekly_report/` — 周报系统（FastAPI + React），远程：`git@github.com:CassiusBlackX/weekly_report.git`
- `server_info/` — 服务器信息文档站（Express/EJS），远程：`git@github.com:CassiusBlackX/server_info.git`

代码量很小、不值得单开仓库的胶水代码，直接作为普通文件放在根目录下：

- `galene-auth-bridge/` — Galene 的 SSO 认证桥接（JWT `authServer`）
- `galene-patch/` — Galene 静态资源 / 前端补丁
- `password-change-bridge/` — 修改密码的桥接服务
- `deploy-bundle/` — 部署脚本、nginx 配置模板、镜像打包（生产环境的密钥、渲染后的配置、运行数据不入库，见其中的 `.gitignore`）

以下目录是第三方服务的运行时状态或下载的构建工具，**不进版本控制**（见根目录 `.gitignore`）：

- `authelia/`、`galene/`、`lldap/` — 各服务自己的配置密钥、SQLite 数据库、录制文件、成员目录数据等运行时状态；需要时用 `deploy-bundle/` 里的脚本从零生成/部署
- `build-src/`、`nginx-1.31.2/` — 下载的第三方源码，非本项目代码，需要时重新拉取即可

## 克隆 / 更新

**submodule 的内容不会随普通 clone/pull 自动拉取，必须显式初始化更新，否则子目录会是空的或停留在旧的 commit。**

首次克隆：

```bash
git clone --recurse-submodules <this-repo-url>
```

如果已经用普通 `git clone` 或忘了加参数：

```bash
git submodule update --init --recursive
```

之后每次 `git pull` 完，如果确认某个子项目在其自己的远程有了新的提交、想把 umbrella repo 里记录的指针也更新到最新：

```bash
cd ccwebsite   # 或 weekly_report / server_info
git pull origin main
cd ..
git add ccwebsite
git commit -m "bump ccwebsite submodule"
```

（单独在子目录里改动、提交，需要 push 到子项目自己的远程；umbrella repo 这边只记录“指向哪个 commit”，需要额外 `git add` + commit 才会更新这个指针。）
