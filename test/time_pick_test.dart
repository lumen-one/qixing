import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/ui/dialogs/time_pick.dart';

import 'test_app.dart';

/// 时刻滚轮（ui-interaction.md §8）：时 / 分两列，12 小时制多一列上午下午，
/// 分钟按 5 分钟步长，初始值原样保留。
void main() {
  Future<void> openSheet(
    WidgetTester tester,
    TimeOfDay initial, {
    bool use24 = true,
    void Function(TimeOfDay?)? onResult,
  }) async {
    await tester.pumpWidget(testApp(
      use24: use24,
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              onResult?.call(
                  await pickTime(ctx, initial: initial, title: '截止时间'));
            },
            child: const Text('开'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('开'));
    await tester.pumpAndSettle();
  }

  testWidgets('24 小时制：两列，初始 18:30 原样返回', (tester) async {
    TimeOfDay? result;
    await openSheet(tester, const TimeOfDay(hour: 18, minute: 30),
        onResult: (v) => result = v);

    expect(find.text('截止时间'), findsOneWidget);
    expect(find.byType(ListWheelScrollView), findsNWidgets(2));
    expect(find.text('18'), findsOneWidget);
    expect(find.text('30'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 18, minute: 30));
  });

  testWidgets('12 小时制：多一列上午下午，18:00 落在下午 6 点', (tester) async {
    TimeOfDay? result;
    await openSheet(tester, const TimeOfDay(hour: 18, minute: 0),
        use24: false, onResult: (v) => result = v);

    expect(find.byType(ListWheelScrollView), findsNWidgets(3));
    expect(find.text('6'), findsOneWidget, reason: '12 小时制的时列是 1–12');
    expect(find.text('下午'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 18, minute: 0));
  });

  testWidgets('午夜与正午都写 12 点：上午 12:00 / 下午 12:00', (tester) async {
    TimeOfDay? midnight;
    await openSheet(tester, const TimeOfDay(hour: 0, minute: 0),
        use24: false, onResult: (v) => midnight = v);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('上午'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(midnight, const TimeOfDay(hour: 0, minute: 0));

    TimeOfDay? noon;
    await openSheet(tester, const TimeOfDay(hour: 12, minute: 0),
        use24: false, onResult: (v) => noon = v);
    expect(find.text('12'), findsOneWidget);
    expect(find.text('下午'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(noon, const TimeOfDay(hour: 12, minute: 0));
  });

  testWidgets('分钟不在 5 分钟网格上：保留原值，不吸附', (tester) async {
    TimeOfDay? result;
    await openSheet(tester, const TimeOfDay(hour: 18, minute: 37),
        onResult: (v) => result = v);

    expect(find.text('37'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 18, minute: 37));
  });

  testWidgets('拨一格：时列 18 → 19', (tester) async {
    TimeOfDay? result;
    await openSheet(tester, const TimeOfDay(hour: 18, minute: 0),
        onResult: (v) => result = v);

    // drag 的前 18dp 被 touch slop 吃掉，多给一些才足以过一格。
    await tester.drag(find.byType(ListWheelScrollView).first,
        const Offset(0, -56));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, const TimeOfDay(hour: 19, minute: 0));
  });

  testWidgets('取消返回 null，不写回', (tester) async {
    var called = false;
    TimeOfDay? result = const TimeOfDay(hour: 9, minute: 0);
    await openSheet(tester, const TimeOfDay(hour: 9, minute: 0),
        onResult: (v) {
      called = true;
      result = v;
    });

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(called, isTrue);
    expect(result, isNull);
  });
}
