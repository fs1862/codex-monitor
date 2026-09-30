# Codex Monitor · Codex 旁路监控台

A single-file PowerShell **side-channel monitor** for OpenAI Codex agent sessions (VSCode extension / Codex CLI / app, any surface). It reads only observable local signals — Codex rollout event logs, `codex` processes, VSCode ext-host logs, project file timestamps and git status — and renders one quiet, change-driven dashboard in a spare terminal, so you can tell at a glance **when Codex actually needs you**.

- **只读旁路推断**：不接 Codex 内部协议、不依赖 daemon、不需要任何 API key，不修改任何文件。
- **只在有实质变化时重绘**（最小间隔 5s + 60s 心跳）：画面静止 = 正常推进或空闲，无需盯屏。
- **一眼定位关键时机**：哪个会话在等你批准、哪个疑似卡住、哪轮刚完成，以及此刻正在执行的具体命令 / 累计 token。

详细面板读法与维护要点：[docs/使用指南.md](docs/使用指南.md) ｜ [中文完整说明见下](#中文说明)

---

## Quick start (Windows)

```powershell
cd C:\path\to\your\project
powershell -ExecutionPolicy Bypass -File C:\path\to\codex-monitor-v3.4.ps1
```

Header shows `CODEX AGENT MONITOR v3.4`. Keys: `Space` pause/resume · `r` force redraw · `q` quit.
Requires Windows + PowerShell 5.1+ (also runs under `pwsh` 7). `git` on PATH is optional (GIT panel degrades gracefully).

## Sample frame

```
Status        : ACTIVE   (no change for 2 m)
---------------------- SESSIONS (rollout) ----------------------
  * sid      ic   status               lastEv   tok    current step / last reply
  * 01a081ac [>]  WORKING              4 s      4.1M   shell_command : git status...
----------------------------- GIT ------------------------------
Branch        : master   changed: 3   diff: +41 / -12
----------------- RECENT WRITES (last 10m, top 10) --------------
  23 s     docs/notes.md
--------------------------- ALERTS ------------------------------
! 2026-09-30 08:42:47 Error fetching httpStatus=401 ...
```

## Status legend

| Icon | Meaning | What you should do |
|---|---|---|
| `[>] WORKING` | events flowing (< 45 s); step column = the command running right now | nothing |
| `[~] CMD/RUNNING?APPROVAL` | a command pending > 45 s: long task **or** waiting for your approval (rollout has no approval event, cannot be 100 % distinguished) | glance at the Codex window |
| `[~] QUIET(long step)` | no new events but process/log still alive (long reasoning / step) | wait |
| `[!] STALLED?` | turn unfinished and no activity for `-StaleMinutes` | investigate (may be stuck) |
| `[+] RECENTLY ENDED` | turn finished < 2 min ago; step column = excerpt of the last reply | review & give next instruction |
| `[=] IDLE` / `[-] ENDED(old)` | finished a while ago / historical session | — |
| `*` | that session's cwd is the monitored project (multi-project disambiguation) | — |

## Parameters

| Flag | Default | Description |
|---|---|---|
| `-Project <path>` | current dir | project to monitor (drives `*` match, GIT, file activity) |
| `-Interval <sec>` | 3 | polling interval (≠ redraw frequency) |
| `-StaleMinutes <min>` | 5 | silence threshold before `[!] STALLED?`; use ~10 for long batch jobs |
| `-Sessions <N>` | 6 | rows in the SESSIONS panel |
| `-RecentMin <min>` | 10 | RECENT WRITES window (minutes) |
| `-FreshHours <h>` | 8 | SESSIONS freshness window (in-flight turns are always kept) |
| `-SessionsDir <path>` | auto | Codex rollout sessions root, see Configuration |
| `-VsCodeLogRoot <path>` | auto | VSCode logs root, see Configuration |
| `-Once` | - | render exactly one frame and exit (for scripts / screenshots) |
| `-OpenLog` | - | open the freshest `Codex.log` and exit |

## Configuration (environment adaptation)

Everything is auto-detected; override only when your layout differs:

| What | Default | Override |
|---|---|---|
| Rollout sessions root | `%USERPROFILE%\.codex\sessions\YYYY\MM\DD\rollout-*.jsonl` | `-SessionsDir`, or env `CODEX_HOME` (→ `%CODEX_HOME%\sessions`) |
| VSCode ext-host log | newest `%APPDATA%\Code\logs\**\openai.chatgpt\Codex.log`, then `Code - Insiders` | `-VsCodeLogRoot`, or env `CODEX_MONITOR_VSCODE_LOGS` |
| git | used if on PATH; otherwise GIT panel shows `(git not on PATH)` | — |
| `code` CLI | only needed by `-OpenLog`; falls back to the OS default handler | — |

The monitor still works fine for pure CLI sessions on a machine without VSCode — the log-based signals simply degrade.

## Honest limitations

- `ACTIVE` means "activity was recently observed", not "the model is definitely thinking".
- Approval-waiting and long-running commands share `[~]`; the rollout stream exposes no approval event.
- Session parsing depends on the rollout JSONL event schema (`task_started` / `task_complete` / `function_call` / ...). If a future Codex version changes it, older builds may silently degrade — file an issue and I will adapt.

---

## 中文说明

### 它解决什么问题

Codex 干活时的执行过程在界面上是折叠的，人无法高效实时跟读。本监控台在旁边开一个 PowerShell 窗口，从**旁路**观察 Codex 进程、VSCode 扩展日志、项目文件变化、git diff 和**每个会话的 rollout 事件流**（此刻在执行哪条命令、累计 token、本轮是否结束），归纳成一眼可读的面板。只在有实质变化时重绘，画面静止即一切正常。

### 使用建议

1. Codex 干活时挂着本窗口，只在三种情况切回 Codex：**`[~] ...?APPROVAL`**（等你批）、**`[!] STALLED?`**（卡死排查）、**`[+] ENDED`**（本轮完成验收）。
2. 长批量任务配 `-StaleMinutes 10` 防误报；需要留证据用 `-Once` 打帧复制或 `Space` 冻结后截图。
3. ALERTS 里的日志错误行可能包含无害重复噪音（如 `fetch failed`），关注"新出现的错误"而不是"有错误"。

### 原理与维护

数据源、turn 判定、重绘指纹机制与修改脚本的注意事项（例如**新增易变字段切勿加入变化指纹，否则回到闪屏**）见 [docs/使用指南.md](docs/使用指南.md)。

### 版本沿革

- **v2** — 进程+日志+文件+git 旁路快照，每 2s 全量重绘。
- **v3** — 逐会话 rollout 面板（当前命令 / token / `-Once`）。
- **v3.1** — 按需重绘 + Space/r/q 键控 + 60s 心跳。
- **v3.2** — 指纹化重绘控制 + 最小重绘间隔 5s（终结"闪屏"）。
- **v3.3** — RECENT WRITES 面板 + `-FreshHours` 会话新鲜度过滤。
- **v3.4**（当前）— 面向发布的环境自适应：`-SessionsDir` / `-VsCodeLogRoot` 参数与 `CODEX_HOME` / `CODEX_MONITOR_VSCODE_LOGS` 环境变量，VSCode Insiders 日志回退，git 缺失优雅降级，`-OpenLog` 不再依赖 `code` CLI。

## License

[MIT](LICENSE)