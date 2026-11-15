import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../application/delivery.dart';
import '../application/settings.dart';
import '../domain/reminder.dart';
import '../domain/task.dart';

/// 安卓交付类适配器（§4.2/§4.3）：系统精确闹钟 + 系统通知（含快捷按钮与
/// 全屏闹钟）+ 持续响铃 + 权限引导 + 任务目录选择。
///
/// 原生侧（android/app/src/main/kotlin/com/lumenone/qixing/）：
/// - MethodChannel `gtd/native`：Dart 调原生（挂闹钟/弹通知/起铃停铃/权限/悬浮把手/读版本号）；
/// - MethodChannel `gtd/native/events`：原生回传（到点、通知按钮、点通知定位、
///   把手拖出、铃声已停）。应用被杀时原生接收器自己按"内容草案"弹通知并起铃；
///   事件先入队，Dart 启动后 `drainEvents` 取走。
///
/// 本文件不受 §2 import 矩阵约束（组装点装配），但不得被核心 import。
class AndroidNativeBridge {
  static const MethodChannel channel = MethodChannel('gtd/native');
  static const MethodChannel eventChannel = MethodChannel('gtd/native/events');

  final StreamController<Map<String, Object?>> _events =
      StreamController<Map<String, Object?>>.broadcast();

  /// 原生事件：{type: alarmFired|action|notificationTap|overlayHandleOpened, ...}
  Stream<Map<String, Object?>> get events => _events.stream;

  AndroidNativeBridge() {
    eventChannel.setMethodCallHandler((call) async {
      if (call.method == 'event' && call.arguments is Map) {
        _events.add(Map<String, Object?>.from(call.arguments as Map));
      }
      return null;
    });
  }

  /// 告诉原生"事件通道已就绪"，并把应用被杀期间入队的事件取回来回放。
  Future<void> markReady() async {
    await _invoke('notifyReady');
    await drain();
  }

  /// 取走原生侧入队的事件（冷启动/被杀期间的通知按钮等）。
  Future<void> drain() async {
    try {
      final raw = await channel.invokeListMethod<Object?>('drainEvents');
      for (final e in raw ?? const <Object?>[]) {
        if (e is Map) _events.add(Map<String, Object?>.from(e));
      }
    } catch (_) {
      // 原生侧不可用（老版本/桌面误装）：静默降级
    }
  }

  /// 整张站点表一次下发：原生逐站挂 `setAlarmClock()` 并把表存进 prefs，
  /// 开机 / 应用更新后由 `BootReceiver` 照表恢复，不需要 Dart 在跑。
  Future<bool> scheduleStations(
    List<AlarmStation> stations, {
    int ringSeconds = 60,
  }) =>
      _invoke('scheduleStations', {
        'stations': [
          for (final s in stations)
            {
              'atMillis': s.at.millisecondsSinceEpoch,
              'taskId': s.draft.taskId,
              'title': s.draft.title,
              'body': s.draft.body,
              'channel': s.draft.channel.name,
              'fullScreen': s.draft.fullScreen,
              'actions': _actionsArg(s.draft.actions),
            }
        ],
        // 到点那一刻应用可能已经被杀，接收器只能照这份 extras 起铃：响铃时长
        // 跟闹钟一起挂上去，别让原生自己去猜设置页里填的数。
        'ringSeconds': ringSeconds,
      });

  Future<bool> cancelAlarm() => _invoke('cancelAlarm');

  Future<bool> showNotification({
    required String taskId,
    required String title,
    String? body,
    ReminderChannel channel = ReminderChannel.ring,
    bool fullScreen = false,
    List<NotificationAction> actions = const [],
  }) =>
      _invoke('showNotification', {
        'taskId': taskId,
        'title': title,
        'body': body,
        'channel': channel.name,
        'fullScreen': fullScreen,
        'actions': _actionsArg(actions),
      });

  Future<bool> cancelNotification(String taskId) =>
      _invoke('cancelNotification', {'taskId': taskId});

  /// 起铃 / 续期（`AlarmRingPort.start`）：原生前台服务循环播放，到秒自停。
  ///
  /// [title] 只是停声后重投那条通知的文案；应用被杀那条路径由原生接收器自己带着
  /// 交付草案起铃，不经过这里。
  Future<bool> startRinging({
    required String taskId,
    required int seconds,
    String? title,
    String? body,
    List<NotificationAction> actions = const [],
  }) =>
      _invoke('startRinging', {
        'taskId': taskId,
        'title': title ?? '该做这件事了',
        'body': body,
        'seconds': seconds,
        // 停声后要重投"可划走"的那一份通知，渠道得是闹钟那条。
        'channel': ReminderChannel.alarm.name,
        'actions': _actionsArg(actions),
      });

