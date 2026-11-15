import '../domain/reminder.dart';

/// 交付类插座（§4.2）：application 定义形状，平台适配器实现，组装点装配。
/// 适配器无自主权——只执行"取消旧的、挂新的"，不得自行重排或补挂。

/// 通知渠道三档（`Notifier` 的三个原生渠道一一对应）：
///
/// - [ring]   **有声**：高优先级 + 声音 + 震动。高优先级 = 一定弹横幅（heads-up），
///   这是提醒的默认形态；
/// - [silent] **静音**：同样高优先级、横幅照弹，但没有声音与震动——编排条目的
///   到点消息恒走这一条；
/// - [alarm]  **闹钟**：全屏 + 持续响铃（媒体静音压不住），只在任务自己的
///   metadata `alarm` 打开、且这条是时点提醒时用，**覆盖**掉它本该走的那条通知栏投递。
enum ReminderChannel { ring, silent, alarm }

/// 平台权限（安卓为主）。被拒时调用方按 UI 文档 §11 降级。
enum PermissionKind {
  notifications,      // 通知
  exactAlarm,         // 精确闹钟（安卓 12+）
  batteryExemption,   // 电池优化白名单（Doze 会吞闹钟）
  overlayWindow,      // 悬浮侧边栏（SYSTEM_ALERT_WINDOW）
  showOnLockScreen,   // 全屏提醒（锁屏/上层显示）
  folderAccess,       // 任务目录（所有文件访问 或 SAF）
}

/// 通知上的快捷按钮（如 done / snooze1h）。
class NotificationAction {
  final String id;
  final String label;

  const NotificationAction({required this.id, required this.label});
}

/// 一次已呈现的提醒（桌面的"托盘"就是应用窗口：适配器回流给 UI 渲染）。
class ShownNotification {
  final ReminderEvent event;
  final List<NotificationAction> actions;
  final ReminderChannel channel;
  final bool fullScreen;

  /// 交付内容的定稿（标题 / 正文 / 渠道 / 按钮）。**编排条目的提醒只有它有标题**：
  /// 事件里的 id 不是任务，UI 查不到人，渲染只能照这份草案来。
  final ReminderDraft? draft;

  const ShownNotification({
    required this.event,
    this.actions = const [],
    this.channel = ReminderChannel.ring,
    this.fullScreen = false,
    this.draft,
  });
}

/// 闹钟到点时要交付的内容草案（§4.3）。
///
/// 桌面不需要它（到点后由应用程序自己 show）；**安卓需要**：系统闹钟到点时
/// 应用可能已被杀，原生接收器只能照着挂闹钟时留下的草案自己弹通知——
/// 因此 ReminderDispatcher 在 `scheduleStations` 时就要把标题/渠道/按钮定下来。
class ReminderDraft {
  final String taskId;
  final String title;
  final String? body;
  final ReminderChannel channel;
  final bool fullScreen;
  final List<NotificationAction> actions;

  const ReminderDraft({
    required this.taskId,
    required this.title,
    this.body,
    this.channel = ReminderChannel.ring,
    this.fullScreen = false,
    this.actions = const [],
  });
}

/// 一个待触发的站点（§4.3）。静态站点（时点提醒、编排）重锚时一次排全交给
/// 原生存盘，到点由原生自己投递，不依赖 Dart 进程还在。
class AlarmStation {
  final DateTime at;

  /// 到点要交付什么，在挂站那一刻定稿。
  final ReminderDraft draft;

  const AlarmStation({required this.at, required this.draft});

  /// 站点 id = 交付草案的目标，Dart 与原生回传事件都用它认人。
  String get id => draft.taskId;
}

abstract class NotificationPort {
  /// 呈现一条提醒。安卓 = 系统通知（[ReminderChannel.alarm] 且 fullScreen 时走
  /// full-screen intent）；桌面 = 应用内弹窗（经 [shown] 回流，渠道不参与渲染）。[draft] 提供标题/正文等交付内容，
  /// 系统通知实现（没法自己查任务）用它渲染文案。
  Future<void> show(
    ReminderEvent event, {
    List<NotificationAction> actions = const [],
    ReminderChannel channel = ReminderChannel.ring,
    bool fullScreen = false,
    ReminderDraft? draft,
  });

