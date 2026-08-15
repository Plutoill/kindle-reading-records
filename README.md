# Kindle Reading Records

一个面向越狱 Kindle 的轻量阅读记录插件，在原生系统中统计并查看每日、每月和每本书的阅读时长。

> 非 Amazon 官方项目。安装前请确认设备已经越狱，并具备运行 `;log runme` 脚本的环境。

## 功能

- 按天记录阅读时长和阅读会话
- “当日阅读”支持切换前一天、后一天
- 年度累计时长及月度比例概览
- 月份详情按阅读时长排列当月书籍
- 书籍列表每页 12 本，支持多种排序方式
- 书籍详情展示每日阅读记录
- 尝试从 Kindle 内容数据库匹配本地封面
- 封面无法匹配时保留版式空位，不影响文字对齐
- 升级安装时保留已有 TSV 阅读数据
- 独立 WAF handler 和诊断日志，降低旧界面缓存干扰

## 安装

1. 从 [Releases](../../releases) 下载 `kindle-reading-records-v1.0.0.zip`。
2. 解压后，将 `RUNME.sh`、`README.txt` 和 `native-reading-time-package` 复制到 Kindle 根目录。
3. 安全弹出 Kindle，并断开 USB 数据线。
4. 在 Kindle 搜索框输入：

   ```text
   ;log runme
   ```

5. 等待“阅读记录 v29 已安装”提示，然后从书库打开“阅读记录”。

## 数据与升级

阅读历史保存在：

```text
/mnt/us/reading-time/reading-time.tsv
/mnt/us/reading-time/reading-sessions.tsv
```

安装器只替换程序文件，不覆盖或删除这两个数据文件。重新安装或升级前仍建议自行备份 `reading-time` 文件夹。

## 诊断

遇到无法启动、界面没有更新或没有统计数据时，可查看：

```text
/mnt/us/reading-time/reading-time-install.log
/mnt/us/reading-time/reading-records-diagnostics.log
/mnt/us/reading-time/service.log
```

当前启动入口固定为：

```text
/mnt/us/documents/ReadingRecords.sh
```

安装器会将已知的错误入口名（如 `readingrecordds.sh`）移动到诊断备份目录，而不是直接删除。

## 已知限制

- 依赖越狱后的 Kindle 系统接口，不保证适用于所有固件和设备型号。
- 封面依赖 Kindle 内容数据库中的映射；部分个人文档可能没有可用封面。
- 阅读时长来自设备端会话统计，极短会话或系统异常退出可能不会形成完整记录。

## 版本

当前稳定版本：`v1.0.1`