  /// 提前停（`AlarmRingPort.stop`）：没在响就是空操作。
  Future<bool> stopRinging(String taskId) =>
      _invoke('stopRinging', {'taskId': taskId});

  Future<bool> canUseFullScreenIntent() => _invoke('canUseFullScreenIntent');

  /// 国产 ROM 的自启动 / 允许后台运行设置页：没有标准 API，只能跳厂商安全中心，
  /// 打不开就退到本应用的系统详情页。
  Future<bool> openBackgroundSettings() =>
      _invoke('openBackgroundSettings');

  Future<bool> requestFullScreenIntentPermission() =>
      _invoke('requestFullScreenIntentPermission');

  Future<bool> hasOverlayPermission() => _invoke('hasOverlayPermission');

  Future<bool> requestOverlayPermission() =>
      _invoke('requestOverlayPermission');

  /// 拉起 / 收起把手服务。**恒开**（§6.0）：装配点只传 true，
  /// 返回值 = 有没有真拉起来（缺悬浮窗权限 = false）。
  Future<bool> setOverlayHandle(bool enabled) =>
      _invoke('setOverlayHandle', {'enabled': enabled});

  /// 把手位置上锁（§6.0：锁上后竖向拖动不再改变 y；长按换边仍可用）。
  Future<bool> setHandleLocked(bool locked) =>
      _invoke('setHandleLocked', {'locked': locked});

  /// 把手热区宽度（dp，§6.0 / §9 第 10 条）：原生侧改的是把手窗口宽度与
  /// 系统手势排除区，服务没在跑也没关系——值落 prefs，下次 onCreate 会读到。
  Future<bool> setHandleHotWidth(int widthDp) =>
      _invoke('setHandleHotWidth', {'widthDp': widthDp});

  Future<bool> isIgnoringBatteryOptimizations() =>
      _invoke('isIgnoringBatteryOptimizations');

  /// 安装包的版本（§9 第 14 条）：`versionName` + `versionCode`，读不到 → null。
  ///
  /// 走自建通道而不是 `package_info_plus`：那个插件的安卓 Gradle 脚本自己
  /// apply 了 Kotlin Gradle Plugin，而 AGP 9 起 Kotlin 内置、Flutter 往后会禁掉
  /// 这条路（构建时会打一条 KGP 警告）。
  Future<({String version, String build})?> appVersion() async {
    try {
      final raw = await channel.invokeMapMethod<String, Object?>('appVersion');
      final version = raw?['version'];
      if (version is! String || version.isEmpty) return null;
      final build = raw?['build'];
      return (version: version, build: build is String ? build : '');
    } catch (_) {
      return null;
    }
  }

  /// 灵感文件（见 docs/panels/notes.md §6.2）：原生 SAF 挑一个文档，回**真实文件路径**
  /// （`/storage/…`），取消或换不出路径 → null。
  ///
  /// 不走 file_picker：它挑文件只会把原件复制进 App 缓存再回副本路径，写回就写进副本，
  /// Obsidian 里那份永远不动（挑目录是另一条分支，见 docs/decisions/2026-10-24-android-markdown-pick.md）。
  Future<String?> pickMarkdownFile() async {
    try {
      return await channel.invokeMethod<String>('pickMarkdownFile');
    } catch (_) {
      return null; // 原生不可用：调用方按 §11 退回手输
    }
  }

  Future<bool> _invoke(String method, [Map<String, Object?>? args]) async {
    try {
      final r = await channel.invokeMethod<Object?>(method, args);
      return r == true;
    } catch (_) {
      return false; // 原生不可用：调用方按 §11 降级
    }
  }

  static List<Map<String, String>> _actionsArg(
          List<NotificationAction> actions) =>
      [
        for (final a in actions) {'id': a.id, 'label': a.label}
      ];
}

/// 系统精确闹钟（AlarmManager + 原生接收器）。
class AndroidAlarmPort implements AlarmPort {
  final AndroidNativeBridge bridge;

  /// 响铃时长（秒）：挂闹钟那一刻一起写进 extras。
  ///
  /// 应用被杀时是原生接收器起铃，那一刻没有 Dart 可问 `alarm_ring_seconds`——所以这个
  /// 值必须随闹钟落地（settings.json 只有这一层读得到）。
  final int Function() ringSeconds;

  AndroidAlarmPort(this.bridge, {int Function()? ringSeconds})
      : ringSeconds = ringSeconds ?? _defaultRingSeconds;

  static int _defaultRingSeconds() => defaultAlarmRingSeconds;

  @override
  Future<void> scheduleStations(List<AlarmStation> stations) async {
    await bridge.scheduleStations(stations, ringSeconds: ringSeconds());
  }

  @override
  Future<void> cancel() async {
    await bridge.cancelAlarm();
  }

