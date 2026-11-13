import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qixing/application/delivery.dart';
import 'package:qixing/platform/android_adapters.dart';

/// 持续响铃的 Dart 那一半（ui-interaction.md §7.2 / sockets/delivery.md 的
/// `AlarmRingPort`）：只验"下给原生的命令对不对、账记没记准"。
/// 真正的循环播放、前台服务、全屏页在 `AlarmRingService` / `AlarmActivity`，
/// 没有可跑 Java 的测试沙箱，靠真机验收。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late bool ringAccepted;

  setUp(() {
    calls = [];
    ringAccepted = true;
    messenger.setMockMethodCallHandler(AndroidNativeBridge.channel, (call) async {
      calls.add(call);
      return call.method == 'startRinging' ? ringAccepted : true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(AndroidNativeBridge.channel, null);
  });

  /// 原生回一条事件（全屏页/通知按钮停完声走这条）。
  Future<void> emit(Map<String, Object?> event) async {
    await messenger.handlePlatformMessage(
      'gtd/native/events',
      const StandardMethodCodec().encodeMethodCall(MethodCall('event', event)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  test('start → 原生 startRinging 带 taskId、秒数与闹钟渠道；记下在响的那一件', () async {
    final ring = AndroidAlarmRingPort(AndroidNativeBridge());

    await ring.start('t1', seconds: 30);

    final call = calls.single;
    expect(call.method, 'startRinging');
    expect(call.arguments['taskId'], 't1');
    expect(call.arguments['seconds'], 30);
    expect(call.arguments['channel'], ReminderChannel.alarm.name,
        reason: '停声后要重投那条通知，渠道得是闹钟那条');
    expect(ring.ringingTaskId, 't1');
  });

  test('stop → stopRinging，账也清掉', () async {
    final ring = AndroidAlarmRingPort(AndroidNativeBridge());
    await ring.start('t1', seconds: 60);
    calls.clear();

    await ring.stop('t1');

    expect(calls.single.method, 'stopRinging');
    expect(calls.single.arguments['taskId'], 't1');
    expect(ring.ringingTaskId, isNull);
  });

  test('原生起不来（后台启动受限）→ 不假装在响', () async {
    ringAccepted = false;
    final ring = AndroidAlarmRingPort(AndroidNativeBridge());

    await ring.start('t1', seconds: 60);

    expect(ring.ringingTaskId, isNull,
        reason: '这条提醒只剩通知栏那条路，端口要说实话');
  });

  test('原生侧停声回事件 → ringingTaskId 随之清空', () async {
    final ring = AndroidAlarmRingPort(AndroidNativeBridge());
    await ring.start('t1', seconds: 60);
    expect(ring.ringingTaskId, 't1');

    await emit({'type': 'ringStopped', 'taskId': 't1'});

    expect(ring.ringingTaskId, isNull);
  });

  test('挂闹钟时把响铃时长一起交给原生（应用被杀时接收器照它起铃）', () async {
    final alarm = AndroidAlarmPort(AndroidNativeBridge(), ringSeconds: () => 120);

    await alarm.scheduleStations([
      AlarmStation(
        at: DateTime(2026, 11, 12, 9, 0),
        draft: const ReminderDraft(
          taskId: 't2',
          title: '例会',
          channel: ReminderChannel.alarm,
          fullScreen: true,
        ),
      ),
    ]);

    final call = calls.single;
    expect(call.method, 'scheduleStations');
    expect(call.arguments['ringSeconds'], 120);
    final stations = call.arguments['stations'] as List<dynamic>;
    expect(stations.length, 1);
    final station = stations.single as Map<dynamic, dynamic>;
    expect(station['fullScreen'], true);
    expect(station['channel'], ReminderChannel.alarm.name);
    expect(station['atMillis'],
        DateTime(2026, 11, 12, 9, 0).millisecondsSinceEpoch);
  });
}
