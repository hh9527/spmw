# spmw

Simple Package Manager for Windows.

`spmw` 是能力层：负责下载包输入、解析变量、生成 plan、安装 package，并激活 links、shortcuts、fonts、registry 等资源。用户配置和包配置不放在这个仓库里，而是通过特殊的 `main` package 同步。

## 目录结构

- `bin/spmw-cli.ps1`：Windows CLI。
- `scripts/make-dist.sh`：生成 release/dev 分发产物。
- `.github/workflows/release.yml`：基于 version tag 构建 release assets。

运行时状态固定在：

- `~/.spmw/state/next-plan.json`：当前计划游标。
- `~/.spmw`：object store、plan、downloads、package objects 和临时目录。

## Bootstrap

生产 bootstrap 入口在 `windows-config` 仓库中：

```powershell
irm "https://raw.githubusercontent.com/hh9527/windows-config/main/bootstrap.ps1" | iex
```

生产配置使用 GitHub：

- `spmw`：先读取 latest release 的版本号，再下载该版本对应的不可变 release assets。
- `main`：先从 `windows-config` 的 Atom feed 读取最新 commit，再下载该 commit 对应的 source tarball。

bootstrap 自身只下载 latest 的 `spmw` release tarball 作为启动器，展开到 `~/.spmw/bootstrap/`。随后它过滤配置，仅保留 `main`、`spmw` 和正式 CLI link，先用 bootstrap CLI 安装正式 `spmw-cli.ps1`，再切换到正式 CLI 完成完整配置安装。

本地开发时，可以生成 `spmw` 的 dev 分发产物：

```bash
scripts/make-dist.sh dev target
```

`dev` 模式会生成：

- `target/tarball.<sha256>.tar.gz`
- `target/sha256.txt`

`windows-config/bootstrap.ps1` 的 dev 模式还需要同一个 HTTP 根下存在 `bootstrap.ps1` 和 `config.spmw.json`。可以准备一个 staging 目录：

```bash
mkdir -p /tmp/spmw-bootstrap
cp target/tarball.*.tar.gz target/sha256.txt /tmp/spmw-bootstrap/
cp ../windows-config/bootstrap.ps1 ../windows-config/config.spmw.json /tmp/spmw-bootstrap/
python3 -m http.server 10922 --bind 127.0.0.1 --directory /tmp/spmw-bootstrap
```

如果只需要服务已有目录，也可以直接使用：

```bash
python3 -m http.server 10922 --bind 127.0.0.1 --directory target
```

如果 Windows 通过 SSH 访问 Linux，可以在 Windows 上建立本地端口转发：

```powershell
ssh -N -T -L 10922:127.0.0.1:10922 lq-2
```

然后在 Windows 上 bootstrap：

```powershell
$env:SPMW_DEV_HOST = "127.0.0.1:10922"
irm "http://127.0.0.1:10922/bootstrap.ps1" | iex
```

`SPMW_DEV_HOST` 同时也是 dev mode 信号：存在这个环境变量时，`update` 合并配置会采用本地优先。

## CLI

在 PowerShell 中运行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 update
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 install
powershell.exe -ExecutionPolicy Bypass -File .\bin\spmw-cli.ps1 prune
```

命令说明：

- `update`：从 `next-plan.json` 中的 `main.path` 推导入口配置，推进计划并写回 `~/.spmw/state/next-plan.json`。
- `update -Bootstrap <path>`：使用指定 bootstrap config 作为首次入口，生成第一版 `next-plan.json`。
- `install`：安装 next plan 并激活。
- `install -Prepare`：只准备/安装对象，不激活。
- `prune`：清理未使用对象。可用 `-Pkgs`、`-Fonts`、`-Cache` 限定范围。
- `update -Hack`：调试用，本地配置覆盖远端配置。

如果没有 `-Hack`，并且没有 `SPMW_DEV_HOST`，则默认远端 `main/config.spmw.json` 优先，覆盖本地同名的 `packages`、`links`、`shortcuts`。

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

- `tarball.tar.gz`
- `sha256.txt`
- `VERSION.txt`

也可以本地生成同样格式的 release 产物：

```bash
GITHUB_REF_NAME=v1.0.0 scripts/make-dist.sh release dist
```

生产配置先读取：

- `https://github.com/hh9527/spmw/releases/latest/download/VERSION.txt`

然后使用具体版本的稳定 URL 下载和校验：

- `https://github.com/hh9527/spmw/releases/download/<version>/tarball.tar.gz`
- `https://github.com/hh9527/spmw/releases/download/<version>/sha256.txt`