  /// 已呈现的提醒流（UI 渲染用）。系统通知实现可返回空流（事件为空）。
  Stream<ShownNotification> get shown;
}

/// 持续响铃（§7.2）：**与通知分开的一条通道**——通知是"留在那儿的消息"，铃声是
/// "现在就要你注意"。两者生命周期不同：通知停声后还在，铃声到点必须自己停。
///
/// 到 [seconds] 自停；[stop] 供全屏闹钟页与通知按钮提前停。没有这个能力的壳
/// （桌面、测试）注入 null，分发器就只投通知、不起铃。
abstract class AlarmRingPort {
  /// 起铃并循环播放，[seconds] 秒后自停。重复起同一件视为续期，不叠声。
  Future<void> start(String taskId, {required int seconds});

  /// 提前停（全屏页 / 通知按钮）。没在响时是空操作。
  Future<void> stop(String taskId);

  /// 正在响的那一件；null = 没在响。全屏页据此决定要不要显示『停止响铃』。
  String? get ringingTaskId;
}

/// 一次闹钟到点回调。
///
/// [delivered] = **系统侧已经把这条提醒弹给用户了**：安卓的原生接收器照着挂
/// 闹钟时留下的 [ReminderDraft] 自己投递（应用被杀也照弹），桌面没有这一层，
/// 永远是 false。分发器据此决定还要不要自己 show——不判断就是同一条提醒弹
/// 两遍：同 id 替换、重新响铃，通知的时刻被刷成"现在"，看起来像提醒迟到。
///
/// [at] / [stationKey] / [draft] 是**这一站的身份**：哪一格、原定几点、挂站那一刻
/// 定稿的交付内容。应用被杀期间原生会按站点表连续投递多站，事件攒在队列里、下次
/// 启动一次回放；只有 taskId 时 Dart 只能按"现在"重算该弹谁，几条叠在一起就会把
/// `point_fired` 记到错的那件上（docs/sockets/reminder.md）。
class FiredAlarm {
  final String taskId;
  final bool delivered;

  /// 站点表里这一格的原定时刻（原生 `ReminderExtras.AT_MILLIS`）；
  /// null = 事件没带（桌面 Timer、升级前入队的事件）。
  final DateTime? at;

  /// 站点表主键 `<taskId>@<atMillis>`（原生 `ReminderExtras.STATION_KEY`）。
  final String? stationKey;

  /// 挂站那一刻定稿的交付草案（标题 / 正文 / 渠道 / 全屏 / 按钮）。
  final ReminderDraft? draft;

  const FiredAlarm(
    this.taskId, {
    this.delivered = false,
    this.at,
    this.stationKey,
    this.draft,
  });

  /// 带站点身份 = 分发器能按这一站记账与补投；false 走 `pollReminder` 旧路径。
  bool get hasStation => at != null && draft != null;
}

/// 系统闹钟插座（§4.3）。调用方一次下发整张站点表，适配器负责把它们保住：
/// 安卓逐站挂进 AlarmManager 并存进原生 prefs，开机自行恢复；桌面只取最早一站。
abstract class AlarmPort {
  /// 用整张站点表替换当前所有闹钟：先取消旧的，再逐站挂上。
  Future<void> scheduleStations(List<AlarmStation> stations);

  Future<void> cancel();

  /// 到点事件。安卓 = 系统闹钟回调转发（带"已投递"标记）；桌面 = Timer（未投递）。
  Stream<FiredAlarm> get fired;
}

/// 目录/文件选择（安卓 SAF / 桌面系统选择器）。
abstract class FolderPickerPort {
  Future<String?> pickDirectory();

  /// 挑一个文件（灵感路径，ui §6.2 / §9 第 5 条）；取消或平台不支持 → null。
  /// [allowedExtensions] 为空 = 不限制类型。
  Future<String?> pickFile({
    required String dialogTitle,
    required List<String> allowedExtensions,
  });
}

/// 权限申请与查询。
abstract class PermissionPort {
  /// 申请（必要时弹系统界面）；被拒返回 false，调用方优雅降级。
  Future<bool> ensure(PermissionKind kind);

  /// 只查询当前是否已授予（设置页展示用，不弹界面）。
  Future<bool> granted(PermissionKind kind);
}
