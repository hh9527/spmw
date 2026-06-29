# spmw

Simple Package Manager for Windows.

`spmw` 是能力层：负责下载包输入、解析变量、生成 plan、安装 package，并激活 links、shortcuts、fonts、registry 等资源。配置来源由本地 `~/sources.spmw.json` 声明，每个 source 物化出一个 `config.spmw.json`。

## 目录结构

- `bin/spmw-cli.ps1`：Windows CLI。
- `bootstrap.ps1`：安装最小 `source.spmw` 并建立 spmw 自举闭环。
- `source/config.spmw.json`：`source.spmw` 的最小自管理配置。
- `scripts/make-dist.sh`：生成 release/dev 分发产物。
- `.github/workflows/release.yml`：基于 version tag 构建 release assets。

运行时状态固定在：

- `~/.spmw/state/next-plan.json`：当前计划游标。
- `~/.spmw`：object store、plan、downloads、package objects 和临时目录。
- `~/sources.spmw.json`：本机 source-ref authority。

## Bootstrap

生产 bootstrap 入口由本仓库 release asset 提供：

```powershell
irm "https://github.com/hh9527/spmw/releases/latest/download/bootstrap.ps1" | iex
```

如果需要让 bootstrap 下载入口也走 curl 代理环境变量，可以用：

```powershell
curl.exe -fL "https://github.com/hh9527/spmw/releases/latest/download/bootstrap.ps1" | iex
```

bootstrap 先下载临时 CLI，再用临时 CLI 添加 `source.spmw`、执行
`update` / `install`，随后切换到正式 `bin:spmw-cli.ps1` 再执行一次
`update` / `install`。
用户配置源不是 bootstrap 的一部分。bootstrap 完成后，可以添加自己的配置源：

```powershell
spmw-cli.ps1 source add main gh-src:OWNER/REPO/main
spmw-cli.ps1 update
spmw-cli.ps1 install
```

source 按 `~/sources.spmw.json` 中的顺序合并，后面的 source 覆盖前面的同名 `packages`、`links`、`shortcuts`。

本地开发时，可以生成 `spmw` 的 dev 分发产物：

```bash
scripts/make-dist.sh dev
```

`dev` 模式会生成：

- `dev-dist/latest/spmw.tar.gz`
- `dev-dist/latest/spmw.tar.gz.sha256`
- `dev-dist/latest/VERSION.txt`
- `dev-dist/latest/bootstrap.ps1`
- `dev-dist/unrelease-<hash9> -> latest`
- `dev-dist/spmw -> .`
- `dev-dist/bootstrap.ps1`

可以准备一个 staging 目录：

```bash
mkdir -p /tmp/spmw-bootstrap
cp -r dev-dist/latest dev-dist/unrelease-* /tmp/spmw-bootstrap/
cp dev-dist/bootstrap.ps1 /tmp/spmw-bootstrap/
python3 -m http.server 10922 --bind 127.0.0.1 --directory /tmp/spmw-bootstrap
```

如果只需要服务已有目录，也可以直接使用：

```bash
python3 -m http.server 10922 --bind 127.0.0.1 --directory dev-dist
```

如果 Windows 通过 SSH 访问 Linux，可以在 Windows 上建立本地端口转发：

```powershell
ssh -N -T -L 10922:127.0.0.1:10922 lq-2
```

然后在 Windows 上 bootstrap：

```powershell
$env:SPMW_SOURCE_URL = "http://127.0.0.1:10922/spmw/latest"
irm "http://127.0.0.1:10922/latest/bootstrap.ps1" | iex
```

也可以使用 curl 入口：

```powershell
$env:SPMW_SOURCE_URL = "http://127.0.0.1:10922/spmw/latest"
curl.exe -fL "http://127.0.0.1:10922/latest/bootstrap.ps1" | iex
```

本地 source 也可以显式写成：

```powershell
spmw-cli.ps1 source add spmw http://127.0.0.1:10922/spmw/latest
```

这种形式要求 HTTP 下存在 `/spmw/latest/VERSION.txt` 和对应 release assets，
适合一个 server 同时伺服多个 release 根。

## CLI

在 PowerShell 中运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 update
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 install
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 prune
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 source add main gh-src:OWNER/REPO/main
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 source add spmw https://github.com/hh9527/spmw/releases/download/latest
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 source add spmw http://127.0.0.1:10922/spmw/latest
```

命令说明：

- `source add <name> gh-src:<OWNER>/<REPO>/<BRANCH>`：向 `~/sources.spmw.json` 追加或更新 GitHub source archive source。
- `source add <name> http(s)://<BASE>/<VERSION>`：向 `~/sources.spmw.json` 追加或更新通用 HTTP release source。
- `update`：从 `~/sources.spmw.json` 解析 source，合并配置，推进计划并写回 `~/.spmw/state/next-plan.json`。
- `install`：安装 next plan 并激活。
- `install -Prepare`：只准备/安装对象，不激活。
- `prune`：清理未使用对象。可用 `-Pkgs`、`-Fonts`、`-Cache` 限定范围。

`update` 按 source 顺序合并远端 `config.spmw.json`，后面的 source 覆盖前面的同名 `packages`、`links`、`shortcuts`。

## 代理

下载统一使用 `curl.exe`，因此会尊重 curl 的标准代理环境变量：

```powershell
$env:ALL_PROXY = "socks5h://127.0.0.1:1080"
$env:NO_PROXY = "127.0.0.1,localhost"
```

建议使用 `socks5h://`，这样 DNS 解析也会在代理端完成。

## Release Assets

推送 version tag 会发布 `spmw` release assets：

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions 会创建 release，并上传：

- `spmw.tar.gz`
- `spmw.tar.gz.sha256`
- `VERSION.txt`
- `bootstrap.ps1`

也可以本地生成同样格式的 release 产物：

```bash
GITHUB_REF_NAME=v1.0.0 scripts/make-dist.sh release dist
```

生产 bootstrap 默认 source URL 是：

- `https://github.com/hh9527/spmw/releases/download/latest`

它先读取：

- `https://github.com/hh9527/spmw/releases/download/latest/VERSION.txt`

然后使用具体版本的稳定 URL 下载和校验：

- `https://github.com/hh9527/spmw/releases/download/<version>/spmw.tar.gz`
- `https://github.com/hh9527/spmw/releases/download/<version>/spmw.tar.gz.sha256`
- `https://github.com/hh9527/spmw/releases/latest/download/bootstrap.ps1`
