import 'package:flutter/material.dart';

import '../../application/notes_markdown.dart';
import '../theme.dart';

/// 一块正文长什么样（灵感页只读态与速记页共用）。
///
/// 解析在 `parseNotesMarkdown`，这里只管样式：两边同一套段落渲染，才不会出现
/// "同一段文字在灵感页是标题、在速记里是正文"这种事。

class NotesBlockView extends StatelessWidget {
  final NotesBlock block;

  const NotesBlockView({super.key, required this.block});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodyMedium ?? const TextStyle(fontSize: 14);
    final body = base.copyWith(height: 1.6);
    final muted = scheme.onSurfaceVariant;

    switch (block.kind) {
      case NotesBlockKind.heading:
        final scale = switch (block.level) {
          1 => 1.45,
          2 => 1.28,
          3 => 1.14,
          _ => 1.0,
        };
        final style = base.copyWith(
          fontSize: (base.fontSize ?? 14) * scale,
          fontWeight: block.level <= 3 ? FontWeight.w700 : FontWeight.w600,
          height: 1.4,
          color: block.level >= 4 ? muted : null,
        );
        return Text.rich(_rich(block.spans, style, scheme));

      case NotesBlockKind.bullet:
      case NotesBlockKind.ordered:
        final marker =
            block.kind == NotesBlockKind.ordered ? '${block.number}.' : '•';
        return Padding(
          padding: EdgeInsets.only(left: 14.0 * block.level),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(marker, style: body.copyWith(color: muted)),
              const SizedBox(width: 7),
              Expanded(child: Text.rich(_rich(block.spans, body, scheme))),
            ],
          ),
        );

      case NotesBlockKind.quote:
        return Container(
          margin: EdgeInsets.only(left: 14.0 * block.level),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: scheme.outlineVariant, width: 3),
            ),
          ),
          child:
              Text.rich(_rich(block.spans, body.copyWith(color: muted), scheme)),
        );

      case NotesBlockKind.code:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(8),
          ),
          // 代码不折行：面板最窄 240，硬折会把缩进切断，横滑更接近原样
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              block.spans.map((s) => s.text).join(),
              style: base.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: _monoFallback,
                fontSize: (base.fontSize ?? 14) * 0.92,
                height: 1.5,
              ),
            ),
          ),
        );

      case NotesBlockKind.paragraph:
        return Text.rich(_rich(block.spans, body, scheme));
    }
  }
}

const _monoFallback = ['Consolas', 'Courier New', 'DejaVu Sans Mono'];

TextSpan _rich(List<NotesSpan> spans, TextStyle base, ColorScheme scheme) =>
    TextSpan(
      style: base,
      children: [
        for (final sp in spans) TextSpan(text: sp.text, style: _spanStyle(sp, base, scheme)),
      ],
    );

/// 单段的附加样式。返回 null = 沿用块的底色（普通文字）。
TextStyle? _spanStyle(NotesSpan span, TextStyle base, ColorScheme scheme) {
  switch (span.style) {
    case NotesSpanStyle.plain:
      return null;
    case NotesSpanStyle.bold:
      return const TextStyle(fontWeight: FontWeight.w700);
    case NotesSpanStyle.italic:
      return const TextStyle(fontStyle: FontStyle.italic);
    case NotesSpanStyle.boldItalic:
      return const TextStyle(
          fontWeight: FontWeight.w700, fontStyle: FontStyle.italic);
    case NotesSpanStyle.strike:
      return TextStyle(
        decoration: TextDecoration.lineThrough,
        decorationColor: base.color?.withValues(alpha: 0.55),
      );
    case NotesSpanStyle.code:
      return TextStyle(
        fontFamily: 'monospace',
        fontFamilyFallback: _monoFallback,
        fontSize: (base.fontSize ?? 14) * 0.92,
        backgroundColor: scheme.onSurface.withValues(alpha: 0.06),
      );
    case NotesSpanStyle.link:
      return TextStyle(
        color: AppColors.accent,
        decoration: TextDecoration.underline,
        decorationColor: AppColors.accent.withValues(alpha: 0.45),
      );
  }
}
