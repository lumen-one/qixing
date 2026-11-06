# 主线插座

主线（行为链 + 记录）住在独立的 `主线.md` 里，一个文件装全部主线；步骤不是 Task。

**MainlineRepository / MainlineCodec**：主线（行为链 + 记录）存独立 `主线.md`，
**一个文件装全部主线**（在跑的 + 已归档）。与任务、周期两套完全不相交——步骤不是 Task，
不进调度、不占工时；归档 = `completed` 字段有值，只改状态不删数据。
实现：`domain/mainline.dart` + `repository/{mainline_codec,mainline_repository,
markdown_mainline_repository}.dart` + `application/mainline_service.dart`。

**记录的增删改按内容定位，不传下标**：身份是 `MainlineLogRef`（起止日 + 当时的原文）。
服务每条命令都先重新读盘、再按起始日排序，界面算出的下标只对"读盘前那一刻"成立——
中间另一份引擎（悬浮面板）或人改了 `主线.md`，同一个下标就落到别人那条圈上，改错和
删错都不报错。按内容找回原条目之后：改找不到就报错（不猜），删找不到就当已经删掉
（幂等）。同起止、同文字的两条取第一条，代价登记在 [架构文档](../architecture.md) §11。

**加段 / 改起止日期要验区间**：新段与已有段只要共用一天就拒绝，报出撞到的那一段的
起止与文字，不自动裁剪——裁剪会悄悄改掉用户亲手拖出的范围。`addLog` 与 `updateLog`
都验，`updateLog` 验的时候排除它自己；只改文字不走这条。读盘不校验也不迁移。
