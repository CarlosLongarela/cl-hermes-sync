# Hermes Portable

**将你的 Hermes Agent 配置打包，跨机器恢复——甚至跨操作系统。**

`hm-portable.sh` 把你的 Hermes Agent 配置（config.yaml、SOUL.md、skills、memories、cron、插件配置）打包成一个便携目录或 `.tar.gz` 文件。搬到另一台机器上，运行 `import`，你的 Hermes 就恢复原样——相同的配置、相同的技能、相同的记忆。

## 功能

- **导出** — 打包 config.yaml、SOUL.md、skills（1300+ 文件）、memories、cron、插件配置
- **导入** — 在新机器上完整恢复，自动备份已有配置
- **跨 OS** — 自动检测 Linux、macOS、Windows，自动调整 OS 特定配置（`auto_source_bashrc`、`persistent_shell`）
- **灵活** — 导出为目录或 `.tar.gz`，方便 scp / Dropbox / USB 传输
- **安全默认** — auth token 和 `.env` API key 需要明确确认才包含。`--no-secrets` 模式用于 CI/脚本环境
- **自包含** — 包内带有 `setup.sh`，解压后直接运行，无需额外工具

## 快速开始

```bash
# 安装（一行命令）
curl -fsSL https://raw.githubusercontent.com/zpage/hermes-portable/main/hm-portable.sh \
  -o /usr/local/bin/hm-portable.sh && chmod +x /usr/local/bin/hm-portable.sh

# 导出你的 Hermes 配置
hm-portable.sh export --tar --output ~/hermes-backup.tgz

# 查看包内容
hm-portable.sh list ~/hermes-backup.tgz

# 复制到另一台机器（scp / Dropbox / U 盘...）
# 然后导入：
hm-portable.sh import ~/hermes-backup.tgz
```

## 为什么需要这个工具

Hermes Agent 的所有配置都存放在 `~/.hermes/` 下——skills（1300+ 文件）、memories、cron、auth token。搬到新机器意味着手动复制所有这些内容，还要处理 OS 差异。这个工具帮你自动化：

| 问题 | 手动做 | 用 hm-portable |
|---|---|---|
| 复制 skills/ | `rsync` 1300 个文件 | 自动包含 |
| macOS 上关掉 `auto_source_bashrc` | 手动编辑 config.yaml | ⚡ 自动检测调整 |
| Windows 上关掉 `persistent_shell` | 手动编辑 config.yaml | ⚡ 自动检测调整 |
| 记得要复制什么 | 通常会漏掉 auth.json | 可选的，明确确认 |
| 验证完整性 | 祈祷别出问题 | manifest 有 SHA256 校验 |
| 灾难恢复 | 希望你有备份 | 恢复前自动备份现有配置 |

## 用法

### 导出

```bash
# 基本用法——目录模式
hm-portable.sh export

# Tar.gz 模式（方便传输）
hm-portable.sh export --tar --output ~/hermes-$(date +%F).tgz

# 非交互模式（跳过 auth/.env 确认）
hm-portable.sh export --yes

# 完全跳过敏感数据（CI 环境安全）
hm-portable.sh export --no-secrets

# 包含 sync 状态和 session 历史
hm-portable.sh export --include-sync --include-sessions
```

### 查看包内容

```bash
hm-portable.sh list ~/hermes-backup.tgz
```

输出示例：
```
  Exported:   2026-05-28T02:33:30Z
  Source OS:  Linux
  Target OS:  Linux
  From:       my-workstation
  Version:    Hermes Agent v0.14.0

Contents:
    ✓ config
    ✓ soul
    ✓ skills
    ✓ memories
    ✓ cron
    ✓ plugins
    ✗ sync (not included)
    ✗ sessions (not included)
    ✗ auth (not included)
    ✗ env (not included)

Skills: 1336 files
Memories: 2 files
Total: 121.6 MB
```

### 导入

```bash
# 从目录导入
hm-portable.sh import /path/to/.hm-portable

# 从 tar.gz 导入
hm-portable.sh import ~/hermes-backup.tgz
```

导入流程：
1. 备份现有 `~/.hermes` 到 `~/.hermes.bak.<timestamp>`
2. 检测目标 OS（Linux / macOS / Windows）
3. 恢复 config、skills、memories、cron、插件配置
4. 自动调整 config.yaml 中的 OS 特定配置
5. 如果包中包含 auth/`.env`，一并恢复

## 包含/不包含的内容

| 项目 | 大小 | 默认包含 |
|---|---|---|
| `config.yaml` | ~15 KB | ✅ |
| `SOUL.md` | ~2 KB | ✅ |
| `skills/` | ~112 MB（1300+ 文件） | ✅ |
| `memories/` | ~12 KB | ✅ |
| `cron/`（任务定义） | ~36 KB | ✅ |
| `plugins/`（仅配置） | ~712 KB | ✅ |
| `auth.json` | ~10 KB | ❌（可选） |
| `.env`（API key） | ~21 KB | ❌（可选） |
| `sync/`（hermes-sync 状态） | ~44 MB | ❌（需要 `--include-sync`） |
| `sessions/` | ~75 MB | ❌（需要 `--include-sessions`） |
| `state.db` | ~69 MB | ❌（需要 `--include-sessions`） |

**不包含（需要在目标机器上独立安装）：**
- Hermes Agent 核心（`pip install hermes-agent`）
- hermes-agent 源码（~2.2 GB）
- Node.js 运行时（~1.4 GB）
- `logs/`、`cache/`——机器相关，会自动重新生成

## 跨 OS 迁移

每个包中自带的 `setup.sh` 会自动检测目标 OS 并调整配置：

| 配置项 | Linux | macOS | Windows |
|---|---|---|---|
| `auto_source_bashrc` | 保持原样 | → `false` | → `false` |
| `persistent_shell` | 保持原样 | 保持原样（加备注） | → `false` |
| sync `remote_path` | 保持原样 | 检查路径是否存在 | 检查路径是否存在 |

无需手动编辑。调整内容会在导入时打印，让你清楚知道改了什么。

## 项目结构

```
hermes-portable/
├── hm-portable.sh     # 主 CLI 工具（单文件，~30 KB）
├── README.md          # 英文文档
├── README.zh.md       # 中文文档（即本文件）
└── LICENSE            # MIT
```

## 环境要求

- **Bash** 4+（Linux、macOS、WSL）
- **Python 3**（`list` 命令需要显示 manifest）
- 常用 POSIX 工具：`curl`、`tar`、`sed`、`grep`、`find`

目标机器必须在导入前已安装 Hermes Agent。

## License

MIT
