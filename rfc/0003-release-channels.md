# RFC 0003: Channel Tarball 指针

## 状态

草案。

本文定义 spmw 自身分发可以使用的轻量 channel 指针模型。本阶段只要求支持
`latest.txt` 和 `snapshot.txt`。

channel 文件只保存一个 tarball URL reference。客户端读取 channel 文件后，按
标准 URL resolve 规则得到最终 tarball URL，然后把这个 tarball 当作 source
package 解包。

## 背景

当前 HTTP release source 使用以下寻址模型：

```text
<BASE>/<VERSION>/VERSION.txt
<BASE>/<resolved-version>/spmw.tar.gz
<BASE>/<resolved-version>/spmw.tar.gz.sha256
```

这个模型适合有完整 release assets 的分发源，但对 spmw 自身偏重。spmw 的 source
package 很简单，仓库根目录已经包含 `config.spmw.json`，`bin/` 中包含 CLI。
GitHub 自动提供的 source archive 已经足够作为可安装 tarball。

因此，spmw 自身可以不再为 tag 发布额外 release assets。发布 workflow 只维护
GitHub Pages 上的 channel 指针：

```text
channels/latest.txt
channels/snapshot.txt
```

每个 channel 文件直接指向一个 tar.gz。

## 目标

- 只定义 `latest` 和 `snapshot` 两个 channel。
- channel 文件保存 tarball URL reference。
- URL reference 可以是绝对 URL、root-relative URL 或相对 URL。
- 使用 channel 文件 URL 作为 base，按标准 URL resolve 规则解析 tarball URL。
- `latest.txt` 指向稳定 tag 对应的 GitHub source archive。
- `snapshot.txt` 指向当前主开发分支 commit 对应的 GitHub source archive。
- 不要求 GitHub Release assets。
- 保持 update/install 的确定性边界：`update` 解析 channel，`install` 重放
  `next-plan.json`。

## 非目标

- 不定义 `rc` channel。
- 不定义 release assets、checksum assets 或 release manifest。
- 不改变 `gh-src:<OWNER>/<REPO>/<BRANCH>` source spec。
- 不定义 GitHub Pages 的具体启用方式；可以由 `gh-pages` 分支或 Pages deploy
  workflow 维护。
- 不为 GitHub source archive 提供独立 checksum。

## Channel 文件

channel 文件是一个文本文件。推荐路径：

```text
channels/latest.txt
channels/snapshot.txt
```

文件内容是 tarball URL reference。示例：

```text
https://codeload.github.com/hh9527/spmw/tar.gz/v1.2.3
```

也可以使用相对 URL：

```text
../archives/spmw-v1.2.3.tar.gz
```

解析规则：

- 读取 channel 文件文本。
- trim 首尾空白。
- 取结果作为 URL reference。
- 使用 channel 文件 URL 作为 base，按标准 URL resolve 规则解析。
- 解析结果必须是 `http` 或 `https` URL。
- 解析结果就是 source tarball URL。

channel 文件不保存 tag、commit SHA 或 release base。tag 和 commit SHA 由发布
workflow 展开到 tarball URL 中。

## 推荐内容

`latest.txt` 推荐在稳定 tag 推送时更新。例如推送 tag `v1.2.3` 后写入：

```text
https://codeload.github.com/hh9527/spmw/tar.gz/v1.2.3
```

`snapshot.txt` 推荐在主开发分支 push 时更新。例如 commit 为
`0123456789abcdef0123456789abcdef01234567` 时写入：

```text
https://codeload.github.com/hh9527/spmw/tar.gz/0123456789abcdef0123456789abcdef01234567
```

这样 `latest` 通过 tag 固定，`snapshot` 通过 commit SHA 固定。客户端不需要调用
GitHub API 解析 branch。

## Source Spec

HTTP URL source spec 表示 channel 文件：

```text
http(s)://<CHANNEL.txt>[#<config-rpath>]
```

