# RFC 0002: 稳定核心外部概念

## 状态

草案。

本文记录 MVP 之后需要稳定下来的外部模型。重点是用户和配置作者可见的
状态、source、package、plan 和命令阶段语义。

内部实现细节，例如进程互斥锁、schema validator 和资源 ownership 校验，
不在本文中定稿。

## 背景

RFC 0001 已经稳定了对象存储和激活模型。当前实现中，配置来源由特殊的
`main` package 承担：

```text
plan -> main package -> config.spmw.json -> packages/resources
```

这个模型足以支撑 MVP，但 `main` 同时承担了多个角色：

- 配置来源。
- 一个特殊 package。
- bootstrap anchor。
- plan 的入口身份。

后续需要支持多个配置来源时，应把“配置来源引用”和“普通 package 声明”
分开建模。

## 目标

- 明确 `next-plan.json`、`state/plan/<id>.json` 和 `lock.json` 的外部语义。
- 定义本地 `sources.spmw.json` 和 source-ref 模型。
- 将声明中的变量绑定过程命名为 `defs`，将解析后的变量快照命名为 `variables`。
- 定义多个 source 对 `packages` 的确定性合并规则。
- 明确 `update`、`install -Prepare`、`install` 和 `prune` 的阶段语义。
- 保持 source package 复用 package 物化机制，但避免把它暴露成普通用户 package。
- 要求实现提供新的 bootstrap script，用 source-ref 模型建立 spmw 自举闭环。

## 非目标

- 不定义未来 resource section 的跨 source 合并语义。
- 不增加公开 `activate` CLI 命令。
- 不改变 RFC 0001 中对象不可变和 plan 激活的基本模型。
- 不定义完整 JSON schema。
- 不定义进程级互斥锁实现。
- 不兼容 RFC 0001 的旧配置字段命名；实现可以要求重新 bootstrap。

## 状态模型

spmw 对外使用三层状态概念：

- **将是状态**：由 `state/next-plan.json` 表示，由 `update` 推进。
- **已准备状态**：由 `state/plan/<id>.json` 表示，由 prepare 阶段生成。
- **应是状态**：由 `state/lock.json` 中的 `plan` 游标表示，由 `install`
  内部 activate 阶段成功后推进。

Windows 文件系统、开始菜单、注册表、字体表等真实系统接入点称为
**物理世界**。物理世界可能因为用户手动修改或外部工具操作而偏离 spmw 的
应是状态。

`lock.json` 不是进程互斥锁。它记录 spmw 当前接受并承诺维护的应是状态。

`lock.json.refs` 不是当前应是资源集合，而是 spmw 已知 managed resource 的
回收追踪集合。`prune` 使用它找出不再属于当前应是 plan 的旧资源，并在成功
回收后收敛这组 refs。

## Source Ref

source-ref 表示一个配置来源。它只表达“如何物化一个包含配置文件的 source
package”，不表达最终系统能力。

source-ref 只能在本地 `~/sources.spmw.json` 中声明。source package 物化出的
`config.spmw.json` 不能声明 source-ref，不能改变 source 顺序，也不能增加新的
source。

source-ref 使用保留前缀 `source.`：

- source-ref key 必须以 `source.` 开头。
- `sources[]` 中的每个 source object 的 `name` 必须以 `source.` 开头。
- 普通 package key 不能以 `source.` 开头。
- `source.` 后面的名字不能为空。
- source package 只能由本地 `~/sources.spmw.json` 声明。
- source package 物化出的 `config.spmw.json` 中，`packages` 不能包含
  以 `source.` 开头的 key。

package key 使用保守字符集：

