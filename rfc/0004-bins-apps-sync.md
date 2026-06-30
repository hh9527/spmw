# RFC 0004: Bins、Apps 和 Sync 资源模型

## 状态

草案。

本文定义 `links` 和 `shortcuts` 之后的新外部资源声明模型。新模型把用户需求
拆成 `bins`、`apps` 和 `sync` 三类，避免把 Windows 上语义差异很大的
symbolic link、junction、hardlink、copy 和 shell shortcut 都暴露成同一个
`link` 概念。

## 背景

当前配置使用：

```json
{
  "links": {
    "bin:rg.exe": "pkgs.ripgrep:rg.exe",
    "user:.wezterm.lua": "pkgs.source:user/.wezterm.lua"
  },
  "shortcuts": {
    "apps:WezTerm": {
      "program": "pkgs.wezterm:wezterm-gui.exe"
    }
  }
}
```

这个模型的问题是 `links` 的需求语义不清晰：

- `bin:` 入口真正想表达的是“提供一个命令”。
- `apps:` 或开始菜单入口真正想表达的是“提供一个应用入口”。
- 用户配置文件真正想表达的是“把文件或目录同步到用户环境”。

如果实现把 `link` 静默 fallback 到 hardlink、junction 或 copy，配置作者会以为
自己声明的是路径引用，实际得到的却是不同资源语义。尤其 copy 只是一次性复制，
会破坏 package object、plan 和 prune 之间的引用关系。

Windows 的 symbolic link 还受 Developer Mode 或管理员权限影响。把所有资源都
建模为 symlink 会把一个 Windows 权限问题扩散到普通命令入口和配置同步场景。

## 目标

- 用 `bins` 表达命令入口。
- 用 `apps` 表达 Windows 应用入口。
- 用 `sync` 表达单向文件或目录同步。
- 让配置作者看到的是需求语义，而不是 Windows 的低层 link 类型。
- 避免 `link` 静默降级为 copy、hardlink 或 junction。
- 保持 update/install 的确定性边界：`update` 解析变量，`install` 重放
  `next-plan.json` 并生成具体 plan。
- 定义 `links` 和 `shortcuts` 的迁移路径。

## 非目标

- 不提供双向同步。
- 不保留用户对 managed sync target 的本地修改。
- 不把 symbolic link 作为 `bins` 或 `apps` 的实现。
- 不要求提供完整目录 mirror。
- 不定义完整 JSON schema。
- 不定义冲突检测和 ownership 元数据的最终实现细节。

## 新配置模型

source config 可以声明：

```json
{
  "schema": 3,
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
  "bins": {
    "rg": "pkgs.ripgrep:rg.exe"
  },
  "apps": {
    "WezTerm": {
      "program": "pkgs.wezterm:wezterm-gui.exe",
      "cwd": "pkgs.wezterm"
    }
  },
  "sync": {
    "user:.wezterm.lua": "pkgs.source:user/.wezterm.lua",
    "user:.config/nvim/": "pkgs.source:user/.config/nvim/"
  }
}
```

`packages` 和 source-ref 语义沿用 RFC 0002。

## Bins

`bins` 是 map：

```json
{
  "bins": {
    "<command-name>": "<target>"
  }
}
```

`<command-name>` 是命令名，不包含路径分隔符，也不包含扩展名。实现会在 `bin:`
虚拟根下创建一个 `.cmd` command shim。`bins` 的实现只使用 `.cmd` shim，
不尝试 symbolic link fallback。

```text
bin:<command-name>.cmd
```

`bin:` 虚拟根指向 spmw managed bin 目录：

```text
~/.spmw/bin
```

bootstrap 应确保用户级 `Path` 中：

```text
~/.local/bin
~/.spmw/bin
```

按上述顺序出现。`~/.local/bin` 是用户 override 层，`~/.spmw/bin` 是 spmw
managed 命令入口层。

示例：

```json
{
  "bins": {
    "rg": "pkgs.ripgrep:rg.exe",
    "spmw-cli": "pkgs.source:bin/spmw-cli.ps1"
  }
}
```

生成的 `.cmd` 应把所有参数转发给目标程序。目标可以是 `.exe`、`.cmd`、`.bat`
或 PowerShell script。PowerShell script 的具体调用方式由实现决定，但必须
满足普通 PowerShell 环境中可执行。