  /// 原生接收器到点会**先自己投递**通知（应用被杀也照弹），再回传事件；
  /// `delivered` 就是从这次投递的返回值来的。事件还带这一站的原定时刻与交付草案，
  /// 分发器据此按站记账（`docs/sockets/delivery.md`）。
  @override
  Stream<FiredAlarm> get fired => bridge.events
      .where((e) => e['type'] == 'alarmFired')
      .map(_firedFrom)
      .where((f) => f.taskId.isNotEmpty);

  /// `alarmFired` → [FiredAlarm]。键名与原生 `ReminderExtras` 一致；缺项
  /// （升级前入队的事件，那时只有 taskId 与 delivered）留 null，分发器走旧路径。
  static FiredAlarm _firedFrom(Map<String, Object?> event) {
    final taskId = event['taskId'] as String? ?? '';
    final atMillis = event['atMillis'];
    final title = event['title'] as String?;
    return FiredAlarm(
      taskId,
      delivered: event['delivered'] as bool? ?? false,
      at: atMillis is num
          ? DateTime.fromMillisecondsSinceEpoch(atMillis.toInt())
          : null,
      stationKey: event['stationKey'] as String?,
      draft: (title == null || title.isEmpty)
          ? null
          : ReminderDraft(
              taskId: taskId,
              title: title,
              body: event['body'] as String?,
              channel: _channelOf(event['channel']),
              fullScreen: event['fullScreen'] as bool? ?? false,
              actions: _actionsOf(event['actionIds'], event['actionLabels']),
            ),
    );
  }

  /// 渠道名按小写认（原生写的是枚举名小写），认不出按普通提醒。
  static ReminderChannel _channelOf(Object? raw) {
    final name = raw is String ? raw.toLowerCase() : '';
    for (final c in ReminderChannel.values) {
      if (c.name == name) return c;
    }
    return ReminderChannel.ring;
  }

  /// 按钮按下标配对（两边长度不一致时缺的 label 退回 id，与原生同一口径）。
  static List<NotificationAction> _actionsOf(Object? ids, Object? labels) {
    if (ids is! List) return const [];
    final out = <NotificationAction>[];
    for (var i = 0; i < ids.length; i++) {
      final id = ids[i];
      if (id is! String || id.isEmpty) continue;
      final label = labels is List && i < labels.length && labels[i] is String
          ? labels[i] as String
          : id;
      out.add(NotificationAction(id: id, label: label));
    }
    return out;
  }
}

/// 系统通知（动作按钮 / 全屏闹钟 / 点通知定位）。
///
/// `shown` 为空流：系统通知不回流给本应用 UI（桌面的"托盘=窗口"语义在安卓
/// 不成立）；按钮与点击走 [AndroidNativeBridge.events] 回传。
class AndroidNotificationPort implements NotificationPort {
  final AndroidNativeBridge bridge;

  /// 通知正文数据来源（taskId → 任务）；null 时用通用文案。
  final Task? Function(String taskId)? lookup;

  AndroidNotificationPort(this.bridge, {this.lookup});