- package key 必须匹配 `[A-Za-z0-9][A-Za-z0-9._-]*`。
- package key 不能包含 `/`、`\`、`:` 或空白字符。
- source-ref key 必须匹配 `source.[A-Za-z0-9][A-Za-z0-9._-]*`。
- 普通 package key 不能以 `source.` 开头。

`defs` 表示变量绑定定义。`variables` 只用于 `next-plan.json` 和 plan 等
解析后的状态文件，表示已经解析出的变量快照。

`~/sources.spmw.json` 的 `sources` 是有序 source-ref object 数组。数组顺序
就是 source config 的读取顺序。

如果本地 `~/sources.spmw.json` 不存在，`update` 报错。bootstrap 或
`source add` 负责创建这个文件。

source object 中：

- `name` 必填。
- `defs` 可选，缺省为 `[]`。
- `install` 必填。
- RFC 0002 中，source object 的 `install` 只能包含 `Unpack` action。

示例：

```json
{
  "schema": 1,
  "sources": [
    {
      "name": "source.spmw",
      "defs": [
        {
          "version": {
            "src": "https://github.com/hh9527/spmw/releases/download/latest/VERSION.txt"
          }
        },
        {
          "config-rpath": "config.spmw.json"
        }
      ],
      "install": [
        {
          "action": "Unpack",
          "file": "spmw-<version>.tar.gz",
          "src": "https://example.invalid/spmw-<version>.tar.gz"
        }
      ]
    },
    {
      "name": "source.main",
      "defs": [
        {
          "commit": {
            "src": "https://github.com/OWNER/REPO/commits/<BRANCH>.atom",
            "ty": "CommitFromGithubAtom"
          }
        }
      ],
      "install": [
        {
          "action": "Unpack",
          "file": "windows-config-<commit>.tar.gz",
          "src": "https://github.com/OWNER/REPO/archive/<commit>.tar.gz",
          "strip": 1
        }
      ]
    }
  ]
}
```

source package 可以复用普通 package object 机制，但它不是普通用户 package。
source package 的职责是提供一个 source config。source package 不能执行普通
package action，但它物化出的 package object 可以作为 link、shortcut 等
activation target。source package 不需要特殊的 `InstallMainConfig` action。

source package 只允许纯获取类 install action。RFC 0002 中唯一支持的 source
install action 是 `Unpack`。source package 的 install action 不能直接产生
activation resources，例如 fonts 或 registry；links 和 shortcuts 由合并后的
source config 在 activate 阶段统一生成。

source config 的 activation target 可以使用 `pkgs.source` 引用承载当前
source config 的 source package object。`pkgs.source:<path>` 是 source
config 内的局部别名，在合并 source fragment 前解析为实际 source key，例如
`source.main` 中的 `pkgs.source:user/.wezterm.lua` 会被解析为
`pkgs.source.main:user/.wezterm.lua`。这样 source config 不需要知道自己在
本机 `~/sources.spmw.json` 中的具体 source-ref key。

source package 可以通过 `defs` 导出 `config-rpath` 变量。若 source-ref 的
resolved variables 中没有 `config-rpath`，读取 source config 时使用默认
fallback `config.spmw.json`。这个 fallback 只用于定位配置文件，不注入到
`variables`，也不参与 `variable-digest`。

`config-rpath` 是 source package object 内的相对文件路径。它必须满足：

- 不能为空。
- 不能是 rooted path。
- 不能以 `/` 或 `\` 开头。
- 不能包含 Windows drive letter。
- 不能包含 `..` path segment。
- 配置中推荐使用 `/` 作为路径分隔符。

source config 的读取路径为：

```text
object:<source.variables.path>/<config-rpath-or-default>
```

## Source 顺序和配置合并

`sources` 是有序、非空、不可重复的 source-ref object 列表。

`update` 按 `sources` 顺序读取各 source package object 中的
source config。这个顺序同时定义了 map section 的确定性覆盖关系。

source config 不能包含 `sources` section。source-ref 只能由本地
`~/sources.spmw.json` 声明。

对 `packages`、`links` 和 `shortcuts` section：

- 按 key 合并。
- 如果多个 source 声明同名 key，后面的 source 覆盖前面的 source。
- 覆盖是 value 级别的整体替换，不做字段级 deep merge。

示例：

```json
// source.spmw/config.spmw.json
{
  "schema": 1,
  "packages": {
    "spmw": {
      "defs": [
        {
          "version": {
            "src": "https://example.invalid/stable/VERSION.txt"
          }
        }
      ]
    },
    "curl": {
      "defs": [
        {
          "version": "8.10.1"
        }
      ]
    }
  }
}
```

```json
// source.main/config.spmw.json
{
  "schema": 1,
  "packages": {
    "curl": {
      "defs": [
        {
          "version": "8.11.0"
        }
      ]
    },
    "ripgrep": {
      "defs": [
        {
          "version": "14.1.1"
        }
      ]
    }
  }
}
```

若本地 `sources.spmw.json` 中声明：

```json
{
  "sources": [
    {
      "name": "source.spmw",
      "defs": [],
      "install": []
    },
    {
      "name": "source.main",
      "defs": [],
      "install": []
    }
  ]
}
```

则合并后的 package 集合等价于：

```json
{
  "packages": {
    "spmw": "...from source.spmw...",
    "curl": "...from source.main...",
    "ripgrep": "...from source.main..."
  }
}
```

其中 `source.main` 中的 `curl` 整体替换 `source.spmw` 中的 `curl`。

`links` 和 `shortcuts` 使用同样规则。后面的 source 中同名 link 或 shortcut
整体替换前面的定义。

未来其他 resource section 的 source 合并语义暂不在本文中定义。

## next-plan.json

`next-plan.json` 记录 update 生成的将是状态。它保存 resolved variables，
不保存 declaration-time `defs`。

它至少包含：

- `sources`：参与生成这份将是状态的 source-ref 列表和顺序。
- `packages`：所有已解析 package 的变量快照集合，包括 source package 和普通 package。

示例：

```json
{
  "schema": 2,
  "sources": ["source.spmw", "source.main"],
  "packages": {
    "source.spmw": {
      "variables": {
        "manifest-digest": "...",
        "version": "...",
        "variable-digest": "...",
        "path": "pkgs/source.spmw.<hash>"
      }
    },
    "source.main": {
      "variables": {
        "manifest-digest": "...",
        "commit": "...",
        "variable-digest": "...",
        "path": "pkgs/source.main.<hash>"
      }
    },
    "spmw": {
      "variables": {
        "manifest-digest": "...",
        "version": "...",
        "variable-digest": "...",
        "path": "pkgs/spmw.<hash>"
      }
    },
    "ripgrep": {
      "variables": {
        "manifest-digest": "...",
        "version": "...",
        "variable-digest": "...",
        "path": "pkgs/ripgrep.<hash>"
      }
    }
  }
}
```

`next-plan.json.sources` 是 source-ref key 数组，说明 `packages` 中哪些 key
在本次 update 中承担 source 角色。
source 是 plan 中的角色，不是 package entry 自身的类型字段。因此不需要在
`packages` entry 中增加 `kind`。

约束：

- `sources` 必须非空。
- `sources` 不能包含重复 key。
- `sources` 中每个 key 必须存在于 `packages`。
- `sources` 中每个 key 必须以 `source.` 开头。
- 普通 package key 不能以 `source.` 开头。

## update

`update` 推进将是状态。

流程：

```text
read ~/sources.spmw.json
resolve source package defs into variables
materialize source package objects
read each source package's config-rpath in sources order
validate that source configs do not declare source refs
merge packages, links and shortcuts by key, later source wins
resolve merged package defs into variables
write state/next-plan.json
```

`update` 不改变 `lock.json.plan`，也不把任何 resource 挂载进物理世界。
如果本地 `~/sources.spmw.json` 不存在，`update` 报错，且不写入新的
`next-plan.json`。

本次 update 中，source package 的解析来源以本地 `~/sources.spmw.json` 为准。
source config 中声明的同名 package 可以影响最终 `next-plan.json`，但不会反向
改变本次已经读取的 source object。

## install 对 next-plan 的重放

`install` 和 `install -Prepare` 必须从 `next-plan.json` 重放 update 已经接受的
source 集合，不能重新读取当前本地 `~/sources.spmw.json` 来决定 source 顺序或
source 定义。

重放流程：

```text
read state/next-plan.json
for each key in next-plan.sources:
  read variables from next-plan.packages[key]
  ensure source package object is ready
  read object:<variables.path>/<variables.config-rpath or config.spmw.json>
