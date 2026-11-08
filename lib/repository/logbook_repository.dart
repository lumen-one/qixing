import '../domain/logbook.dart';

/// 记录册的存储插座（格式见 formats/logbook.md B.10）：**一个文件装全部记录**，
/// 没有 sidecar、没有行指纹。
///
/// 读永不抛异常（坏行进 warnings）；写是整份重写——正文就是数据，不值得为它造一套
/// 行级补丁。**与主线是两个插座**：这里没有一条命令需要主线 id。
abstract class LogBookRepository {
  /// 解析告警（诊断用；UI 不展示）。
  List<String> get warnings;

  Future<LogBook> load();

  /// 整份落盘（记录段与月记的排序由编解码按起始日 / 年月维持）。
  Future<void> save(LogBook book);
}
