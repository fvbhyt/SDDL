SID 替换脚本（优化版 v6.6）
-
这是一个高效、稳定且支持权限快照与变更识别的 PowerShell 脚本，用于在共享目录中替换 NTFS ACL 中的 SID 标识，并生成详细的权限变更报告。
-
功能特性
✅ SID 映射替换：根据 sid_mapping.csv 对 ACL 中的旧 SID 进行替换。

📸 权限快照备份：在替换前生成完整 ACL 快照文件。

🧠 权限变更识别：判断每条权限是否发生变更（ACL_Changed 字段）。

💾 输出 CSV 和 JSON 报告：可用于进一步分析或留档。

📊 进度实时反馈：目录扫描、快照生成、权限处理和 JSON 转换等阶段均显示进度条。

错误与调试日志：保存异常目录及处理详情便于排查。
-
文件名	作用说明
replace_acl.ps1	主脚本程序
sid_mapping.csv	SID 映射表（包含 OldSID 和 NewSID 两列）
acl_snapshot_before.csv	替换前的权限快照备份
acl_changes.csv	权限变更记录 CSV（含 ACL_Changed 字段）
acl_changes.json	同上数据的 JSON 格式，适合程序处理
acl_report.txt	脚本运行汇总报告，包括处理时间、记录总数等
acl_error.log	捕获处理异常的目录及错误信息
acl_debug.log	详细的过程调试信息（目录扫描、SID替换、JSON生成等）

步骤1：获得域用户和组的SID,ConvertTo-SID-PowerShell.
-
自动读取域组并将其转换为安全标识符（SID）。

1、ConvertTo-SID.ps1
读取 CSV 文件中的 Domain / Group 数据

2、group.csv
利用 System.Security.Principal.NTAccount 转换为 SID

3、group_with_sid.csv
输出为格式化的 CSV 文件，支持中文字符


步骤2，将group_with_sid.csv需要替换的新旧用户或组SID信息填写sid_mapping.csv中。
自动读取新旧SID将目标目录权限信息进行替换，并输出报告。
-

1、replace_sid_v6.6.ps1脚本已分为以下几个模块：

A、初始化与SID映射加载

B、目录收集与快照记录

C、权限替换及变更检测

D、JSON生成与报告输出

2、acl_snapshot_merge_tool_v1.3.ps1

A、 批量生成更多类似结构的记录

B、插入异常 SID 或空字段测试容错性

C、自动生成快照与合并后的对比报告（按用户分组）

3、sid_mapping.csv

新旧SID对照表


🧰 环境要求
-
PowerShell 7.5+

Windows 系统（支持 Active Directory 的 SID 查询）

权限允许调用 NTAccount.Translate

