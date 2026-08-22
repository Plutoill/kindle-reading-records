# 局域网同步

v1.3 在同一 Wi-Fi 内直接同步多台 Kindle，不需要手机、电脑或云端服务。

## 工作方式

- 后台 `reading-syncd` 只监听数据请求，不定时扫描，也不每秒唤醒。
- 两台 Kindle 连接同一 Wi-Fi、保持唤醒并同时打开“阅读记录”后，各自发起一次局域网查找。
- 找到对方后会拉取事件账本，按事件 ID 去重合并，再把合集回传给对方。
- 同步失败不影响本机统计和界面打开。
- TCP 17688 用于设备确认和数据传输，数据不会发送到互联网。

## 数据兼容

- 原有 `reading-time.tsv` 与 `reading-sessions.tsv` 会在首次升级时导入 `sync-events.tsv`。
- 每条新记录包含持久化设备 ID 和单调序号，反复同步不会重复累计。
- 合并后仍重建原来的两个 TSV，因此现有 UI、统计报告和历史数据格式保持兼容。

## 状态和诊断

- 页面右下角显示“未发现设备”“已发现设备”“正在同步”或“同步完成”。
- `/mnt/us/reading-time/sync.log`：后台同步日志。
- `/mnt/us/reading-time/sync-status.tsv`：最近一次状态。
- `/mnt/us/reading-time/reading-records-diagnostics.log`：安装和启动诊断。

## 日志清理

- `sync.log` 达到 128 KB 后轮换，保留当前文件和一份 `.1` 旧日志。
- `reading-records-diagnostics.log` 达到 256 KB 后轮换一次。
- `service.log` 达到 128 KB 后轮换一次；两个 Upstart 输出日志各限制为 64 KB。
- 成功同步只写一行摘要，失败时保留失败阶段，全部诊断日志长期控制在约 1 MB。
- 安装成功后只保留最近两份旧 UI 备份，更早的备份会在路径校验后删除。
- `sync-events.tsv` 是同步数据账本，不属于日志；阅读数据、设备标识和事件序号均不会自动清理。
