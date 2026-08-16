Kindle 阅读记录 v31（基于 v17 统计底座）

安装：
1. 把本压缩包中的 RUNME.sh 与 native-reading-time-package 文件夹复制到 Kindle 根目录。
2. 在电脑上安全弹出 Kindle，并断开 USB 数据线。
3. 等待 Kindle 恢复主界面后，在搜索框输入 ;log runme。
4. 等待“阅读记录 v31 已安装”提示，然后从书库打开“阅读记录”。

重要说明：
- 不覆盖、不删除 /mnt/us/reading-time/reading-time.tsv。
- 不覆盖、不删除 /mnt/us/reading-time/reading-sessions.tsv。
- 正确启动入口固定为 /mnt/us/documents/ReadingRecords.sh。
- 已知的 readingrecordds.sh 等拼错入口会移动到
  /mnt/us/reading-time/diagnostics/stale-launchers/，不会直接删除。
- 新 UI 使用 handlerId com.krt.readingrecords.v31 和独立目录
  /mnt/us/reading-time/illusion/ReadingRecords-v31/，用于绕过旧 Mesquite/WAF 缓存。
- UI 只使用 HTML/CSS/JavaScript，没有生成或内置图片。

诊断文件：
- /mnt/us/reading-time/reading-time-install.log：安装结果。
- /mnt/us/reading-time/reading-records-diagnostics.log：注册路径、appreg 实际命令、
  启动前后 activeApp/activeContext、入口文件和 UI 版本。
- /mnt/us/reading-time/service.log：统计服务运行记录。

成功日志应包含：
installed successfully; handler=com.krt.readingrecords.v31; UI=v31-unified-summary;
launcher=ReadingRecords.sh; data=preserved
