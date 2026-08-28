# NewTerm-Beat 移动终端增强 · 需求核实与执行方案

日期：2026-08-28
状态：已批准（用户确认「批准，按此执行」）
验证通道：设备 SSH（连接信息待用户提供）

## 1. Objective

把 NewTerm-Beat 打造成越狱 iPhone 上跑 AI CLI（codex / claude code）的主力终端：
选择复制、链接/Filza 跳转、项目管理、会话续接可靠可用；补齐触屏分屏、
iCloud 项目目录、SSH 服务器管理、AI skill 面板与模型锁定、主题与中文优化、
灵动岛状态显示。

## 2. 需求核实结论（2026-08-28，基于 HEAD 5b3df0e）

| # | 需求 | 结论 |
|---|------|------|
| 1 | 灵动岛后台显示 | 未实现，需 WidgetKit extension，deb 打包签名是最大风险点 |
| 2 | 复制选中 / 链接跳转 / Filza | 代码已实现（TerminalSessionViewController:428/468/504），用户装最新仍不可用 → 真机排查 |
| 3 | 双屏 = 触屏分屏 | split 已有但仅硬件键盘 Cmd+D 可触发；用户上限 2 个 pane |
| 4a | 选项目自动切终端 | 已实现（RootViewController.openProject:506），实测仍不行 → 排查 |
| 4b | 杀后台恢复会话 | SessionStore 恢复 tab 结构 + tmux 续接上下文（设备需装 tmux），实测仍不行 → 排查 |
| 4c | iCloud 项目目录 | projectsDirectory 已可配置；指向 CloudDocs 待实机验证同步 |
| 5 | SSH 服务器管理 | 仅 ssh:// scheme，无管理界面 |
| 6 | 越狱高权限 | 已具备（no-container / platform-application entitlements） |
| 7 | 主题 / 中文 | 主题选择器与 CJK 宽度处理已有；具体症状待用户补充 |
| 8 | skill 管理 + agent 调用 | 未实现；形态=app 内管理面板（用户已确认） |
| 9 | 禁止模型降级 | 落地为锁定 AI CLI 配置文件中的 model 字段 |

HEAD 编译验证：`xcodebuild -scheme "NewTerm (iOS)" -configuration Release` BUILD SUCCEEDED。

## 3. 阶段划分（每阶段独立交付、独立回滚，开工时单独出实现计划）

### 阶段 0 · 实测通道（前置）
- 手工打 deb：xcodebuild → ldid（App/entitlements.plist，helper 单独签）→ dpkg-deb（Theos 未安装，不走 Makefile）
- 建立设备 SSH：装包、跑压测脚本、读崩溃日志全自动化
- 完成条件：deb 装上能开 shell，SSH 通道可执行远程命令

### 阶段 1 · P0 实测修复批
- 逐项真机复现：选择复制、链接/Filza、项目切换、杀后台恢复
- 先验假设：复制失败的根因是选择手势入口不可发现（需长按/拖选特定手势）
- 完成条件：四项功能真机全过 + 每个 bug 有根因记录

### 阶段 2 · 触屏分屏（上限 2 pane）
- 工具栏加分屏按钮：竖屏上下分、横屏左右分；已分屏时变「关闭分屏」
- 现有嵌套 split 逻辑加硬顶：最多 2 个 pane
- 完成条件：iPhone 纯触屏可分屏/关闭，第 3 次分屏被拒绝

### 阶段 3 · iCloud 项目目录
- 设置加「使用 iCloud Drive」开关 → projectsDirectory 指向
  `~/Library/Mobile Documents/com~apple~CloudDocs/NewTermProjects`
- 风险：越狱进程写入能否触发 bird 同步，必须实机验证；不行则回到方案讨论，不预造备选
- 完成条件：手机建项目 → Mac 端 iCloud Drive 可见（或明确记录不可行）

### 阶段 4 · SSH 服务器管理
- 唯一数据源 `~/.ssh/config`（Host 条目 = 服务器）；app 列表 + 点击开 tab 执行 `ssh <name>` + 增删改写回
- 终端内 / AI 输出里 `ssh 名字` 天然生效，无第二份配置
- 完成条件：增删改查 + 一键连接真机可用；config 手工改动后列表同步

### 阶段 5 · AI 面板（skill 管理 + 模型锁定）
- 面板列出 `~/.claude/skills`、`~/.codex` 及项目级 skills；一键向当前终端插入调用命令
- 模型锁定：读写 `~/.claude/settings.json`、`~/.codex/config.toml` 的 model 字段，显示当前值、一键固定
- 边界：不做 skill 内容编辑器
- 完成条件：列表准确、插入命令正确、模型字段写入后 CLI 实际生效（真机验证）

### 阶段 6 · 主题 + 中文
- 主题选择器加预览色板；补 Dracula / Solarized / Catppuccin 等主流配色
- 中文：终端 CJK 字体 fallback（PingFang SC）与对齐验证；app 界面本地化检查
- 前置：用户补充具体症状后细化
- 完成条件：中文长文本输出对齐无错位、新主题可选可预览

### 阶段 7 · 灵动岛 Live Activity（风险最高，最后做）
- WidgetKit extension + ActivityKit：显示活动会话数 / 当前项目 / 运行状态
- 风险：deb 内打包 app extension + ldid 签名需实机验证，是全项目最大不确定点
- 边界：app 被系统杀死后灵动岛不再更新（上下文存续靠 tmux）；后台保活（jetsam 调整）不在本期范围
- 完成条件：前台转后台时灵动岛出现并显示正确状态；被杀后行为符合预期并记录

## 4. 复核门禁（每阶段交付前必过）

1. 编译 + 打 deb 成功
2. 真机功能清单全过
3. 压力测试：`yes` / `seq 1000000` 大量输出、10+ tab 创建切换、连续杀后台恢复 20 次、中文长文本输出
4. 稳定性：30 分钟持续输出无崩溃、内存无持续增长
5. 失败如实报告：失败命令、原因、影响面、下一步

## 5. Out of Scope

- skill 内容编辑器
- 后台永久保活（jetsam 优先级调整，单独评估）
- 双独立窗口新功能（多 scene 已支持，不动）
- 会话滚动历史全文持久化（上下文续接由 tmux 承担）

## 6. 待用户提供

- 设备 SSH 连接信息（IP / 端口 / 用户名 / 认证方式）
- P0 各项具体症状（复制 / 链接跳转 / 项目切换 / 杀后台恢复各自怎么个不行法）
- 中文显示具体问题（错位 / 字体 / 界面语言）
