# backup

> **English** / [简体中文](README_zh.md)

Linux 服务器通用备份与恢复脚本。POSIX 兼容，可同时运行于 `sh` 与 `bash`，适配新旧各版本 Linux 发行版。通过 `.env` 文件或环境变量配置，无需改动脚本即可适配不同业务。

## 特性

- **POSIX 兼容**：仅使用标准语法与基础命令，无 bash 专属特性，`sh` / `bash` 通用。
- **配置与逻辑分离**：所有可变参数通过 `.env` / 环境变量注入，脚本本体零修改复用。
- **前置校验**：必填项、路径、依赖在执行核心逻辑前一次性校验，提前报错终止。
- **故障兜底**：`trap` 捕获所有退出路径；若服务停止曾被执行，退出时强制尝试启动，杜绝业务长期停摆。
- **滚动清理**：按时间戳保留最新 N 份备份与日志，超出自动删除。
- **恢复支持**：`--restore-latest` 恢复最新备份，支持恢复前自动快照。
- **极简输出**：仅保留关键节点提示，错误信息统一携带返回码。

## 项目结构

```
.
├── backup.sh        # 核心备份 / 恢复脚本（POSIX）
├── .env.example     # 配置模板（复制为 .env 后修改）
├── .gitignore       # 忽略 .env 与 logs/
├── README.md        # 英文文档
└── README_zh.md     # 中文文档
```

运行后会在配置目录下生成备份包与日志：

```
{BACKUP_DIR}/{PREFIX}_backup_{YYYYMMDD_HHMMSS}.tar.gz   # 备份压缩包
{LOG_DIR}/{PREFIX}_backup_{YYYYMMDD_HHMMSS}.log         # 备份运行日志
{LOG_DIR}/{PREFIX}_restore.log                            # 恢复运行日志（每次覆盖）
```

## 快速开始

1. 复制配置模板并填写必填项：

   ```sh
   cp .env.example .env
   vi .env
   ```

2. 编辑 `.env`，至少填写 4 个必填变量（服务停止命令、源数据目录、备份目录、服务启动命令）：

   ```sh
   STOP_CMD="systemctl stop myapp"
   START_CMD="systemctl start myapp"
   SRC_DIR="/opt/myapp/data"
   BACKUP_DIR="/var/backups/myapp"
   ```

3. 赋予执行权限并运行备份：

   ```sh
   chmod +x backup.sh
   ./backup.sh
   ```

4. （可选）加入定时任务，每天凌晨 2:30 执行：

   ```sh
   crontab -e
   # 添加：
   30 2 * * * /path/to/backup.sh
   ```

## 使用方式

```
./backup.sh                                  # 执行备份
./backup.sh --restore-latest                 # 恢复最新备份
./backup.sh --restore-latest --target-dir /new/path
                                             # 恢复到指定目录
```

| 选项 | 说明 |
| --- | --- |
| `--restore-latest` | 将 `BACKUP_DIR` 中最新的备份恢复到 `SRC_DIR`（交互式）。 |
| `--target-dir <目录>` | 覆盖 `SRC_DIR`，对备份和恢复模式均生效（最高优先级）。 |

## 配置说明

所有变量遵循优先级：**系统环境变量 > `.env` 文件 > 内置默认值**。已存在的系统环境变量不会被 `.env` 覆盖，支持运行时临时覆写。

| 变量 | 必填 | 默认值 | 说明 |
| --- | :---: | --- | --- |
| `STOP_CMD` | 是 | — | 备份前停止服务的命令 |
| `START_CMD` | 是 | — | 备份后启动服务的命令 |
| `SRC_DIR` | 是 | — | 待备份的源数据目录（相对/绝对路径） |
| `BACKUP_DIR` | 是 | — | 备份压缩包存放目录（不存在自动创建） |
| `MAX_BACKUPS` | 否 | `30` | 备份包与日志共享的最大保留份数（正整数） |
| `BACKUP_PREFIX` | 否 | `app` | 备份包与日志文件名前缀 |
| `LOG_DIR` | 否 | `./logs/` | 日志文件存放目录（不存在自动创建） |

## 备份工作流程

脚本严格按「校验 → 停服 → 备份 → 启服 → 清理」顺序执行，任一步失败走对应兜底分支：

1. **前置校验**：加载配置 → 检查必填项 → 校验 `MAX_BACKUPS` 为正整数 → 校验源目录存在 → 自动创建备份/日志目录 → 生成运行时间戳。
2. **停止服务**：执行 `STOP_CMD` 并校验返回码。失败则尝试启动服务后报错退出，不进入备份。
3. **数据备份**：`tar -zcf` 按源目录 basename 打包（保证归档可移植性）。失败则删除残缺包、启动服务、报错退出，不执行清理。
4. **启动服务**：执行 `START_CMD`。失败仅输出告警，不影响已生成的备份，脚本正常结束。
5. **滚动清理**：仅备份成功后执行，分别对备份包与日志按 `MAX_BACKUPS` 保留最新 N 份。

