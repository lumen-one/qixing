import '../domain/speednote.dart';

/// 速记的存储插座（附录 B.9）：**一个文件装全部速记**，没有 sidecar、没有行指纹。
///
/// 读永不抛异常（坏块进 warnings）；写是整份重写——正文就是数据，不值得为它造
/// 一套行级补丁（与 `主线.md`、`编排.md` 同档）。
abstract class SpeedNoteRepository {
  /// 解析告警（诊断用；UI 不展示）。
  List<String> get warnings;

  /// 全部速记，**顺序即文件顺序**（本层不排序）。
  Future<List<SpeedNote>> loadAll();

  /// 整份落盘。
  Future<void> saveAll(List<SpeedNote> notes);
}
