import '../domain/plan.dart';

/// `编排.md` 的编解码插座（附录 B.7）。
///
/// 与任务的双文档不同：编排**一个文件装所有日子**，正文就是数据本身，所以没有
/// sidecar、也没有行指纹——应用保存时按模型重写正文。
///
/// 整份文件有两类段：日期段（一天一段）与模板段（`### 循环`，至多一段）。模板必须和
/// 日子一起过这道编解码，否则写回时会被抹掉。
class PlanDecodeResult {
  final List<DayPlan> days;

  /// 每日循环的模板条目；空 = 没有模板段或段里是空的。
  final List<PlanEntry> template;

  final List<String> warnings;

  const PlanDecodeResult(
    this.days,
    this.warnings, {
    this.template = const [],
  });
}

abstract class PlanCodec {
  /// 格式标识（将来迁移用）。
  String get formatId;

  /// 解析整篇（**永不抛异常**：认不出的行跳过）。
  PlanDecodeResult decode(String raw);

  /// 编码整篇（模板段在前，日子按新→旧）。
  String encode(List<DayPlan> days, {List<PlanEntry> template = const []});
}
