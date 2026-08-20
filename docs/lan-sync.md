# 局域网同步

v1.3 在同一 Wi-Fi 内直接同步多台 Kindle，不需要手机、电脑或云端服务。

## 工作方式

- 后台 `reading-syncd` 只监听局域网发现和数据请求，不定时扫描，也不每秒唤醒。
- 打开“阅读记录”时发起一次发现，拉取其他在线 Kindle 的事件账本，按事件 ID 去重合并，再把合集回传给对方。
- 同步失败不影响本机统计和界面打开；另一台设备需亮屏并保持 Wi-Fi 连接。
- UDP 17687 用于发现，TCP 17688 用于传输。数据不会发送到互联网。

## 数据兼容

- 原有 `reading-time.tsv` 与 `reading-sessions.tsv` 会在首次升级时导入 `sync-events.tsv`。
- 每条新记录包含持久化设备 ID 和单调序号，反复同步不会重复累计。
- 合并后仍重建原来的两个 TSV，因此现有 UI、统计报告和历史数据格式保持兼容。

## 状态和诊断

- 页面右下角显示“正在同步”“已同步 N 台设备”或“未发现设备”。
- `/mnt/us/reading-time/sync.log`：后台同步日志。
- `/mnt/us/reading-time/sync-status.tsv`：最近一次状态。
- `/mnt/us/reading-time/reading-records-diagnostics.log`：安装和启动诊断。
