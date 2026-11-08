import '../domain/logbook.dart';

/// `记录.md` 的编解码插座（格式见 formats/logbook.md B.10）。
///
/// 与 `主线.md` 同族：**一个文件装全部记录**，正文就是数据本身，所以没有 sidecar、
/// 也没有行指纹——应用保存时按模型重写正文。
class LogBookDecodeResult {
  final LogBook book;
  final List<String> warnings;

  const LogBookDecodeResult(this.book, this.warnings);
}

abstract class LogBookCodec {
  /// 格式标识（将来迁移用）。
  String get formatId;

  bool canDecode(String raw);

  /// 解析整篇（**永不抛异常**：坏行跳过）。
  LogBookDecodeResult decode(String raw);

  /// 编码整篇。
  String encode(LogBook book);
}
