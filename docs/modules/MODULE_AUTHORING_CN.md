# state 模块制作与安装说明

这份说明面向希望为 **state** 编写扩展的开发者，也适合需要安装第三方模块的用户。模块是独立的 `.stasismodule` 压缩包；核心应用负责原生界面、配置保存、进程生命周期和服务路由，模块只负责自己声明的数据、计算和动作。

## 一、制作标准

### 1. 模块包结构

```text
MyModule/
├─ module.json              # 身份、版本、角色、依赖和权限
├─ presentation.json        # 菜单栏、面板和设置中的声明式 UI
├─ settings.schema.json     # 模块自己的设置字段
├─ checksums.json           # package 命令自动生成
├─ Resources/
│  └─ localizations.json    # 可选，按 BCP-47 语言提供文案
└─ Worker.app/              # 可选；数据/业务/控制模块必须提供
```

模块 ID 使用稳定的反向域名格式，例如 `com.example.state.weather`。发布后不要因为改名或翻译修改 ID。版本使用语义化版本号；通信协议版本和模块版本是两套独立版本。

### 2. `module.json` 必填内容

```json
{
  "id": "com.example.state.example",
  "version": "0.1.0",
  "protocolVersion": "1.0",
  "minHostVersion": "1.0.0-beta.1",
  "minOSVersion": "14.8",
  "architectures": ["arm64"],
  "roles": ["presentation"],
  "entrypoint": null,
  "provides": [],
  "requires": [],
  "permissions": [],
  "uiCapabilities": ["native.rows.v1"],
  "author": "Your Name",
  "license": "MIT",
  "settingsVersion": 1,
  "displayName": "Example Module",
  "summary": "A short description.",
  "systemImage": "puzzlepiece.extension",
  "settingsAreas": ["general", "panel"]
}
```

角色按职责选择：`presentation` 只声明显示内容；`data` 发布数据服务；`business` 处理数据和动作；`control` 申请受控硬件能力。包含 `data`、`business` 或 `control` 的模块必须声明可执行的 Worker；控制模块还必须声明 `hardware.control` 权限。

### 3. 界面和设置

`presentation.json` 只能使用 state 提供的原生组件、SF Symbols 名称、数据绑定和动作 ID，不能注入 SwiftUI/AppKit 视图，也不能自行绘制窗口背景。设置必须归入三类之一：`general` 通用设置、`panel` 面板设置、`features` 功能设置。一个字段只能归属一个页面。

面板内容应只描述展示数据和可见条件，不在视图创建或预览时启动采样。菜单关闭后不再需要的展示订阅必须释放；仍需运行的控制任务通过业务生命周期保持活动。

### 4. Worker 和通信

Worker 通过标准输入/输出使用逐行 UTF-8 JSON-RPC 2.0，不开放本地网络端口。必须实现 `initialize`、`activate`、`updateDemand`、`configurationChanged`、`handleAction`、`deactivate` 和 `shutdown` 的生命周期；所有调用都应可重复、可取消。

普通请求默认 5 秒超时；长任务使用任务 ID 报告进度。数据快照必须带时间、序列号、单位和质量状态，不可用数据不能用零伪装。控制命令必须按顺序处理，不能静默丢弃。

### 5. 安全和兼容性

安装器会拒绝绝对路径、`..` 越界路径、符号链接、未知文件、不可执行入口和校验清单不一致的包。第三方程序仍按本机软件信任边界运行；正式目录模块必须使用 Developer ID 签名和公证。

官方 state 1.0 Beta 目前只发布 `arm64`。模块如声明数据服务，应在 `provides` 中声明字段、最小采样周期和最大采样周期；核心会合并多个消费者的需求，避免重复采样。

## 二、开发、验证和打包

在仓库根目录执行：

```bash
cd Tools/StasisModuleCLI
swift run stasis-module init /tmp/MyModule
swift run stasis-module validate /tmp/MyModule
swift run stasis-module dev /tmp/MyModule
swift run stasis-module test /tmp/MyModule
swift run stasis-module package /tmp/MyModule
```

`validate` 检查描述文件、界面树、设置版本、角色权限、入口程序和依赖；`dev`/`test` 会启动 Worker，验证双向 JSON-RPC 生命周期；`package` 生成干净的 `com.example.state.example-0.1.0.stasismodule`，并自动生成 SHA-256 `checksums.json`。

发布前应至少确认：冷启动和重复激活正常、取消订阅后停止采样、配置版本可迁移、Worker 崩溃不会拖垮主程序、错误信息可恢复，以及浅色/深色和长文案没有布局重叠。

## 三、安装方法

### 从设置安装本地模块

1. 打开菜单栏 state，进入“设置 → 通用设置 → 模块”。
2. 点击“安装本地模块…”，选择 `.stasismodule` 文件或模块目录。
3. state 完成协议、架构、路径安全、权限、依赖和 SHA-256 校验后才会激活。
4. 安装成功后，模块页面会自动出现在对应的通用、面板或功能设置分类中。

### 从官方目录安装

在同一页面的“官方目录”中点击“检查模块”，选择模块后点击“安装”。目录包必须通过签名、版本、系统和依赖检查；下载失败或启动健康检查失败时不会替换当前版本。

### 命令行验证本地包

```bash
cd Tools/StasisModuleCLI
swift run stasis-module validate /path/to/MyModule
swift run stasis-module package /path/to/MyModule
```

已激活模块的文件存放在：

```text
~/Library/Application Support/Stasis/Modules/<moduleID>/<version>/
```

配置单独存放在 `~/Library/Application Support/Stasis/Configuration/`，更新或移除模块不会自动删除用户设置。卸载模块应从“模块”页面执行；如果还有其他模块依赖它，state 会先提示受影响的服务。

## 四、版本发布清单

提交模块前，请提供模块 ID、版本、兼容的 state 和 macOS 版本、支持架构、权限说明、许可证、变更记录和测试结果。官方目录使用静态索引记录下载地址、摘要、签名和依赖；模块更新采用下载、校验、备份、迁移、健康检查、切换或回滚的事务流程。