## 恢复工作流程（`--restore-latest`）

将 `BACKUP_DIR` 中最新的备份恢复到 `SRC_DIR`（备份目录 → 源目录）。交互式流程，不涉及服务启停（恢复仅处理数据）。

1. **确认恢复**：打印最新备份路径与恢复目标，询问确认。输入 `y` 或 `yes` 继续；其他取消。
2. **选择现有数据处理方式**：
   - `1` — 直接覆盖现有数据目录。
   - `2` — 先将当前数据备份为 `{PREFIX}_backup_before_restore.tar.gz`，再覆盖。安全快照使用固定文件名（每次恢复覆盖），**不计入** `MAX_BACKUPS`。
   - `3` — 取消。
   - 输入非 `1` 非 `2` 的值均视为 `3`（取消）。
3. **执行恢复**：解压归档到临时目录，将数据移入 `SRC_DIR`。

恢复默认读取配置中的 `SRC_DIR` 和 `BACKUP_DIR`。如需恢复到其他位置：

```sh
# 通过 CLI 参数（最高优先级）
./backup.sh --restore-latest --target-dir /opt/myapp/data_restored

# 通过系统环境变量
SRC_DIR=/opt/myapp/data_restored ./backup.sh --restore-latest
```

## 异常与兜底

`trap ... EXIT` 捕获正常退出、报错退出与中断信号（`INT` / `HUP` / `TERM`）。只要服务停止曾被实际执行（`STOP_CMD` 已运行），无论以何种方式退出都会强制尝试一次 `START_CMD`，杜绝脚本异常导致服务永久停止。恢复模式下不执行停止，trap 为空操作。

分级失败策略（备份模式）：

| 场景 | 行为 |
| --- | --- |
| 停服失败 | 不执行备份；尝试启服后报错退出 |
| 打包失败 | 删除残缺包；启服；报错退出；不执行清理 |
| 启服失败 | 仅输出告警；备份已生效；脚本正常结束 |
| 清理失败 | 不影响主流程；记录告警日志 |

## 滚动清理

- **匹配规则**：备份包匹配 `{PREFIX}_backup_*.tar.gz`，日志匹配 `{PREFIX}_backup_*.log`。文件名含 `before_restore` 的文件被排除，恢复安全快照不会被清理或计入上限。
- **排序规则**：按文件名字典序倒序排列（文件名含时间戳，字典序等同于时间序），不依赖文件 mtime。
- **执行时机**：仅备份成功后执行，避免备份失败时误删历史可用备份。

## 日志

- 每轮运行的日志文件名与备份包一一对应（恢复模式为运行日志），共用同一时间戳。
- 所有输出同时写入终端与日志文件；关键节点（停服、备份完成、启服、清理完成）同步终端提示。
- 错误信息统一携带 `[ERROR]` 标识与返回码。
- 备份日志与备份包共享 `MAX_BACKUPS` 保留上限，清理逻辑完全一致。

## 使用示例

**运行时覆写参数**（不改 `.env`）：

```sh
MAX_BACKUPS=10 BACKUP_PREFIX=db ./backup.sh
```

**查看最新日志**：

```sh
ls -t logs/*.log | head -1 | xargs less
```

**交互式恢复最新备份**：

```sh
./backup.sh --restore-latest
```

## 兼容性

- 语法：仅使用 POSIX 标准（`[ ]` 判断、`.` 加载、无数组 / 关联数组 / bash 字符串截取）。
- 命令：`date +%Y%m%d_%H%M%S`、`tar -zcf`/`-zxf` 搭配 `-C`、`ls` + `sort`，均使用标准参数，无 GNU 专属扩展。
- 已通过 `sh` 与 `bash` 语法校验，并覆盖成功、配置缺失、停服失败、打包失败、滚动清理、环境变量覆写、信号中断兜底、默认值、参数校验、源目录缺失等场景测试，以及恢复全流程（覆盖模式、先备份再恢复、取消、目标目录、环境变量覆盖、无备份归档、非 1/2 默认取消）测试。

## 常见问题

- **报错 "missing required config"**：`.env` 中有必填变量留空，按提示补齐。
- **报错 "source directory does not exist"**：`SRC_DIR` 路径不存在或不是目录。
- **报错 "MAX_BACKUPS must be a positive integer"**：`MAX_BACKUPS` 必须为 ≥ 1 的整数。
- **报错 "backup directory does not exist"**（恢复）：`BACKUP_DIR` 中需已有备份归档。
- **备份/日志目录不存在**：脚本会自动递归创建，无需手动建立。
- **首次运行**：正常生成备份与日志，无历史时跳过清理。
- **启服告警但备份成功**：检查 `START_CMD` 是否正确；归档已生成且有效。
- **恢复被取消**：重新运行，在确认提示输入 `y`/`yes`，在操作提示输入 `1` 或 `2`。