  @override
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.ring,
    bool fullScreen = false,
    ReminderDraft? draft,
  }) async {
    final task = lookup?.call(event.taskId);
    await bridge.showNotification(
      taskId: event.taskId,
      title: draft?.title ?? task?.title ?? '该做这件事了',
      body: draft?.body ?? _bodyOf(task),
      channel: channel,
      fullScreen: fullScreen,
      actions: actions,
    );
  }

  @override
  Stream<ShownNotification> get shown => const Stream.empty();

  /// 兜底文案：只在调用方**没带** [ReminderDraft.body] 时才会用到（正常路径
  /// 总带）。文案的唯一来源是 `ReminderDispatcher._bodyOf`——它认识调度模式
  /// （无排序档不报"剩余 N 分钟"，那是拿缺省 30 分钟编的）。这里只留中性时刻，
  /// 不要在这里重造一套口径。
  static String? _bodyOf(Task? task) {
    if (task == null) return null;
    final d = task.deadline;
    if (d == null) return null;
    return '到点 ${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}

/// 持续响铃（ui-interaction.md §7.2）：循环、前台服务、wakelock 都在原生
/// `AlarmRingService` 里，这层只下命令。
///
/// 两条起铃路径都落到同一个服务：应用被杀时由 `ReminderReceiver` 照交付草案起铃，
/// 应用活着时由分发器经这里起（同一件重复 start 只是续期，不叠声）。
class AndroidAlarmRingPort implements AlarmRingPort {
  final AndroidNativeBridge bridge;

  /// 停声后重投那条通知的文案来源（与 [AndroidNotificationPort] 同一个 lookup）。
  final Task? Function(String taskId)? lookup;

  String? _ringing;

  AndroidAlarmRingPort(this.bridge, {this.lookup}) {
    // 全屏页与通知按钮也能停声（纯原生那条路）：停完回一条事件，这里才知道
    // "已经不响了"，别对着一个早就停掉的铃声报 [ringingTaskId]。
    bridge.events
        .where((e) => e['type'] == 'ringStopped')
        .listen(_onRingStopped);
  }

  void _onRingStopped(Map<String, Object?> event) {
    final id = event['taskId'] as String?;
    if (id == null || id.isEmpty || id == _ringing) _ringing = null;
  }

  @override
  Future<void> start(String taskId, {required int seconds}) async {
    final task = lookup?.call(taskId);
    final ok = await bridge.startRinging(
      taskId: taskId,
      seconds: seconds,
      title: task?.title,
    );
    // 原生拒绝（Android 12+ 后台启动受限 / 厂商拦截）时不假装在响：这条提醒还剩
    // 通知栏那条路，分发器不用知道，[ringingTaskId] 说实话。
    _ringing = ok ? taskId : null;
  }

  @override
  Future<void> stop(String taskId) async {
    await bridge.stopRinging(taskId);
    if (_ringing == taskId) _ringing = null;
  }

  @override
  String? get ringingTaskId => _ringing;
}

/// 权限引导（permission_handler + 原生全屏 intent / 悬浮窗查询）。
/// 被拒一律返回 false，调用方按 ui-interaction.md §11 优雅降级。
class AndroidPermissionPort implements PermissionPort {
  final AndroidNativeBridge bridge;

  AndroidPermissionPort(this.bridge);

  @override
  Future<bool> ensure(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.notifications:
        return (await Permission.notification.request()).isGranted;
      case PermissionKind.exactAlarm:
        return (await Permission.scheduleExactAlarm.request()).isGranted;
      case PermissionKind.batteryExemption:
        return (await Permission.ignoreBatteryOptimizations.request())
            .isGranted;
      case PermissionKind.overlayWindow:
        return (await Permission.systemAlertWindow.request()).isGranted;
      case PermissionKind.showOnLockScreen:
        return bridge.requestFullScreenIntentPermission();
      case PermissionKind.folderAccess:
        return (await Permission.manageExternalStorage.request()).isGranted;
    }
  }

  @override
  Future<bool> granted(PermissionKind kind) async {
    switch (kind) {
      case PermissionKind.notifications:
        return Permission.notification.isGranted;
      case PermissionKind.exactAlarm:
        return Permission.scheduleExactAlarm.isGranted;
      case PermissionKind.batteryExemption:
        return Permission.ignoreBatteryOptimizations.isGranted;
      case PermissionKind.overlayWindow:
        return Permission.systemAlertWindow.isGranted;
      case PermissionKind.showOnLockScreen:
        return bridge.canUseFullScreenIntent();
      case PermissionKind.folderAccess:
        return Permission.manageExternalStorage.isGranted;
    }
  }
}

/// 任务目录选择（决议：所有文件访问 + 系统目录选择器）。
/// 未授予"所有文件访问"时先申请；选择器取消 → null（UI 保持原目录）。
class AndroidFolderPickerPort implements FolderPickerPort {
  final AndroidPermissionPort permissions;
  final AndroidNativeBridge bridge;

  AndroidFolderPickerPort(this.permissions, this.bridge);

  @override
  Future<String?> pickDirectory() async {
    if (!await permissions.granted(PermissionKind.folderAccess)) {
      final ok = await permissions.ensure(PermissionKind.folderAccess);
      if (!ok) return null;
    }
    try {
      return await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择任务目录（Obsidian 可直接打开）',
      );
    } catch (_) {
      return null;
    }
  }

  /// 灵感文件（ui §6.2）：所有文件访问打底，然后走原生 SAF 拿**真实路径**。
  ///
  /// file_picker 挑目录回真实路径（`getFullPathFromTreeUri`），挑文件却先复制进
  /// `<缓存目录>/file_picker/<时间戳>/<文件名>` 再回副本——写回就写进副本，
  /// Obsidian 里那份永远不动，缓存一清灵感页就空。所以文件这条自己发 SAF。
  /// [allowedExtensions] 只作提示：选择器不按它过滤（`.md` 的 MIME 各 ROM 不一，
  /// 过滤条件对不上文件就是灰的），类型由调用方验。
  @override
  Future<String?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  }) async {
    if (!await permissions.granted(PermissionKind.folderAccess)) {
      final ok = await permissions.ensure(PermissionKind.folderAccess);
      if (!ok) return null;
    }
    final path = await bridge.pickMarkdownFile();
    return (path == null || path.trim().isEmpty) ? null : path;
  }
}
