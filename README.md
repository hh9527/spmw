# spmw

Simple Package Manager for Windows.

`spmw` 是配置驱动的极简包管理器，用于个人 Windows 工作环境的可重复搭建。
它负责下载输入、解析变量、生成计划、安装 package，并激活 links、shortcuts、
fonts、registry 等资源。

## 定位

- 配置驱动的极简包管理。
- 用于个人工作环境的可重复搭建。
- 不追求通用软件仓库；更适合管理自己的常用工具和配置。

## 特性

- 可被组合复用：配置以 source 形式组织，可以分享，也可以按顺序叠加。
- 声明式：在 `config.spmw.json` 中声明 packages、links、shortcuts。
- 适用于绿色软件、字体、简单命令行工具和个人配置文件。
- 可重复：`update` 生成“将是”状态，`install` 按计划安装和激活。

## 用法

### 开始

在 PowerShell 中执行：

```powershell
irm "https://github.com/hh9527/spmw/releases/latest/download/bootstrap.ps1" | iex
```

如果需要让 bootstrap 入口也走 curl 代理环境变量：

```powershell
((curl.exe -fL "https://github.com/hh9527/spmw/releases/latest/download/bootstrap.ps1") -join "`n") | iex
```

bootstrap 会安装最小 `source.spmw`，并把 `spmw-cli.ps1` 挂载到
`~/.local/bin`。它也会确保 `~/.local/bin` 位于用户级 `Path` 中。

### 更新

```powershell
spmw-cli.ps1 update
spmw-cli.ps1 install
```

`update` 从 `~/sources.spmw.json` 解析 sources，生成
`~/.spmw/state/next-plan.json`。`install` 安装该计划并激活外部资源。

### 加入其他源

例如加入一个 GitHub 配置仓：

```powershell
spmw-cli.ps1 source add main gh-src:OWNER/REPO/main
spmw-cli.ps1 update
spmw-cli.ps1 install
```

例如加入 `windows-config`：

```powershell
spmw-cli.ps1 source add main gh-src:hh9527/windows-config/main
spmw-cli.ps1 update
spmw-cli.ps1 install
```

也可以加入一个 HTTP release source：

```powershell
spmw-cli.ps1 source add tools https://example.com/spmw/tools/latest
```

source 按 `~/sources.spmw.json` 中的顺序合并；后面的 source 覆盖前面的同名
`packages`、`links`、`shortcuts`。

### 定义自己的源

source 是一个能提供 `config.spmw.json` 的 package object。最常见方式是创建
一个 GitHub 仓库，并在仓库根目录放置 `config.spmw.json`：

```json
{
  "schema": 2,
  "packages": {
    "ripgrep": {
      "defs": [
        { "version": "14.1.1" }
      ],
      "install": [
        {
          "action": "Unpack",
          "src": "https://github.com/BurntSushi/ripgrep/releases/download/<version>/ripgrep-<version>-x86_64-pc-windows-msvc.zip",
          "strip": 1
        }
      ]
    }
  },
  "links": {
    "bin:rg.exe": "pkgs.ripgrep:rg.exe"
  }
}
```

然后加入这个源：

```powershell
spmw-cli.ps1 source add main gh-src:OWNER/REPO/main
```

source config 内可以用 `pkgs.source:<path>` 引用承载当前 config 的 source
package object，例如：

```json
{
  "links": {
    "user:.wezterm.lua": "pkgs.source:user/.wezterm.lua"
  }
}
```

## 命令

- `source add <name> gh-src:<OWNER>/<REPO>/<BRANCH>`：追加或更新 GitHub source archive source。
- `source add <name> http(s)://<BASE>/<VERSION>`：追加或更新 HTTP release source。
- `update`：解析 sources，推进 `next-plan.json`。
- `install`：安装 next plan 并激活。
- `install -Prepare`：只准备对象，不激活。
- `prune`：回收不再使用的对象和 managed resources。可用 `-Pkgs`、`-Fonts`、`-Cache` 限定范围。

## 状态

- `~/sources.spmw.json`：本机 source authority。
- `~/.spmw/state/next-plan.json`：当前“将是”计划。
- `~/.spmw/state/lock.json`：当前“应是”状态。
- `~/.spmw/object/`：downloads、package objects、font objects。
- `~/.local/bin`：默认命令挂载目录。

## 代理

下载统一使用 `curl.exe`，因此会尊重 curl 的标准代理环境变量：

```powershell
$env:ALL_PROXY = "socks5h://127.0.0.1:1080"
$env:NO_PROXY = "127.0.0.1,localhost"
```

## 本地开发

生成 dev 分发产物：

```bash
scripts/make-dist.sh dev
python3 -m http.server 10922 --bind 127.0.0.1 --directory dev-dist
```

Windows 侧：

```powershell
$env:SPMW_SOURCE_URL = "http://127.0.0.1:10922/spmw/latest"
irm "http://127.0.0.1:10922/latest/bootstrap.ps1" | iex
```

dev 模式会生成：

- `dev-dist/latest/spmw.tar.gz`
- `dev-dist/latest/spmw.tar.gz.sha256`
- `dev-dist/latest/VERSION.txt`
- `dev-dist/latest/bootstrap.ps1`
- `dev-dist/unrelease-<hash9> -> latest`
- `dev-dist/spmw -> .`

## 发布

推送 version tag 会发布 release assets：

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions 会上传：

- `spmw.tar.gz`
- `spmw.tar.gz.sha256`
- `VERSION.txt`
- `bootstrap.ps1`
