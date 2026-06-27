# spmw

Simple Package Manager for Windows.

`spmw` 是能力层：负责下载包输入、解析变量、生成 plan、安装 package，并激活 links、shortcuts、fonts、registry 等资源。用户配置和包配置不放在这个仓库里，而是通过特殊的 `main` package 同步。

## 目录结构

- `bin/spmw-cli.ps1`：Windows CLI。
- `tws/config.spmw.json.txt`：生产环境 bootstrap 配置模板。
- `tws/dev-config.spmw.json.txt`：本地开发 bootstrap 配置模板。
- `tws/bootstrap.ps1`：用于 `irm ... | iex` 的 bootstrap 脚本。
- `tws/pack-tarballs.sh`：在 `target/` 下生成本地 tarball。
- `tws/serve.py`：本地开发时用于服务 `target/`。
- `.github/workflows/release.yml`：基于 version tag 构建 release assets。

运行时状态固定在：

- `~/.config.spmw.json`：本地 bootstrap 配置。
- `~/.spmw`：object store、plan、downloads、package objects 和临时目录。

## Bootstrap

生产配置使用 GitHub：

- `spmw`：先读取 latest release 的版本号，再下载该版本对应的不可变 release assets。
- `main`：先从 `windows-config` 的 Atom feed 读取最新 commit，再下载该 commit 对应的 source tarball。

本地开发时，先在 Linux 侧服务 `target/`：

```bash
tws/pack-tarballs.sh
python3 tws/serve.py --host 127.0.0.1 --port 10922
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

- `update`：解析配置和变量，写入 `~/.spmw/state/next-plan.json`。
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

生产配置先读取：

- `https://github.com/hh9527/spmw/releases/latest/download/VERSION.txt`

然后使用具体版本的稳定 URL 下载和校验：

- `https://github.com/hh9527/spmw/releases/download/<version>/tarball.tar.gz`
- `https://github.com/hh9527/spmw/releases/download/<version>/sha256.txt`
