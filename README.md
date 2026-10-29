# Codex 额度悬浮球

基于 [Freeze7749/claude-token-monitor-ball](https://github.com/Freeze7749/claude-token-monitor-ball) 改编，保留原版 Windows WPF 外观和操作，改为监控 Codex 的 ChatGPT 订阅额度。

## 使用

1. 安装 Codex 桌面版或 Codex CLI，使用 ChatGPT 账户登录。
2. 将 ZIP 完整解压到固定文件夹。
3. 双击 **启动悬浮球.vbs**。不需要管理员权限。
4. 如果系统禁用了 VBS，可右键“使用 PowerShell 运行”脚本，或执行：
   `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexFloatBall.ps1`

大数字显示主窗口剩余额度，下方显示次窗口剩余额度。通常是 5 小时 / 每周，具体以服务返回的窗口长度为准。绿色 ≥50%，黄色 ≥20%，红色 <20%。未知额度显示 -- 或 !，不会假装成 0%。

| 操作 | 功能 |
| --- | --- |
| 拖动 | 移动并记住位置 |
| 双击 | 立即刷新 |
| 悬停 | 查看全部额度、重置时间、最近更新时间或错误 |
| 右键 → 打开详细监控 | 内置详情窗口，随刷新更新，可选择复制文本 |
| 右键 → 开机自动启动 | 切换当前用户的启动快捷方式 |
| 右键 → 退出 | 关闭悬浮球及其查询进程 |

每 3 分钟自动刷新；后台查询不会阻塞拖动。失败时保留上次数据并标注“数据较旧”。启动项不会默认开启。移动文件夹前请关闭开机启动，再在新位置重新开启。

## 数据来源和差异

通过本机 `codex app-server` 的官方 `account/rateLimits/read` 接口查询，仅初始化并读取额度，不创建聊天或发起模型请求。优先使用 `rateLimitsByLimitId`，兼容旧版 `rateLimits`。详情显示服务返回的所有额度窗口。

原版的外部 Claude Usage Monitor 已替换为内置 Codex 详情窗口。Claude 的 Opus / Sonnet 分类由 Codex 返回的实际额度分类取代。

这是订阅额度监控，不是 API Key 账单统计或逐条消息 token 计数。API Key 登录或账户未返回额度时会提示不可用。

官方协议参考：https://learn.chatgpt.com/docs/app-server

## 环境和排查

- Windows 10 / 11，自带 Windows PowerShell 5.1 + WPF。
- 自动查找 PATH、Codex 桌面版目录和 npm 默认全局目录中的 codex.exe。
- 自定义安装可设置 `CODEX_FLOATBALL_EXE` 指向 codex.exe；自定义配置目录使用 `CODEX_HOME`。
- 登录失败：在 Codex 中重新登录 ChatGPT 账户，再双击刷新。
- 超时：检查网络或 Codex 的代理设置。
- 悬浮球使用当前 Codex 配置和登录账户。它不读取、复制、保存或记录访问令牌；鉴权及网络请求由官方 Codex 进程处理。
- 本地 settings.json 仅保存悬浮球位置。卸载前关闭开机启动、退出，然后删除文件夹即可。

## 验证

`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-CodexUsage.ps1`

`powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\CodexFloatBall.ps1 -SmokeTest`

SmokeTest 使用模拟数据打开界面及详情窗口，两秒后自动退出，不查询网络。

## 许可

MIT，保留原项目 LICENSE。原版主脚本参考 SHA：0c807e71976f73ec6c2c14a9f1a8bcc97325bd82。