示例：

```powershell
spmw-cli.ps1 source add spmw https://hh9527.github.io/spmw/channels/latest.txt
spmw-cli.ps1 source add spmw-snapshot https://hh9527.github.io/spmw/channels/snapshot.txt
spmw-cli.ps1 source add tools https://example.com/spmw/channels/latest.txt#path/to/config.spmw.json
```

`http(s)://<CHANNEL.txt>[#<config-rpath>]` 表示：

- URL 去掉 fragment 后是 channel 文件 URL。
- fragment 可选，表示 tarball 内的 `config.spmw.json` 相对路径。
- update 阶段读取该 URL。
- 文件内容解析为 tarball URL。
- tarball 被作为 source package 下载并解包。

对 spmw 自身，GitHub source archive 解包后有一层根目录，仓库根目录包含
`config.spmw.json`。因此 source-ref definition 概念上等价于：

```json
{
  "name": "source.<name>",
  "defs": [
    {
      "tarball-url": {
        "src": "<channel-url>",
        "ty": "UrlReference"
      }
    }
  ],
  "install": [
    {
      "action": "Unpack",
      "file": "spmw-<manifest-digest>.tar.gz",
      "src": "<tarball-url>",
      "strip": 1
    }
  ]
}
```

这里的 `UrlReference` 是一个新的变量 resolver type：

- 下载 `src` 文本。
- trim 得到 URL reference。
- 使用 `src` URL 作为 base 解析。
- 结果必须是 `http` 或 `https` URL。

`file` 可以由实现选择更稳定的名称。只要 `tarball-url` 已经解析进 variables，
`variable-digest` 就会随着 channel 目标变化而变化。

## Pages 布局

推荐使用同仓库的 `gh-pages` 分支维护 channel 指针：

```text
channels/
  latest.txt
  snapshot.txt
```

对应访问路径：

```text
https://hh9527.github.io/spmw/channels/latest.txt
https://hh9527.github.io/spmw/channels/snapshot.txt
```

发布 workflow 只更新目标 channel 文件，避免覆盖其他 channel。

## Workflow 约定

推荐 GitHub Actions 行为：

- 每一次 push 到主开发分支，都把当前 commit SHA 展开成 codeload tarball URL，
  写入 `channels/snapshot.txt`。
- 每一次推送稳定 tag，例如 `v1.2.3`，都把该 tag 展开成 codeload tarball URL，
  写入 `channels/latest.txt`。

示例：

```text
channels/latest.txt
  https://codeload.github.com/hh9527/spmw/tar.gz/v1.2.3

channels/snapshot.txt
  https://codeload.github.com/hh9527/spmw/tar.gz/0123456789abcdef0123456789abcdef01234567
```

## 与现有 HTTP Release Source 的关系

`gh-src` 继续保留：

```text
gh-src:<OWNER>/<REPO>/<BRANCH>
```

它适合直接跟随 GitHub branch 的配置仓。

HTTP URL source spec 不再表示 `<BASE>/<VERSION>` release source。它表示 channel
文件，channel 文件直接指向 tarball。spmw 自身优先使用该模型。

## 安全和确定性

channel 文件是可变输入，因此它只应决定 tarball URL。

`update` 读取 channel 后，应把解析出的 tarball URL 写入 variables，并写入
`next-plan.json`。后续 `install` 必须重放 `next-plan.json`，不能重新读取 channel
文件来改变本次安装。

GitHub source archive 暂不提供独立 checksum。为降低可变性：

- `latest.txt` 应指向 tag archive。
- `snapshot.txt` 应指向 commit SHA archive。
- channel 文件不应指向 branch archive。

## 后续问题

- 是否允许 `file:` channel URL 用于本地开发。
- bootstrap 默认入口是否迁移到 GitHub Pages `channels/latest.txt`。
- 是否需要在未来为 channel tarball 增加可选 checksum 文件。