`bins` 表达的是命令入口，不是文件同步。`.cmd` shim 是唯一实现路径，因此
`bins` 不依赖 Developer Mode。

## Apps

`apps` 是 map：

```json
{
  "apps": {
    "<app-name>": {
      "program": "<target>",
      "cwd": "<target>"
    }
  }
}
```

`program` 必填，`cwd` 可选。实现会在 `apps:` 虚拟根下创建 Windows shell
shortcut：

```text
apps:<app-name>.lnk
```

`apps` 表达的是用户可启动的应用入口。它不表示文件系统 link。

## Sync

`sync` 是 map：

```json
{
  "sync": {
    "<target-path>": "<source-path>"
  }
}
```

`sync` 是单向同步：

```text
source -> target
```

路径是否以 `/` 结尾决定同步对象类型：

- target 和 source 都不以 `/` 结尾：文件 sync。
- target 和 source 都以 `/` 结尾：目录 sync。
- 只有一侧以 `/` 结尾是配置错误。

文件 sync 的 MVP 实现策略是：

```text
symbolic link -> managed copy
```

实现应优先创建文件 symbolic link。若 symbolic link 因 Developer Mode、权限或
平台限制失败，则复制文件内容到 target。copy 在 `sync` 中是合法实现语义，因为
`sync` 表达的是“让 target 反映 source 内容”，不是路径引用。

目录 sync 的 MVP 实现策略是：

```text
directory symbolic link -> junction
```

实现应优先创建目录 symbolic link。若 symbolic link 失败，则创建 directory
junction。junction 仍然是路径重定向，会把外部 target 指向 source object 目录。

如果用户修改 managed sync target，后续 `install` 可以覆盖这些修改。配置作者
不应把需要手工维护的文件或目录声明为 `sync` target。

`sync` 声明以 managed 状态为准。若 `sync-file` target 已经存在为普通文件，
activate 可以替换它，使目标收敛到当前 plan。目录 target 更危险；若
`sync-dir` target 已经存在为普通目录，activate 必须拒绝递归覆盖，要求用户先
手工处理。

## Tradeoff

本文选择轻量实现，不在 MVP 中提供完整目录 mirror。`bins` 和 `apps` 直接使用
Windows 原生入口机制：`bins` 固定生成 `.cmd` shim，`apps` 固定生成 `.lnk`。
只有 `sync` 使用 symbolic link 作为首选路径引用实现，并在 symbolic link
不可用时按资源类型 fallback。

不使用 hardlink 作为文件 sync 的原因是 Windows hardlink 的多个路径共享同一个
MFT 文件记录，ReadOnly 属性也共享。若 ready object 被标记为 ReadOnly，则
hardlink 出来的 sync target 也是 ReadOnly；删除任意一个 hardlink 名字都需要
先清除 ReadOnly，而清除 target 的 ReadOnly 会同时清除 source object 的保护状态。
这无法同时满足“object 防误改”和“外部 sync target 可替换/删除”。

文件 fallback 到 copy 的代价是 target 不再自动跟随 source object 的路径变化。
但 `sync` 是 install/activate 驱动的单向同步，后续 `install` 可以重新复制当前
plan 的 source 内容。因此 copy 是 `sync-file` 的正确降级，而不是 `link` 的
静默语义变化。

目录 fallback 到 junction 的优点是实现简单、速度快，也不需要维护 ownership
manifest。代价是 junction 会暴露 object 目录：通过外部 target 写入，就等同于
写入 source object tree。ReadOnly attribute 可以防止已有 ReadOnly 文件被误改，
但不能完整保护目录结构，也不能防止新增文件。这个方案适合受信任的个人环境，
不是安全边界。

`bins` 不使用 symbolic link 的原因是命令入口需求和文件路径引用需求不同。
`.cmd` shim 可以稳定处理命令名、扩展名、参数转发和 PowerShell script 调用，
也不受 Developer Mode 限制。更新时只需要重写 shim 指向新 object。

未来可以增加显式目录策略，例如 `mode: "mirror"` 或单独的 managed mirror
resource，用更重的实现换取更强的 object 隔离。

## Object ReadOnly

ready object 可以在提交后标记为 ReadOnly，用于防止意外修改。ReadOnly 是防误改
机制，不是安全边界。

