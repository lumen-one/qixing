# 主线插座

主线（行为链）住在独立的 `主线.md` 里，一个文件装全部主线；步骤不是 Task。日历上的记录
不在这里，是另一个插座（[记录插座](logbook.md)）。

**MainlineRepository / MainlineCodec**：主线存独立 `主线.md`，**一个文件装全部主线**
（在跑的 + 已归档）。与任务、周期两套完全不相交——步骤不是 Task，不进调度、不占工时；
归档 = `completed` 或 `abandoned` 字段有值，只改状态不删数据。完成要求行为链全部勾完，
废弃不要求——两条都是显式动作。
实现：`domain/mainline.dart` + `repository/{mainline_codec,mainline_repository,
markdown_mainline_repository}.dart` + `application/mainline_service.dart`。

**每条命令都是"读整份 → 改一条 → 整份写回"**：两个引擎（应用内 / 悬浮窗）可能同时写同一
个文件，读一遍再改能把"别人刚改的另一条主线"带上，不至于被本地旧内存态抹掉。代价是每条
命令多读一次小文件，可以接受。

**记录那一半已经不在这份文件里**：旧版正文里的 `### 记录` / `### 月记` 两段不解码、不迁移，
保存重写正文时丢掉（读盘给一条告警）；要留的内容由人搬进 `记录.md`
（[记录文件](../formats/logbook.md)）。
