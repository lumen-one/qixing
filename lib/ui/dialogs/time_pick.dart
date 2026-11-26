import 'package:flutter/material.dart';

/// 时刻选择：底部 sheet 里的滚轮（§8「时间选择器」）。
///
/// 时列 + 分列，分列按 **5 分钟**步长——60 项点着转半天，而排程里的时刻很少
/// 精确到分。初始分钟不在 5 的倍数上（旧数据 18:37）时临时插一项进去，不吸附：
/// 改时间不该悄悄挪动用户已经设过的时刻。
///
/// 系统开 12 小时制时多一列上午/下午，时列变成 1–12。
///
/// 不用 `showTimePicker`：那个走 root navigator，在 240 dp 的面板里会弹成屏幕
/// 正中的 328 dp 卡片，跟"对话框不跳屏中央"（§5.1 第 5 条）正好相反。
Future<TimeOfDay?> pickTime(
  BuildContext context, {
  required TimeOfDay initial,
  String title = '选个时刻',
}) {
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    // 内容高度固定，别让系统把 sheet 压到半个屏幕。
    isScrollControlled: true,
    builder: (ctx) => _TimePickerSheet(initial: initial, title: title),
  );
}

class _TimePickerSheet extends StatefulWidget {
  final TimeOfDay initial;
  final String title;

  const _TimePickerSheet({required this.initial, required this.title});

  @override
  State<_TimePickerSheet> createState() => _TimePickerSheetState();
}

class _TimePickerSheetState extends State<_TimePickerSheet> {
  static const double _itemExtent = 32;
  static const double _viewportHeight = _itemExtent * 5;

  /// 三列各自的宽度。不用 Expanded 均分：均分会让「6」「00」「下午」散在
  /// 屏幕两端，读不出是同一个时刻。数字列收到刚好放两位数的宽度，冒号居中。
  static const double _hourWidth = 52;
  static const double _minuteWidth = 52;
  static const double _periodWidth = 64;
  static const double _colonWidth = 10;

  bool _inited = false;
  bool _use24 = true;

  late List<int> _minutes;
  late int _minuteIndex;
  late int _hourIndex;
  late bool _pm;

  late final FixedExtentScrollController _hourCtrl;
  late final FixedExtentScrollController _minuteCtrl;
  late final FixedExtentScrollController _periodCtrl;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inited) return;
    _inited = true;
    _use24 = MediaQuery.alwaysUse24HourFormatOf(context);

    _minutes = [for (var m = 0; m < 60; m += 5) m];
    if (!_minutes.contains(widget.initial.minute)) {
      _minutes = [..._minutes, widget.initial.minute]..sort();
    }
    _minuteIndex = _minutes.indexOf(widget.initial.minute);

    final hour = widget.initial.hour;
    _pm = hour >= 12;
    // 12 小时制的时列是 1–12：0 点写 12 上午，12 点写 12 下午。
    _hourIndex = _use24 ? hour : (hour % 12 == 0 ? 12 : hour % 12) - 1;

    _hourCtrl = FixedExtentScrollController(initialItem: _hourIndex);
    _minuteCtrl = FixedExtentScrollController(initialItem: _minuteIndex);
    _periodCtrl = FixedExtentScrollController(initialItem: _pm ? 1 : 0);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    _periodCtrl.dispose();
    super.dispose();
  }

  TimeOfDay _compose() {
    final minute = _minutes[_minuteIndex];
    if (_use24) return TimeOfDay(hour: _hourIndex, minute: minute);
    final h12 = _hourIndex + 1;
    return TimeOfDay(hour: (h12 % 12) + (_pm ? 12 : 0), minute: minute);
  }

  String _hourLabel(int i) => _use24 ? i.toString() : (i + 1).toString();

  String _minuteLabel(int i) => _minutes[i].toString().padLeft(2, '0');

  double get _wheelsWidth =>
      _hourWidth +
      _colonWidth +
      _minuteWidth +
      (_use24 ? 0 : _periodWidth);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            SizedBox(
              height: _viewportHeight,
              child: Center(
                child: SizedBox(
                  width: _wheelsWidth,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: (_viewportHeight - _itemExtent) / 2,
                        height: _itemExtent,
                        child: IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerHighest
                                  .withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          SizedBox(
                            width: _hourWidth,
                            child: _wheel(
                              count: _use24 ? 24 : 12,
                              controller: _hourCtrl,
                              label: _hourLabel,
                              onChanged: (i) => setState(() => _hourIndex = i),
                            ),
                          ),
                          SizedBox(
                            width: _colonWidth,
                            child: Text(
                              ':',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontSize: 19,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: _minuteWidth,
                            child: _wheel(
                              count: _minutes.length,
                              controller: _minuteCtrl,
                              label: _minuteLabel,
                              onChanged: (i) => setState(() => _minuteIndex = i),
                            ),
                          ),
                          if (!_use24)
                            SizedBox(
                              width: _periodWidth,
                              child: _wheel(
                                count: 2,
                                controller: _periodCtrl,
                                label: (i) => i == 0 ? '上午' : '下午',
                                onChanged: (i) => setState(() => _pm = i == 1),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(_compose()),
                  child: const Text('确定'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _wheel({
    required int count,
    required FixedExtentScrollController controller,
    required String Function(int index) label,
    required ValueChanged<int> onChanged,
  }) {
    final theme = Theme.of(context);
    return ListWheelScrollView.useDelegate(
      controller: controller,
      itemExtent: _itemExtent,
      diameterRatio: 1.6,
      perspective: 0.002,
      physics: const FixedExtentScrollPhysics(),
      onSelectedItemChanged: onChanged,
      childDelegate: ListWheelChildBuilderDelegate(
        childCount: count,
        builder: (ctx, i) => Center(
          child: Text(
            label(i),
            style: theme.textTheme.titleMedium?.copyWith(
              fontSize: 19,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