`install`、`activate` 和删除外部 managed refs 都不解除 ready object 的
ReadOnly。只有 prune 最后删除不可达 object tree 时，才可以先解除该 object
tree 的 ReadOnly，再删除 object。

## Source Local Target

RFC 0002 中的 `pkgs.source` 局部别名继续适用。source config 内：

```json
{
  "bins": {
    "spmw-cli": "pkgs.source:bin/spmw-cli.ps1"
  },
  "sync": {
    "user:.wezterm.lua": "pkgs.source:user/.wezterm.lua"
  }
}
```

在合并 source fragment 前，`pkgs.source` 会解析为当前 source package key，
例如 `pkgs.source.spmw`。

## Source 合并规则

`packages`、`bins`、`apps` 和 `sync` 按 source 顺序合并。

- 按 key 合并。
- 后面的 source 覆盖前面的同名 key。
- 覆盖是 value 级别整体替换，不做字段级 deep merge。

旧的 `links` 和 `shortcuts` 不参与新模型的长期合并规则。兼容期内实现可以把它们
转换为新资源，再进入同一套 plan 生成流程。

## Plan Resource

外部配置使用需求语义；plan 使用可执行语义。prepare 阶段可以把 `bins`、`apps`
和 `sync` 转换为更具体的 resources。

推荐 plan 结构：

```json
{
  "resources": {
    "bins": [
      {
        "kind": "bin",
        "key": "bin:rg",
        "path": "bin:rg.cmd",
        "program": "object:pkgs/ripgrep.<hash>/rg.exe"
      }
    ],
    "apps": [
      {
        "kind": "app",
        "key": "app:WezTerm",
        "path": "apps:WezTerm.lnk",
        "program": "object:pkgs/wezterm.<hash>/wezterm-gui.exe",
        "cwd": "object:pkgs/wezterm.<hash>"
      }
    ],
    "syncs": [
      {
        "kind": "sync-file",
        "key": "sync:user:.wezterm.lua",
        "target": "user:.wezterm.lua",
        "source": "object:pkgs/source.main.<hash>/user/.wezterm.lua",
        "method": "symlink-or-copy"
      },
      {
        "kind": "sync-dir",
        "key": "sync:user:.config/nvim/",
        "target": "user:.config/nvim/",
        "source": "object:pkgs/source.main.<hash>/user/.config/nvim/",
        "method": "symlink-or-junction"
      }
    ],
    "regs": []
  }
}
```

具体字段名可以在实现时调整，但 plan 必须记录足够信息，让 activate 不再读取
source config，也不重新解析 variables。

## Activate 语义

activate 应用 plan resources：

- `bin`：创建或更新 `.cmd` shim。
- `app`：创建或更新 `.lnk` shortcut。
- `sync-file`：优先创建文件 symbolic link，失败时复制文件。
- `sync-dir`：优先创建目录 symbolic link，失败时创建 junction。
- `reg`：沿用当前 registry resource 语义。

activate 不解除 ready object 的 ReadOnly 属性，也不修改 ready object 内的文件。
从旧 resource 切换到新 resource 时，activate 只处理外部 managed path，例如
替换 `.cmd` shim、`.lnk` shortcut 或 sync target。`sync-file` fallback copy
属于外部 managed file，可以替换本地普通文件；`sync-dir` junction 会暴露 object
目录，activate 只替换 junction 本身，不修改 source object tree，也不递归覆盖
已有普通目录。

如果某个 resource 应用失败，activate 的失败策略应按 resource 类型定义。
MVP 中可以保守选择：

- `bin`、`app`、`sync` 失败时报告错误并继续处理其他 resources。
- registry 写入失败仍然可以让 activate 失败，因为 registry 常用于字体等系统集成。

无论某个 resource 本次物理应用是否成功，`lock.refs` 都记录当前 plan 的 managed
resource keys。`lock.refs` 表示 spmw 接受并承诺维护的资源集合，不表示本次物理
写入成功集合。

## Prune 语义

`prune` 根据当前 lock plan 计算 wanted resources。

`prune` 的顺序是：

1. 先删除 `lock.refs` 中不再 wanted 的真实外部 managed resources。
2. 收敛 `lock.refs`。
3. 最后在显式对象清理选项下删除不再可达的 object。

对不再 wanted 的外部 managed resource：