merge packages, links and shortcuts by key, later source wins
for each non-source package in next-plan.packages:
  use variables from next-plan.packages[package-key]
  use definition from merged packages[package-key]
  materialize package object
generate external resources from merged links and shortcuts
write state/plan/<id>.json
```

这样 `update` 和 `install` 之间即使本地 `~/sources.spmw.json` 被修改，当前
`next-plan.json` 仍然可以被确定性安装。

重放时必须满足：

- `next-plan.sources` 中每个 key 必须存在于 `next-plan.packages`。
- `next-plan.packages` 中允许包含被 `next-plan.sources` 引用的 source package。
- install 先安装 `next-plan.packages` 中列出的所有普通 package，也就是排除
  `next-plan.sources` 引用的 source package。
- 对每个普通 package，merged config 中必须存在同名 package definition。
- merged config 中存在但 `next-plan.packages` 中不存在的 package 不会被安装。
- 普通 package 安装完成后，再按 merged links 和 shortcuts 生成外部 resources。
- merged links 和 shortcuts 如果引用不存在于 `next-plan.packages` 的 package，
  install 报告该 resource 错误，但继续处理其他 resources。

这些约束保证 `next-plan.json` 是 install 的 package 枚举来源。source config
只用于恢复 package definitions，并在 package 安装完成后生成外部 resources。

## install -Prepare

`install -Prepare` 执行 prepare 阶段。

它读取 `next-plan.json`，物化 package objects，并生成具体的
`state/plan/<id>.json`。

`install -Prepare` 表示达成将是状态前的资源准备：

- 不挂载进物理世界。
- 不改变用户当前可用能力。
- 不改变 `lock.json.plan`。
- 不删除 `lock.json` 中已有信息。
- 如需记录将来可回收的 managed refs，只能对 `lock.json` 做只增不改不删的
  非破坏性扩展。

因此，`install -Prepare` 不达成应是状态，只生成可被 activate 的已准备状态。

## install 和 activate 阶段

公开 CLI 仍然只有 `install`，不新增 `activate` 命令。

概念上：

```text
install = prepare + activate
```

`activate` 是 `install` 内部阶段。它负责把已准备 plan 中的 resources 挂载进
物理世界，并在成功后推进 `lock.json.plan`。

activate 阶段：

- 应用 link、shortcut、registry、font 等 resources。
- 成功后把 `lock.json.plan` 推进到本次 plan id。
- 将本次 plan 的 resource keys 合并进 `lock.json.refs`。
- 不负责删除旧 resources。

如果 prepare 成功但 activate 失败，`lock.json.plan` 不应推进到新 plan。

## prune

`prune` 按 `lock.json.plan` 表示的应是状态做非破坏性回收。

`prune`：

- 不推进 `next-plan.json`。
- 不推进 `lock.json.plan`。
- 根据当前应是 plan 计算 wanted resources。
- 从 `lock.json.refs` 中找出不再属于 wanted resources 的旧 managed resources。
- 删除这些旧 managed resources。
- 可在显式选项下回收未引用的 package objects、font objects 和 download cache。
- 回收成功后，可以收敛 `lock.json.refs`。

`prune` 不是通用卸载命令。它只清理 spmw 已知、且不再属于当前应是状态的
managed resources 和可回收对象。

## Bootstrap 影响

source-ref 模型下，bootstrap 不再需要理解用户配置仓，也不需要过滤用户
`config.spmw.json`。

RFC 0002 的实现必须提供一个 bootstrap script。bootstrap 的职责只剩下建立
spmw 自举闭环：

```text
bootstrap.ps1
  -> 下载临时 spmw CLI
  -> 临时 CLI source add spmw https://github.com/hh9527/spmw/releases/download/latest
  -> 临时 CLI update
  -> 临时 CLI install
  -> 正式 CLI update
  -> 正式 CLI install
  -> 正式 bin:spmw-cli.ps1 接管
