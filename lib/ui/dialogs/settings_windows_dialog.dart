import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../time_format.dart';
import 'time_pick.dart';

/// 通知时间段编辑（多段式，设置页「提醒与排序」区）：截止型任务的提醒只落在
/// 时间段内，段外顺延到下一时段开头（不吞掉）；时点性提醒不受限制。
Future<void> showSettingsWindowsDialog(
    BuildContext context, AppController c) async {
  final windows = [
    for (final w in c.settings.notificationWindows) [w[0], w[1]]
  ];
  Future<void> pick(int index, bool isStart) async {
    final cur = windows[index][isStart ? 0 : 1];
    final t = await pickTime(
      context,
      initial: TimeOfDay(hour: cur ~/ 60, minute: cur % 60),
      title: '通知时间段',
    );
    if (t == null) return;
    final v = t.hour * 60 + t.minute;
    if (isStart ? v >= windows[index][1] : v <= windows[index][0]) return;
    windows[index][isStart ? 0 : 1] = v;
  }

  await showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('通知时间段（多段式）',
                  style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                  '段外的提醒顺延到下一时段开头；时点性提醒不受限',
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 8),
              for (var i = 0; i < windows.length; i++)
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () async {
                          await pick(i, true);
                          setSheet(() {});
                        },
                        child: Text(fmtClockMinutes(ctx, windows[i][0])),
                      ),
                    ),
                    const Text('–'),
                    Expanded(
                      child: TextButton(
                        onPressed: () async {
                          await pick(i, false);
                          setSheet(() {});
                        },
                        child: Text(fmtClockMinutes(ctx, windows[i][1])),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => setSheet(() => windows.removeAt(i)),
                    ),
                  ],
                ),
              TextButton.icon(
                onPressed: () {
                  if (windows.length >= 6) return;
                  setSheet(() => windows.add([9 * 60, 12 * 60]));
                },
                icon: const Icon(Icons.add),
                label: const Text('加一段'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  c.updateSettings(
                      c.settings.copyWith(notificationWindows: windows));
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