- `bin`：删除对应 `.cmd` shim。
- `app`：删除对应 `.lnk` shortcut。
- `sync-file`：删除 target 文件。
- `sync-dir`：删除 target directory symlink 或 junction。
- `reg`：删除对应 registry value。

`sync-dir` 的 MVP 外部 target 应是 directory symlink 或 junction。`prune`
删除的是这个 reparse point 本身，不递归删除 source object tree。

ready object 的 ReadOnly 保护只在删除 object tree 时解除。也就是说：

- `install` 在 `.tmp` object 中构建资产，提交 ready 后可以把 object 标记为
  ReadOnly。
- `activate` 不解除 object ReadOnly。
- 删除外部 managed refs 时不解除 object ReadOnly。
- 只有 prune 最后删除不可达 object tree 时，才可以先解除该 object tree 的
  ReadOnly，再删除 object。

## 兼容和迁移

旧配置：

```json
{
  "links": {
    "bin:rg.exe": "pkgs.ripgrep:rg.exe",
    "user:.wezterm.lua": "pkgs.source:user/.wezterm.lua"
  },
  "shortcuts": {
    "apps:WezTerm": {
      "program": "pkgs.wezterm:wezterm-gui.exe"
    }
  }
}
```

推荐迁移为：

```json
{
  "bins": {
    "rg": "pkgs.ripgrep:rg.exe"
  },
  "apps": {
    "WezTerm": {
      "program": "pkgs.wezterm:wezterm-gui.exe"
    }
  },
  "sync": {
    "user:.wezterm.lua": "pkgs.source:user/.wezterm.lua"
  }
}
```

兼容期内实现可以支持：

- `links` 中 `bin:*` 转换为 `bins`。
- `shortcuts` 中 `apps:*` 转换为 `apps`。
- `links` 中非 `bin:` target 转换为 `sync`。

但兼容转换应输出 warning，提示配置作者迁移到 `bins`、`apps` 和 `sync`。

长期目标是弃用 `links` 和 `shortcuts`。`shortcuts` 可以比 `links` 保留更久，
因为它的语义接近 `apps`，不存在 symlink fallback 问题。

## Bootstrap 影响

spmw 自身最小 source config 应从：

```json
{
  "links": {
    "bin:spmw-cli.ps1": "pkgs.source:bin/spmw-cli.ps1"
  }
}
```

迁移为：

```json
{
  "bins": {
    "spmw-cli": "pkgs.source:bin/spmw-cli.ps1"
  }
}
```

bootstrap 仍然只负责建立 spmw 自举闭环。正式命令入口由 `bins` 生成的 shim
接管。

## 安全和确定性

- `bins` 使用 `.cmd` shim，不需要 Developer Mode。
- `apps` 使用 `.lnk` shortcut，不需要 Developer Mode。
- `sync-file` 不使用 hardlink。优先使用文件 symbolic link；如果 symbolic link
  不可用，fallback 到 managed copy。
- `sync-file` managed 状态优先于本地普通文件；声明后 activate 可以替换已有
  普通文件。
- `sync-dir` 不递归接管已有普通目录。
- `sync-dir` 优先使用 directory symbolic link，失败时 fallback 到 junction。
- `sync-dir` 的 junction fallback 会暴露 source object tree；这是轻量实现的
  明确 tradeoff，不是安全边界。
- `install` 必须从 `next-plan.json` 重放 source 集合，不能重新读取当前
  `~/sources.spmw.json` 决定本次资源集合。
- `activate` 不重新解析变量。
- `prune` 只能删除 `lock.refs` 中由 spmw 接管过、且当前 plan 不再需要的 resources。

## 后续问题

- `.cmd` shim 对 PowerShell script、GUI exe 和参数 quoting 的具体模板。
- `bins` 是否允许配置作者显式指定扩展名，例如 `spmw-cli.ps1`。
- `apps` 是否支持 icon、arguments、description 和 window style。
- `sync-file` copy fallback 是否应记录 source hash，用于跳过不必要复制。
- `sync-dir` 是否需要未来支持 `mode: "mirror"`，以及 ownership metadata 采用
  manifest、xattr、sidecar 还是全目录托管。
- object ready 后是否只对文件标记 ReadOnly，还是也标记目录。
- 是否保留一个显式 `symlinks` section 给确实需要路径引用语义的高级场景。
