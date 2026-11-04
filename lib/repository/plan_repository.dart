import '../domain/plan.dart';

/// 编排的存储插座（附录 B.7）：**一个文件装所有日子**，没有 sidecar、没有行指纹。
///
/// 读永不抛异常（坏行进 warnings）；写是整份重写——正文就是数据，不值得为它造
/// 一套行级补丁（与 `主线.md` 同档）。
///
/// **模板和日子一起过这道插座**：每日循环的模板住在同一个文件的 `### 循环` 段里，
/// 分两次读写的话，写回日子那一次会把模板抹掉。
abstract class PlanRepository {
  /// 解析告警（诊断用；UI 不展示）。
  List<String> get warnings;

  /// 整份文档（日子由调用方保证新→旧，本层不排序）。
  Future<PlanDocument> load();

  /// 整份落盘。
  Future<void> save(PlanDocument doc);
}

/// 只要日子（测试与仿真里核对落盘内容用）。
extension PlanRepositoryDays on PlanRepository {
  Future<List<DayPlan>> loadAll() async => (await load()).days;
}