```

初始 `~/sources.spmw.json` 可以只有：

```json
{
  "schema": 1,
  "sources": [
    {
      "name": "source.spmw",
      "defs": [
        {
          "version": {
            "src": "https://github.com/hh9527/spmw/releases/download/latest/VERSION.txt"
          }
        }
      ],
      "install": [
        {
          "action": "Unpack",
          "file": "spmw-<version>.tar.gz",
          "src": "https://github.com/hh9527/spmw/releases/download/<version>/spmw.tar.gz",
          "verify": {
            "sha256": {
              "src": "https://github.com/hh9527/spmw/releases/download/<version>/spmw.tar.gz.sha256"
            }
          }
        }
      ]
    }
  ]
}
```

`source.spmw` 提供最小自管理 profile，至少声明正式 CLI link。该 link 可以
直接指向当前 source package object 中的 CLI，例如
`pkgs.source:bin/spmw-cli.ps1`。bootstrap 只需要保证正式 `spmw-cli.ps1` 由
spmw 自己挂载到 `bin:`。

bootstrap script 应满足：

- 可以在没有既有 `~/sources.spmw.json` 的机器上运行。
- 通过 CLI 的
  `source add spmw https://github.com/hh9527/spmw/releases/download/latest`
  只写入或更新自举必需的 `source.spmw`。
