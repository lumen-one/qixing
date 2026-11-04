import '../domain/speednote.dart';

/// `速记.md` 的编解码插座（附录 B.9）。
///
/// 与主线同族：**一个文件装全部速记**，正文就是数据本身，所以没有 sidecar、也没有
/// 行指纹——应用保存时按模型整份重写。
class SpeedNoteDecodeResult {
  final List<SpeedNote> notes;
  final List<String> warnings;

  const SpeedNoteDecodeResult(this.notes, this.warnings);
}

abstract class SpeedNoteCodec {
  /// 格式标识（将来迁移用）。
  String get formatId;

  bool canDecode(String raw);

  /// 解析整篇（**永不抛异常**：坏块记 warnings 后跳过）。
  SpeedNoteDecodeResult decode(String raw);

  /// 编码整篇。[originalRaw] 用来做未知 frontmatter 行的字段级保真。
  String encode(List<SpeedNote> notes, {String? originalRaw});
}
