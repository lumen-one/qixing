import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 居中弹窗外壳：**任务详情卡与日历弹窗共用这一份尺寸与圆角**。
///
/// 从底部滑出的 sheet 在桌面壳里铺满整个窗口宽度、在 240dp 的窄栏里是一条压到底
/// 的横带；一张居中卡片在三种壳下观感一致，也才配得上"一次性的小决定"这件事。
/// **新建流程不用它**：那张表要摆月历，贴着窄面板根本放不下（取舍见
/// `docs/decisions/2026-11-01-dialog-presentation.md`）。
///
/// 高度上限与日历同一套：至多屏高的 78%，键盘抬起后按剩余高度再让 40dp——输入法
/// 占掉小半屏时卡片跟着缩，而不是被顶出屏幕。
class AppDialog extends StatelessWidget {
  /// 弹窗内容。滚不滚由内容自己决定（长备注要滚，月历不滚）。
  final Widget child;

  const AppDialog({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final availableH = size.height - keyboard;
    // 下限 160：键盘几乎占满屏时宁可卡片矮到只剩标题行，也不要一个负的上限
    // （BoxConstraints 收到负值会直接断言）。
    final maxH = math.max(160.0, math.min(size.height * 0.78, availableH - 40));

    return Dialog(
      backgroundColor: theme.cardTheme.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // 默认两侧各留 40dp：窄栏里会把卡片压到 160dp，月历七列每格只剩 22dp。
      // 窄容器收到 16dp，宽屏保持 40dp。
      insetPadding: EdgeInsets.symmetric(
        horizontal: size.width < 480 ? 16 : 40,
        vertical: 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH, maxWidth: 420),
        child: child,
      ),
    );
  }
}