- 不要求用户配置仓存在。
- 不读取、不解析、不过滤用户配置仓。
- 自举完成前，bootstrap script 必须用正式 `bin:spmw-cli.ps1` 再执行一次
  标准 `update` / `install` 流程。

用户配置源不是 bootstrap 的一部分。bootstrap 完成后，用户可以通过后续命令
或直接编辑本地 `~/sources.spmw.json` 添加自己的 source-ref，例如：

```text
spmw-cli.ps1 source add main gh-src:OWNER/REPO/main
```

最小 `source add` 命令支持 GitHub source archive：

```text
spmw source add <name> gh-src:<OWNER>/<REPO>/<BRANCH>
```

以及通用 HTTP release source：

```text
spmw source add <name> http(s)://<BASE>/<VERSION>
```

其中 `<name>` 是不带 `source.` 前缀的本地 source 名。命令写入
`source.<name>`。

`source add` 是 update-or-append：

- 如果同名 `source.<name>` 已存在，则替换原 source object，并保持原位置。
- 如果同名 source 不存在，则追加到 `sources` 数组尾部。
- `source add` 不做重命名语义。

GitHub source 的默认定义为：

```json
{
  "name": "source.<name>",
  "defs": [
    {
      "commit": {
        "src": "https://github.com/<OWNER>/<REPO>/commits/<BRANCH>.atom",
        "ty": "CommitFromGithubAtom"
      }
    }
  ],
  "install": [
    {
      "action": "Unpack",
      "file": "<REPO>-<commit>.tar.gz",
      "src": "https://github.com/<OWNER>/<REPO>/archive/<commit>.tar.gz",
      "strip": 1
    }
  ]
}
```

release source 的默认定义为：

```json
{
  "name": "source.<name>",
  "defs": [
    {
      "version": {
        "src": "<BASE>/<VERSION>/VERSION.txt"
      }
    }
  ],
  "install": [
    {
      "action": "Unpack",
      "file": "spmw-<version>.tar.gz",
      "src": "<BASE>/<version>/spmw.tar.gz",
      "verify": {
        "sha256": {
          "src": "<BASE>/<version>/spmw.tar.gz.sha256"
        }
      }
    }
  ]
}
```

其中 `http(s)://<BASE>/<VERSION>` 形式中，最后一个 path segment 是 `<VERSION>`，
前面的 URL 是 release `<BASE>`。这允许同一个本地或私有 HTTP server 同时
伺服多个 release 根。

加入后，本地 source 顺序可以变成：

```text
source.spmw
source.main
```

`source.main` 在 `source.spmw` 之后，因此用户配置可以覆盖 `source.spmw`
提供的默认 package definition。若用户不添加任何配置源，系统仍然保持最小
spmw 自管理状态。

因此，当前 MVP 中的 `main` package 不再是 bootstrap 必需概念。它可以迁移为
用户后续添加的普通配置来源：

```text
source.main -> package object -> config-rpath
```

本地 `sources.spmw.json` 是唯一 source authority。

## 后续问题

以下问题留给后续 RFC 或实现设计：

- 未来 resource section 的跨 source 合并规则。
- 本地 `sources.spmw.json` 的默认生成和迁移策略。
- 是否支持本地 file source package。
- source package 是否使用独立 object namespace，或继续复用 `object/pkgs`。
- 完整 JSON schema 和错误报告格式。
- 进程互斥锁和异常恢复。
- managed resource ownership 校验。
