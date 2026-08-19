import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'models/open_loop.dart';
import 'services/external_integrations.dart';
import 'services/shared_capture.dart';

final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class OpenLoopApp extends StatefulWidget {
  const OpenLoopApp({super.key, required this.controller});
  final AppController controller;
  @override
  State<OpenLoopApp> createState() => _OpenLoopAppState();
}

class _OpenLoopAppState extends State<OpenLoopApp> {
  final navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<List<SharedMediaFile>>? shareSubscription;
  SharedCapturePayload? _queuedShare;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
    _listenForShares();
    AppIntegrations.instance.pendingLoopId.addListener(_openPushLoop);
  }

  Future<void> _initialize() async {
    await widget.controller.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.enableAutomaticReminders());
    });
    final queuedShare = _queuedShare;
    _queuedShare = null;
    if (queuedShare != null) _presentSharedCapture(queuedShare);
  }

  void _openPushLoop() {
    final id = AppIntegrations.instance.pendingLoopId.value;
    if (id == null || !widget.controller.ready) return;
    if (!widget.controller.loops.any((loop) => loop.id == id)) return;
    navigatorKey.currentState?.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            LoopDetailScreen(controller: widget.controller, loopId: id),
      ),
    );
    AppIntegrations.instance.pendingLoopId.value = null;
  }

  Future<void> _listenForShares() async {
    try {
      shareSubscription = ReceiveSharingIntent.instance.getMediaStream().listen(
        _openSharedMedia,
        onError: (_) {},
      );
      _openSharedMedia(await ReceiveSharingIntent.instance.getInitialMedia());
    } catch (_) {
      // Sharing is unavailable on web and some test hosts; normal capture remains usable.
    }
  }

  void _openSharedMedia(List<SharedMediaFile> items) {
    final capture = normalizeSharedMedia(items);
    if (capture.isEmpty) return;
    ReceiveSharingIntent.instance.reset();
    if (!widget.controller.ready) {
      _queuedShare = capture;
      return;
    }
    _presentSharedCapture(capture);
  }

  void _presentSharedCapture(SharedCapturePayload capture) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = navigatorKey.currentState;
      if (navigator == null) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => CaptureScreen(
            controller: widget.controller,
            initialText: capture.text,
            initialImagePath: capture.imagePath,
            autoAnalyze: true,
          ),
        ),
      );
    });
  }

  @override
  void dispose() {
    shareSubscription?.cancel();
    AppIntegrations.instance.pendingLoopId.removeListener(_openPushLoop);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => MaterialApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'OpenLoop',
      debugShowCheckedModeBanner: false,
      theme: openLoopTheme(),
      darkTheme: openLoopDarkTheme(),
      themeMode: widget.controller.themeMode,
      themeAnimationDuration: const Duration(milliseconds: 250),
      themeAnimationCurve: Curves.easeInOutCubic,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('ko', 'KR'),
        Locale('en', 'US'),
      ],
      locale: const Locale('ko', 'KR'),
      home: widget.controller.ready
          ? HomeScreen(controller: widget.controller)
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    ),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum HomeFilter {
  all('전체'),
  urgent('임박'),
  closed('종료'),
  coupon('쿠폰'),
  schedule('일정'),
  place('장소');

  const HomeFilter(this.label);
  final String label;
}

bool isLoopExpired(OpenLoop loop, [DateTime? referenceTime]) {
  if (loop.state == LoopState.closed) return true;
  final now = referenceTime ?? DateTime.now();

  if (loop.expiresOn != null) {
    final endOfExpiry = DateTime(
      loop.expiresOn!.year,
      loop.expiresOn!.month,
      loop.expiresOn!.day,
      23,
      59,
      59,
    );
    if (endOfExpiry.isBefore(now)) return true;
  } else if (loop.date != null) {
    int hour = 23;
    int minute = 59;
    if (loop.time != null && loop.time!.trim().isNotEmpty) {
      final timeParts = loop.time!.split(':');
      if (timeParts.length >= 2) {
        hour = int.tryParse(timeParts[0]) ?? 23;
        minute = int.tryParse(timeParts[1]) ?? 59;
      }
    }
    final loopEnd = DateTime(
      loop.date!.year,
      loop.date!.month,
      loop.date!.day,
      hour,
      minute,
      59,
    );
    if (loopEnd.isBefore(now)) return true;
  }
  return false;
}

bool isLoopUrgent(OpenLoop loop, [DateTime? referenceTime]) {
  if (loop.state == LoopState.closed || isLoopExpired(loop, referenceTime)) {
    return false;
  }
  final now = referenceTime ?? DateTime.now();

  final targetDate = loop.date ?? loop.expiresOn;
  if (targetDate != null) {
    int hour = 23;
    int minute = 59;
    if (loop.time != null && loop.time!.trim().isNotEmpty) {
      final timeParts = loop.time!.split(':');
      if (timeParts.length >= 2) {
        hour = int.tryParse(timeParts[0]) ?? 23;
        minute = int.tryParse(timeParts[1]) ?? 59;
      }
    }

    final loopDateTime = DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
      hour,
      minute,
    );
    final difference = loopDateTime.difference(now);

    // 0초 이상 미래, 3일(72시간) 이내에 도래하는 활성 일정/마감/쿠폰
    if (difference.inSeconds >= 0 && difference.inDays <= 3) {
      return true;
    }
  }

  for (final cp in loop.checkpoints) {
    if (!cp.completed && cp.dueAt != null) {
      final diff = cp.dueAt!.difference(now);
      if (diff.inSeconds >= 0 && diff.inDays <= 3) {
        return true;
      }
    }
  }

  return false;
}

class _HomeScreenState extends State<HomeScreen> {
  HomeFilter filter = HomeFilter.all;

  List<OpenLoop> _filterLoops(List<OpenLoop> loops, HomeFilter targetFilter) {
    return switch (targetFilter) {
      HomeFilter.all => loops
          .where((l) => l.state != LoopState.closed && !isLoopExpired(l))
          .toList(),
      HomeFilter.urgent => loops.where(isLoopUrgent).toList(),
      HomeFilter.coupon => loops
          .where(
            (l) =>
                l.kind == LoopKind.coupon &&
                l.state != LoopState.closed &&
                !isLoopExpired(l),
          )
          .toList(),
      HomeFilter.schedule => loops
          .where(
            (l) =>
                (l.kind == LoopKind.appointment ||
                    l.kind == LoopKind.deadline ||
                    l.kind == LoopKind.reservation) &&
                l.state != LoopState.closed &&
                !isLoopExpired(l),
          )
          .toList(),
      HomeFilter.place => loops
          .where(
            (l) =>
                (l.kind == LoopKind.place ||
                    (l.place != null && l.place!.trim().isNotEmpty)) &&
                l.state != LoopState.closed,
          )
          .toList(),
      HomeFilter.closed => loops
          .where((l) => l.state == LoopState.closed || isLoopExpired(l))
          .toList(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final allLoops = widget.controller.loops;
    final loops = _filterLoops(allLoops, filter);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 110),
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                key: const Key('settings-button'),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SettingsScreen(controller: widget.controller),
                  ),
                ),
                icon: const Icon(Icons.settings_outlined, size: 24),
                tooltip: '설정',
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '공유하면\n바로 정리해요.',
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? Colors.white
                    : OLColors.navy,
                fontSize: 32,
                height: 1.2,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.2,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '일정·장소·쿠폰을 구분하고 필요한 정보만 물어봅니다.',
              style: TextStyle(
                color: Theme.of(context).brightness == Brightness.dark
                    ? OLColors.darkMuted
                    : OLColors.muted,
                fontSize: 15,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 24),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  for (final item in HomeFilter.values)
                    _FilterChip(
                      key: Key('filter-chip-${item.name}'),
                      label: item.label,
                      selected: filter == item,
                      count: _filterLoops(allLoops, item).length,
                      onTap: () => setState(() => filter = item),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (loops.isEmpty)
              if (allLoops.isEmpty)
                const _EmptyLoops()
              else
                _EmptyFilterLoops(filter: filter)
            else
              ...loops.map(
                (loop) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: LoopCard(
                    loop: loop,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LoopDetailScreen(
                          controller: widget.controller,
                          loopId: loop.id,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('capture-button'),
        onPressed: () {
          AppIntegrations.instance.capture('capture_started');
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => CaptureScreen(controller: widget.controller),
            ),
          );
        },
        backgroundColor: OLColors.cobalt,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          '일정 추가',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }
}

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({
    super.key,
    required this.controller,
    this.initialText = '',
    this.initialImagePath,
    this.autoAnalyze = false,
  });
  final AppController controller;
  final String initialText;
  final String? initialImagePath;
  final bool autoAnalyze;
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late final TextEditingController textController;
  String source = 'text';
  XFile? image;
  String? error;
  String? notice;
  bool analysisStarted = false;

  @override
  void initState() {
    super.initState();
    textController = TextEditingController(text: widget.initialText);
    if (widget.initialImagePath != null) {
      image = XFile(widget.initialImagePath!);
      source = 'image';
    }
    if (widget.autoAnalyze &&
        (textController.text.trim().isNotEmpty || image != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_analyze());
      });
    }
  }

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  Future<void> _pickImage(ImageSource imageSource) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: imageSource,
        imageQuality: 82,
      );
      if (picked != null && mounted) {
        setState(() {
          image = picked;
          source = imageSource == ImageSource.camera ? 'screenshot' : 'image';
          error = null;
          notice = null;
        });
        unawaited(_analyze());
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = '사진 권한이 없거나 이미지를 열 수 없습니다. 텍스트로 계속할 수 있어요.');
      }
    }
  }

  Future<void> _analyze() async {
    if (analysisStarted) return;
    final text = textController.text.trim();
    if (text.isEmpty && image == null) {
      setState(() => error = '분석할 텍스트나 이미지를 추가해 주세요.');
      return;
    }
    setState(() {
      error = null;
      analysisStarted = true;
    });
    final result = image == null
        ? widget.controller.analyze(text: text, source: source)
        : widget.controller.analyzeImage(
            imagePath: image!.path,
            companionText: text,
            source: source,
          );
    try {
      final failure = await Navigator.push<String>(
        context,
        MaterialPageRoute<String>(
          builder: (_) =>
              ProcessingScreen(result: result, controller: widget.controller),
        ),
      );
      if (failure != null && mounted) setState(() => error = failure);
    } finally {
      if (mounted) setState(() => analysisStarted = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('일정 추가')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          '사진을 고르면 바로 분석하고, 텍스트는 붙여 넣은 뒤 분석할 수 있어요.',
          style: TextStyle(color: OLColors.muted),
        ),
        const SizedBox(height: 22),
        TextField(
          key: const Key('capture-text'),
          controller: textController,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(hintText: '대화, 공지, 예약 내용을 붙여 넣으세요'),
          onChanged: (_) {
            if (image == null) setState(() => source = 'text');
          },
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('카메라'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_outlined),
                label: const Text('사진·스크린샷'),
              ),
            ),
          ],
        ),
        if (image != null) ...[
          const SizedBox(height: 12),
          const Text(
            '이미지 1장을 바로 분석합니다.',
            style: TextStyle(color: OLColors.muted),
          ),
          const SizedBox(height: 8),
          ListTile(
            tileColor: OLColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            leading: const Icon(Icons.image_outlined),
            title: Text(
              image!.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '이미지 제거',
              onPressed: () => setState(() {
                image = null;
                if (textController.text.trim().isNotEmpty) source = 'text';
              }),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: OLColors.warning)),
        ],
        if (notice != null) ...[
          const SizedBox(height: 12),
          _InfoBanner(text: notice!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('analyze-button'),
          onPressed: analysisStarted ? null : _analyze,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 17),
          ),
          child: Text(
            analysisStarted ? '일정 분석 중…' : '일정 분석',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ),
  );
}

class ProcessingScreen extends StatefulWidget {
  const ProcessingScreen({
    super.key,
    required this.result,
    required this.controller,
  });
  final Future<OpenLoop> result;
  final AppController controller;
  @override
  State<ProcessingScreen> createState() => _ProcessingScreenState();
}

class _ProcessingScreenState extends State<ProcessingScreen> {
  @override
  void initState() {
    super.initState();
    _complete();
  }

  Future<void> _complete() async {
    try {
      final loop = await widget.result;
      if (!mounted) return;
      final hasMissing = loop.effectiveMissingFields.isNotEmpty;
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) => (loop.state == LoopState.needsInput && hasMissing)
              ? AmbiguityScreen(controller: widget.controller, loop: loop)
              : ReviewScreen(controller: widget.controller, loop: loop),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.pop(context, '일정을 분석하지 못했습니다. 네트워크 연결을 확인하고 다시 시도해 주세요.');
    }
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 20),
          Text('최종 합의와 빠진 정보를 찾는 중…'),
        ],
      ),
    ),
  );
}

class AmbiguityScreen extends StatefulWidget {
  const AmbiguityScreen({
    super.key,
    required this.controller,
    required this.loop,
  });
  final AppController controller;
  final OpenLoop loop;
  @override
  State<AmbiguityScreen> createState() => _AmbiguityScreenState();
}

/// Returns the API's `HH:mm:ss` representation for the compact Korean time
/// formats a user can comfortably enter with a phone keyboard.
String? normalizeTimeInput(String raw) {
  final compact = raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty) return null;

  String? period;
  int? hour;
  int minute = 0;
  final digits = RegExp(r'^\d{3,4}$').firstMatch(compact);
  if (digits != null) {
    final value = digits.group(0)!;
    hour = int.tryParse(value.substring(0, value.length - 2));
    minute = int.tryParse(value.substring(value.length - 2)) ?? 0;
  } else {
    final match = RegExp(
      r'^(오전|오후|am|pm)?(\d{1,2})(?:(?::|시)(\d{1,2})?)?(?:분)?$',
    ).firstMatch(compact);
    if (match == null) return null;
    period = match.group(1);
    hour = int.tryParse(match.group(2)!);
    minute = int.tryParse(match.group(3) ?? '') ?? 0;
  }

  if (hour == null || minute > 59) return null;
  if (period == '오후' || period == 'pm') {
    if (hour >= 1 && hour <= 11) hour += 12;
  } else if (period == '오전' || period == 'am') {
    if (hour == 12) hour = 0;
  }
  if (hour > 23) return null;
  return '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';
}

String _editableTime(String? value) =>
    value == null ? '' : value.split(':').take(2).join(':');

Future<DateTime?> showAdaptiveDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  DateTime? firstDate,
  DateTime? lastDate,
}) async {
  final isIOS = !kIsWeb && Platform.isIOS;
  if (isIOS) {
    DateTime picked = initialDate;
    final min = firstDate ?? DateTime.now().subtract(const Duration(days: 365));
    final max = lastDate ?? DateTime.now().add(const Duration(days: 3650));
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => Container(
        height: 280,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Container(
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: CupertinoColors.separator,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: const Text(
                        '취소',
                        style: TextStyle(color: CupertinoColors.systemGrey),
                      ),
                      onPressed: () => Navigator.pop(context, false),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: const Text(
                        '완료',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: OLColors.cobalt,
                        ),
                      ),
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  initialDateTime: initialDate,
                  minimumDate: min,
                  maximumDate: max,
                  onDateTimeChanged: (dt) => picked = dt,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return (confirmed == true) ? picked : null;
  } else {
    return showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: firstDate ?? DateTime.now().subtract(const Duration(days: 365)),
      lastDate: lastDate ?? DateTime.now().add(const Duration(days: 3650)),
    );
  }
}

Future<TimeOfDay?> showAdaptiveTimePicker(
  BuildContext context, {
  required int initialHour,
  required int initialMinute,
}) async {
  final isIOS = !kIsWeb && Platform.isIOS;
  if (isIOS) {
    DateTime picked = DateTime(2000, 1, 1, initialHour, initialMinute);
    final confirmed = await showCupertinoModalPopup<bool>(
      context: context,
      builder: (context) => Container(
        height: 280,
        color: CupertinoColors.systemBackground.resolveFrom(context),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              Container(
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: CupertinoColors.separator,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: const Text(
                        '취소',
                        style: TextStyle(color: CupertinoColors.systemGrey),
                      ),
                      onPressed: () => Navigator.pop(context, false),
                    ),
                    CupertinoButton(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: const Text(
                        '완료',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: OLColors.cobalt,
                        ),
                      ),
                      onPressed: () => Navigator.pop(context, true),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.time,
                  initialDateTime:
                      DateTime(2000, 1, 1, initialHour, initialMinute),
                  use24hFormat: false,
                  onDateTimeChanged: (dt) => picked = dt,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return (confirmed == true)
        ? TimeOfDay(hour: picked.hour, minute: picked.minute)
        : null;
  } else {
    return showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: initialHour, minute: initialMinute),
    );
  }
}

TimeOfDay _timeOfDayOrDefault(String value, TimeOfDay fallback) {
  final normalized = normalizeTimeInput(value);
  if (normalized == null) return fallback;
  final parts = normalized.split(':');
  return TimeOfDay(
    hour: int.tryParse(parts.first) ?? fallback.hour,
    minute: int.tryParse(parts[1]) ?? fallback.minute,
  );
}

class _AmbiguityScreenState extends State<AmbiguityScreen> {
  DateTime? selectedDate;
  late final TextEditingController textController;
  late final TextEditingController timeController;

  String get field => widget.loop.effectiveMissingFields.firstOrNull ?? 'title';

  List<String> get _participants => textController.text
      .split(RegExp(r'[,\n]'))
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();

  @override
  void initState() {
    super.initState();
    if (widget.loop.effectiveMissingFields.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ReviewScreen(
                controller: widget.controller,
                loop: widget.loop.copyWith(state: LoopState.open),
              ),
            ),
          );
        }
      });
      return;
    }
    selectedDate = field == 'expires_on'
        ? widget.loop.expiresOn
        : widget.loop.date;
    textController = TextEditingController(
      text: switch (field) {
        'place' => widget.loop.place ?? '',
        'title' => widget.loop.title == '새 Open Loop' ? '' : widget.loop.title,
        'purpose' => widget.loop.purpose ?? '',
        'participants' => widget.loop.participants.join(', '),
        _ => '',
      },
    );
    timeController = TextEditingController(
      text: _editableTime(widget.loop.time),
    );
  }

  @override
  void dispose() {
    textController.dispose();
    timeController.dispose();
    super.dispose();
  }

  String get _displayTitle {
    final t = widget.loop.title.trim();
    if (t.isEmpty || t == '새 Open Loop') return '일정';
    return t;
  }

  String get question {
    final suggested = widget.loop.suggestedQuestion?.trim();
    if (suggested != null && suggested.isNotEmpty) {
      final isPlaceQ = suggested.contains('장소') || suggested.contains('어디');

      if (field == 'place' && isPlaceQ) {
        return suggested;
      }
      if (field == 'date' &&
          suggested.contains('날짜') &&
          !suggested.contains('시간')) {
        return suggested;
      }
      if (field == 'start_time' &&
          suggested.contains('시간') &&
          !suggested.contains('날짜')) {
        return suggested;
      }
      if (field == 'start_time' && suggested.contains('날짜와 시간')) {
        return suggested.replaceAll('날짜와 시간', '시간');
      }
      if (field == 'date' && suggested.contains('날짜와 시간')) {
        return suggested.replaceAll('날짜와 시간', '날짜');
      }
    }
    return switch (field) {
      'place' => '$_displayTitle 장소는 어디인가요?',
      'date' => '$_displayTitle 날짜를 언제로 정할까요?',
      'start_time' => '$_displayTitle 시작 시간을 몇 시로 정할까요?',
      'expires_on' => '$_displayTitle 유효기간이 언제까지인가요?',
      'title' => '일정 제목을 무엇으로 정할까요?',
      'purpose' => '$_displayTitle의 목적이나 내용은 무엇인가요?',
      'participants' => '$_displayTitle에 누구와 함께하나요?',
      _ => '$_displayTitle 세부 정보를 확인해 주세요',
    };
  }

  Object? get value => switch (field) {
    'start_time' => normalizeTimeInput(timeController.text),
    'date' || 'expires_on' =>
      selectedDate == null
          ? null
          : '${selectedDate!.year.toString().padLeft(4, '0')}-${selectedDate!.month.toString().padLeft(2, '0')}-${selectedDate!.day.toString().padLeft(2, '0')}',
    'participants' => _participants.isEmpty ? null : _participants,
    _ => textController.text.trim().isEmpty ? null : textController.text.trim(),
  };

  String? get _timeInputError =>
      timeController.text.trim().isNotEmpty && value == null
      ? '예: 16:30 또는 오후 4시 30분으로 입력해 주세요.'
      : null;

  String get _inputHint => switch (field) {
    'start_time' => '시작 시간을 직접 입력하거나 [시간 선택]을 눌러주세요.',
    'date' => selectedDate == null
        ? '날짜를 선택하면 다음으로 넘어가요.'
        : '추출한 날짜가 맞으면 바로 다음으로 넘어갈 수 있어요.',
    'expires_on' => selectedDate == null
        ? '유효기간을 선택하면 다음으로 넘어가요.'
        : '추출한 유효기간이 맞으면 바로 다음으로 넘어갈 수 있어요.',
    'place' => '약속 또는 방문할 장소를 입력해 주세요.',
    'title' => '일정을 기억하기 쉬운 이름으로 입력해 주세요.',
    'purpose' => '일정의 상세 내용이나 메모를 입력해 주세요.',
    'participants' => '함께하는 사람들의 이름을 쉼표로 구분해 입력해 주세요.',
    _ => '이 정보만 확인하면 일정으로 정리할 수 있어요.',
  };

  Future<void> _pickAmbiguityTime() async {
    final initial = _timeOfDayOrDefault(
      timeController.text,
      const TimeOfDay(hour: 19, minute: 0),
    );
    final selected = await showAdaptiveTimePicker(
      context,
      initialHour: initial.hour,
      initialMinute: initial.minute,
    );
    if (selected != null) {
      setState(() {
        timeController.text =
            '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  Widget _input(BuildContext context) => switch (field) {
    'start_time' => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('ambiguity-time-input'),
          controller: timeController,
          autofocus: true,
          keyboardType: TextInputType.datetime,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: '시작 시간',
            hintText: '예: 16:30 또는 오후 4시 30분',
            errorText: _timeInputError,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('time-picker'),
          onPressed: _pickAmbiguityTime,
          icon: const Icon(Icons.schedule_outlined),
          label: const Text('시간 선택'),
        ),
      ],
    ),
    'date' || 'expires_on' => InkWell(
      key: Key(field == 'expires_on' ? 'expiry-picker' : 'date-picker'),
      onTap: () async {
        final selected = await showAdaptiveDatePicker(
          context,
          initialDate: selectedDate ?? DateTime.now(),
        );
        if (selected != null) setState(() => selectedDate = selected);
      },
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: OLColors.surface,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          selectedDate == null
              ? (field == 'expires_on' ? '유효기간 선택' : '날짜 선택')
              : (field == 'expires_on'
                    ? '유효기간 ${dateText(selectedDate)}'
                    : '일정 날짜 ${dateText(selectedDate)}'),
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ),
    ),
    _ => TextField(
      key: const Key('ambiguity-text-field'),
      controller: textController,
      autofocus: true,
      minLines: field == 'purpose' ? 3 : 1,
      maxLines: field == 'purpose' ? 5 : 2,
      decoration: InputDecoration(
        hintText: field == 'participants' ? '쉼표로 구분해 입력' : '직접 입력',
      ),
      onChanged: (_) => setState(() {}),
    ),
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('추가 정보 확인')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ListView(
                children: [
                  Text(
                    question,
                    style: const TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    widget.loop.title,
                    style: const TextStyle(color: OLColors.muted),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _inputHint,
                    style: const TextStyle(color: OLColors.muted, height: 1.4),
                  ),
                  const SizedBox(height: 26),
                  _input(context),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const Key('ambiguity-continue-button'),
                onPressed: value == null
                    ? null
                    : () async {
                        final resolved = await widget.controller
                            .resolveAmbiguity(
                              widget.loop,
                              field: field,
                              value: value!,
                            );
                        if (!context.mounted) return;
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                (resolved.state == LoopState.needsInput &&
                                        resolved.effectiveMissingFields.isNotEmpty)
                                ? AmbiguityScreen(
                                    controller: widget.controller,
                                    loop: resolved,
                                  )
                                : ReviewScreen(
                                    controller: widget.controller,
                                    loop: resolved,
                                  ),
                          ),
                        );
                      },
                child: const Text('다음'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key, required this.controller, required this.loop});
  final AppController controller;
  final OpenLoop loop;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late OpenLoop draft;
  late final TextEditingController titleController;
  late final TextEditingController placeController;
  late final TextEditingController timeController;
  bool submitting = false;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    draft = widget.loop;
    titleController = TextEditingController(text: draft.title);
    placeController = TextEditingController(text: draft.place ?? '');
    timeController = TextEditingController(text: _editableTime(draft.time));
  }

  @override
  void dispose() {
    titleController.dispose();
    placeController.dispose();
    timeController.dispose();
    super.dispose();
  }

  void _edit(String field, Object value) {
    if (!draft.isDraft) return;
    setState(
      () => draft = controller.editDraft(draft, field: field, value: value),
    );
  }

  Future<void> _pickDate() async {
    if (!draft.isDraft) return;
    final initial = draft.primaryDate ?? DateTime.now();
    final selected = await showAdaptiveDatePicker(context, initialDate: initial);
    if (selected != null) {
      _edit(
        (draft.kind == LoopKind.coupon || draft.kind == LoopKind.purchase)
            ? 'expires_on'
            : 'date',
        '${selected.year.toString().padLeft(4, '0')}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}',
      );
    }
  }

  Future<void> _pickTime() async {
    if (!draft.isDraft) return;
    final parts = draft.time?.split(':');
    final hour = parts == null ? 9 : int.tryParse(parts.first) ?? 9;
    final minute =
        parts == null || parts.length < 2 ? 0 : int.tryParse(parts[1]) ?? 0;
    final selected = await showAdaptiveTimePicker(
      context,
      initialHour: hour,
      initialMinute: minute,
    );
    if (selected != null) {
      timeController.text =
          '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
      _updateTime(timeController.text);
    }
  }

  bool get _hasInvalidTimeInput =>
      timeController.text.trim().isNotEmpty &&
      normalizeTimeInput(timeController.text) == null;

  String? get _timeInputError =>
      _hasInvalidTimeInput ? '예: 16:30 또는 오후 4시 30분으로 입력해 주세요.' : null;

  void _updateTime(String input) {
    final normalized = normalizeTimeInput(input);
    setState(() {
      if (input.trim().isEmpty) {
        draft = controller.editDraft(draft, field: 'start_time', value: '');
      } else if (normalized != null) {
        draft = controller.editDraft(
          draft,
          field: 'start_time',
          value: normalized,
        );
      }
    });
  }

  Future<void> _approve() async {
    if (submitting || draft.missingFields.isNotEmpty) return;
    setState(() => submitting = true);
    try {
      final bool expired = isLoopExpired(draft);
      final loopToSave = expired && draft.state != LoopState.closed
          ? draft.copyWith(state: LoopState.closed)
          : draft;
      final persisted = await controller.approveDraft(loopToSave);
      if (!mounted) return;
      setState(() => draft = persisted);

      final bool isCalendarEvent = !expired &&
          (persisted.kind == LoopKind.appointment ||
              persisted.kind == LoopKind.reservation ||
              (persisted.date != null && persisted.time != null));

      // 약속·예약 등 날짜/시간이 있는 경우 캘린더에 추가 (만료된 일정은 캘린더 연동 제외)
      if (isCalendarEvent) {
        _launchCalendarHandoff(controller, persisted);
      }

      if (mounted) Navigator.popUntil(context, (route) => route.isFirst);

      final String message = expired
          ? '‘${persisted.title}’ 종료된 항목으로 저장되었습니다.'
          : (isCalendarEvent
              ? '‘${persisted.title}’ 일정이 캘린더에 추가되었습니다.'
              : '‘${persisted.title}’ 저장이 완료되었습니다.');

      final messenger =
          scaffoldMessengerKey.currentState ??
          (mounted ? ScaffoldMessenger.maybeOf(context) : null);
      messenger?.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(
                isCalendarEvent
                    ? Icons.event_available_rounded
                    : Icons.check_circle_outline_rounded,
                color: Colors.white,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          backgroundColor: OLColors.navy,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      final messenger =
          scaffoldMessengerKey.currentState ??
          (mounted ? ScaffoldMessenger.maybeOf(context) : null);
      messenger?.showSnackBar(
        SnackBar(
          content: Text('저장 중 문제가 발생했습니다: $e'),
          backgroundColor: OLColors.warning,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('분석 결과')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        if (controller.lastAnalysisWasLocal)
          const _InfoBanner(text: '원격 AI를 설정하지 않아 로컬 규칙 분석을 사용했습니다.'),
        const SizedBox(height: 12),
        Text(
          loopKindLabel(draft.kind),
          style: const TextStyle(
            color: OLColors.cobalt,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        _ReviewFieldCard(
          icon: Icons.title_rounded,
          label: '제목',
          child: draft.isDraft
              ? TextField(
                  key: const Key('review-title-field'),
                  controller: titleController,
                  maxLines: 2,
                  minLines: 1,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                    contentPadding: EdgeInsets.zero,
                    isDense: true,
                  ),
                  onChanged: (value) => _edit('title', value.trim()),
                )
              : Text(
                  draft.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
        ),
        if (draft.summary?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 14),
          _SummaryCard(summary: draft.summary!),
        ],
        if (isLoopExpired(draft)) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFF3B1E1E)
                  : const Color(0xFFFEF2F2),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: const Color(0xFFEF4444).withValues(alpha: 0.35),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFEF4444),
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    draft.kind == LoopKind.coupon
                        ? '유효기간이 이미 지난 쿠폰입니다. [종료] 상태로 등록됩니다.'
                        : '일정 기한이 이미 지난 항목입니다. [종료] 상태로 등록됩니다.',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).brightness == Brightness.dark
                          ? const Color(0xFFFCA5A5)
                          : const Color(0xFFB91C1C),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 4),
        if (draft.kind != LoopKind.place)
          _ReviewFieldCard(
            key: const Key('review-date-field'),
            icon: (draft.kind == LoopKind.coupon ||
                    draft.kind == LoopKind.purchase)
                ? Icons.timer_outlined
                : Icons.calendar_today_outlined,
            label: (draft.kind == LoopKind.coupon ||
                    draft.kind == LoopKind.purchase)
                ? '기한'
                : '날짜',
            trailing: draft.isDraft
                ? const Icon(
                    Icons.chevron_right_rounded,
                    color: OLColors.muted,
                  )
                : null,
            onTap: draft.isDraft ? _pickDate : null,
            child: Text(
              (draft.kind == LoopKind.coupon || draft.kind == LoopKind.purchase)
                  ? dateText(draft.expiresOn ?? draft.date)
                  : dateText(draft.date),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (draft.kind == LoopKind.appointment ||
            draft.kind == LoopKind.reservation ||
            draft.time != null)
          _ReviewFieldCard(
            icon: Icons.schedule_outlined,
            label: draft.kind == LoopKind.deadline
                ? '마감 시간 (선택)'
                : (draft.kind == LoopKind.reservation ? '예약 시간' : '시간'),
            trailing: draft.isDraft
                ? const Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: OLColors.muted,
                  )
                : null,
            onTap: draft.isDraft ? _pickTime : null,
            child: AbsorbPointer(
              absorbing: true,
              child: TextField(
                key: const Key('review-time-field'),
                controller: timeController,
                enabled: draft.isDraft,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                  hintText: draft.kind == LoopKind.deadline
                      ? '시간 없음'
                      : '시간 미정',
                  hintStyle: const TextStyle(
                    color: OLColors.muted,
                    fontWeight: FontWeight.w500,
                  ),
                  errorText: _timeInputError,
                ),
                onChanged: _updateTime,
              ),
            ),
          ),
        if (draft.kind == LoopKind.appointment ||
            draft.kind == LoopKind.reservation ||
            draft.kind == LoopKind.place ||
            draft.kind == LoopKind.purchase ||
            draft.place != null)
          _ReviewFieldCard(
            icon: Icons.place_outlined,
            label: draft.kind == LoopKind.place
                ? '저장할 장소'
                : (draft.kind == LoopKind.purchase
                    ? '구매처/판매처'
                    : (draft.kind == LoopKind.reservation
                        ? '예약 장소'
                        : '장소')),
            child: TextField(
              key: const Key('review-place-field'),
              controller: placeController,
              enabled: draft.isDraft,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.zero,
                isDense: true,
                hintText: draft.kind == LoopKind.place
                    ? '장소명'
                    : (draft.kind == LoopKind.purchase
                        ? '예: 쿠팡, 네이버쇼핑'
                        : '장소 미정'),
                hintStyle: const TextStyle(
                  color: OLColors.muted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              onChanged: (value) => _edit('place', value.trim()),
            ),
          ),
        if (draft.participants.isNotEmpty)
          _Fact(
            icon: Icons.group_outlined,
            label: draft.participants.join(', '),
          ),
        if (draft.resolutionNote != null) ...[
          const SizedBox(height: 18),
          _InfoBanner(text: draft.resolutionNote!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('save-loop-button'),
          onPressed:
              submitting ||
                  draft.missingFields.isNotEmpty ||
                  _hasInvalidTimeInput
              ? null
              : _approve,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 17),
          ),
          child: Text(submitting ? '저장 중…' : reviewPrimaryActionText(draft)),
        ),
      ],
    ),
  );
}

void _launchCalendarHandoff(AppController controller, OpenLoop loop) {
  unawaited(_finishCalendarHandoff(controller, loop));
}

Future<void> _finishCalendarHandoff(
  AppController controller,
  OpenLoop loop,
) async {
  try {
    if (await controller.deviceActions.addToCalendar(loop)) {
      await controller.completeActionByType(loop, 'calendar');
    }
  } catch (_) {
    // Calendar handoff is a convenience action; the saved Loop remains usable.
  }
}

class LoopDetailScreen extends StatefulWidget {
  const LoopDetailScreen({
    super.key,
    required this.controller,
    required this.loopId,
  });
  final AppController controller;
  final String loopId;
  @override
  State<LoopDetailScreen> createState() => _LoopDetailScreenState();
}

class _LoopDetailScreenState extends State<LoopDetailScreen> {
  String? notice;
  WeatherSnapshot? weather;

  Future<void> _openPlaceContext(OpenLoop loop) async {
    final query = loop.place;
    if (query == null || query.isEmpty) return;
    final api = ContextApi(baseUrl: widget.controller.baseUrl);
    final results = await api.searchPlaces(query);
    if (!mounted) return;
    if (results.isEmpty) {
      final encodedName = Uri.encodeComponent(query);
      final fallbackRoute =
          Uri.parse('https://map.kakao.com/link/to/$encodedName');
      await launchUrl(fallbackRoute, mode: LaunchMode.externalApplication);
      await widget.controller.completeActionByType(loop, 'place');
      setState(() => notice = '카카오맵 길찾기를 열었습니다.');
      return;
    }
    final selected = results.length == 1
        ? results.first
        : await showModalBottomSheet<PlaceResult>(
            context: context,
            backgroundColor: Theme.of(context).brightness == Brightness.dark
                ? OLColors.darkSurface
                : Colors.white,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            ),
            builder: (context) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    '길찾기 도착 장소 선택',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  ...results.map(
                    (place) => ListTile(
                      title: Text(
                        place.name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(place.address),
                      trailing: const Icon(
                        Icons.directions_outlined,
                        color: OLColors.cobalt,
                      ),
                      onTap: () => Navigator.pop(context, place),
                    ),
                  ),
                ],
              ),
            ),
          );
    if (selected == null || !mounted) return;
    final currentLocation =
        await widget.controller.deviceActions.getCurrentLocation();
    final snapshot = await api.weather(
      latitude: selected.latitude,
      longitude: selected.longitude,
      at: loop.startsAt,
    );
    if (!mounted) return;
    final mapOpened = await api.openKakaoRoute(
      selected,
      currentLat: currentLocation?.latitude,
      currentLng: currentLocation?.longitude,
    );
    if (mapOpened) {
      await widget.controller.completeActionByType(loop, 'place');
      AppIntegrations.instance.capture('place_opened');
    }
    if (!mounted) return;
    setState(() {
      weather = snapshot;
      notice = mapOpened
          ? (snapshot.available
                ? '기상청 예보를 확인하고 카카오맵 길찾기를 열었습니다.'
                : '카카오맵 길찾기를 열었습니다.')
          : '카카오맵을 열지 못했습니다.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final loop = widget.controller.loops
        .where((item) => item.id == widget.loopId)
        .firstOrNull;
    if (loop == null) {
      return const Scaffold(
        body: Center(child: Text('보관 기간에 따라 삭제된 Loop입니다.')),
      );
    }
    final relatedLoops = widget.controller.loops
        .where(
          (candidate) =>
              candidate.id != loop.id &&
              loop.relatedLoopIds.contains(candidate.id),
        )
        .toList();
    final isExpired = isLoopExpired(loop);
    final isClosed = loop.state == LoopState.closed;

    final isUrgent = !isClosed && !isExpired && isLoopUrgent(loop);

    final (chipBg, chipColor, chipIcon, chipLabel) = () {
      if (isClosed || isExpired) {
        final label = (isExpired && loop.kind == LoopKind.coupon)
            ? '만료된 쿠폰'
            : '종료된 Loop';
        final color =
            isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        final bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
        final icon = isExpired
            ? Icons.alarm_off_rounded
            : Icons.check_circle_outline_rounded;
        return (bg, color, icon, label);
      }
      if (isUrgent) {
        const color = Color(0xFFEA580C);
        final bg = isDark ? const Color(0xFF381F10) : const Color(0xFFFFEDD5);
        return (bg, color, Icons.alarm_rounded, '${loopKindLabel(loop.kind)} · 임박');
      }
      const color = OLColors.cobalt;
      final bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFEEF5FF);
      return (bg, color, loopKindIcon(loop.kind), loopKindLabel(loop.kind));
    }();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          (isClosed || isExpired)
              ? (loop.kind == LoopKind.coupon ? '만료된 쿠폰' : '종료된 Loop')
              : 'Open Loop',
        ),
        actions: [
          IconButton(
            tooltip: '삭제',
            onPressed: () async {
              final confirm = await showAdaptiveDeleteConfirmation(
                context,
              );
              if (confirm != true) return;
              await widget.controller.deleteLoop(loop);
              if (!context.mounted) return;
              Navigator.pop(context);
            },
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 40),
        children: [
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
              decoration: BoxDecoration(
                color: chipBg,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    chipIcon,
                    size: 14,
                    color: chipColor,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    chipLabel,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: chipColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              loop.title,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
                height: 1.3,
                letterSpacing: -0.4,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 20),
          if (loop.summary?.trim().isNotEmpty == true) ...[
            _SummaryCard(summary: loop.summary!),
            const SizedBox(height: 16),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF161E2E) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? const Color(0xFF26334D)
                    : const Color(0xFFEDF2F7),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              children: [
                if (loop.kind == LoopKind.appointment ||
                    loop.kind == LoopKind.deadline ||
                    loop.kind == LoopKind.reservation)
                  _FactItem(
                    icon: Icons.calendar_today_rounded,
                    label: '날짜',
                    value: dateText(loop.date),
                  ),
                if (loop.kind == LoopKind.appointment ||
                    loop.kind == LoopKind.reservation ||
                    (loop.time != null &&
                        loop.kind != LoopKind.coupon &&
                        loop.kind != LoopKind.place))
                  _FactItem(
                    icon: Icons.schedule_rounded,
                    label: '시간',
                    value: loop.time?.substring(0, 5) ?? '시간 미정',
                  ),
                if (loop.kind == LoopKind.coupon ||
                    loop.kind == LoopKind.purchase)
                  _FactItem(
                    icon: Icons.timer_outlined,
                    label: '유효기간',
                    value: (loop.expiresOn ?? loop.date) == null
                        ? '기한 정보 없음'
                        : '${dateText(loop.expiresOn ?? loop.date)}${isExpired ? ' (만료됨)' : ''}',
                  ),
                if (loop.place != null)
                  _FactItem(
                    icon: loop.kind == LoopKind.coupon
                        ? Icons.storefront_outlined
                        : Icons.place_outlined,
                    label: loop.kind == LoopKind.coupon ? '사용/교환처' : '장소',
                    value: loop.place!,
                  ),
                if (loop.participants.isNotEmpty)
                  _FactItem(
                    icon: Icons.people_outline_rounded,
                    label: '함께하는 사람',
                    value: loop.participants.join(', '),
                  ),
                if (loop.purpose != null && loop.kind != LoopKind.coupon)
                  _FactItem(
                    icon: Icons.notes_rounded,
                    label: '목적 및 메모',
                    value: loop.purpose!,
                  ),
              ],
            ),
          ),
          if (weather?.available == true) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF161E2E) : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF26334D)
                      : const Color(0xFFEDF2F7),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF1E293B)
                          : const Color(0xFFEEF5FF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.cloud_outlined,
                      color: OLColors.cobalt,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '일정 당일 날씨 예보',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${weather!.summary ?? '날씨'} · ${weather!.temperatureC?.toStringAsFixed(1) ?? '-'}°C · 강수 확률 ${weather!.precipitationProbability ?? '-'}%',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (relatedLoops.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              '연결된 Loop',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 10),
            ...relatedLoops.map(
              (related) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: LoopCard(
                  loop: related,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => LoopDetailScreen(
                        controller: widget.controller,
                        loopId: related.id,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (loop.kind == LoopKind.coupon) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: (isExpired || isClosed)
                    ? (isDark
                          ? const Color(0xFF2D1818)
                          : const Color(0xFFFEF2F2))
                    : (isDark
                          ? const Color(0xFF1E293B)
                          : const Color(0xFFEEF5FF)),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: (isExpired || isClosed)
                      ? const Color(0xFFEF4444).withValues(alpha: isDark ? .4 : .25)
                      : OLColors.cobalt.withValues(alpha: isDark ? .4 : .2),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    (isExpired || isClosed)
                        ? Icons.alarm_off_outlined
                        : Icons.notifications_active_outlined,
                    color: (isExpired || isClosed)
                        ? const Color(0xFFEF4444)
                        : OLColors.cobalt,
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          (isExpired || isClosed)
                              ? '유효기간이 만료되었습니다'
                              : '유효기간 알림 자동 예약됨',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: (isExpired || isClosed)
                                ? (isDark
                                      ? const Color(0xFFFCA5A5)
                                      : const Color(0xFF991B1B))
                                : (isDark ? Colors.white : OLColors.navy),
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          (isExpired || isClosed)
                              ? '기한이 지나 알림이 발송되지 않습니다.'
                              : '기한을 놓치지 않도록 만료 전에 푸시 알림으로 알려드립니다.',
                          style: TextStyle(
                            color: (isExpired || isClosed)
                                ? (isDark
                                      ? const Color(0xFFF87171)
                                      : const Color(0xFFB91C1C))
                                : (isDark
                                      ? const Color(0xFF94A3B8)
                                      : const Color(0xFF64748B)),
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else if (loop.checklist.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              '체크리스트',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF161E2E) : Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isDark
                      ? const Color(0xFF26334D)
                      : const Color(0xFFEDF2F7),
                  width: 1.2,
                ),
              ),
              child: Column(
                children: [
                  for (int i = 0; i < loop.checklist.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        color: isDark
                            ? const Color(0xFF26334D)
                            : const Color(0xFFEDF2F7),
                      ),
                    CheckboxListTile(
                      value: loop.checklist[i].completed,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 2,
                      ),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              loop.checklist[i].title,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14.5,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: loop.checklist[i].isRequired
                                  ? (isDark
                                        ? const Color(0xFF381F10)
                                        : const Color(0xFFFFEDD5))
                                  : (isDark
                                        ? const Color(0xFF1E293B)
                                        : const Color(0xFFF1F5F9)),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              loop.checklist[i].isRequired ? '필수' : '선택',
                              style: TextStyle(
                                color: loop.checklist[i].isRequired
                                    ? const Color(0xFFEA580C)
                                    : const Color(0xFF64748B),
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      onChanged: loop.state == LoopState.closed
                          ? null
                          : (value) async {
                              await widget.controller.updateChecklist(
                                loop,
                                loop.checklist[i],
                                value ?? false,
                              );
                              if (mounted) setState(() {});
                            },
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (notice != null) ...[
            const SizedBox(height: 14),
            _InfoBanner(text: notice!),
          ],
          const SizedBox(height: 24),
          if (loop.state == LoopState.closed) ...[
            OutlinedButton.icon(
              key: const Key('reopen-loop-button'),
              onPressed: () async {
                await widget.controller.saveLoop(
                  loop.copyWith(state: LoopState.open),
                );
                if (mounted) {
                  setState(() => notice = 'Loop를 다시 진행 중 상태로 열었습니다.');
                }
              },
              icon: const Icon(Icons.replay_rounded),
              label: const Text('Loop 다시 열기'),
            ),
          ] else ...[
            if (loop.place != null)
              OutlinedButton.icon(
                key: const Key('directions-button'),
                onPressed: () => _openPlaceContext(loop),
                icon: const Icon(Icons.directions_rounded),
                label: const Text('장소 길찾기'),
              ),
            const SizedBox(height: 10),
            FilledButton.icon(
              key: const Key('close-loop-button'),
              onPressed: () async {
                await widget.controller.closeLoop(loop);
                AppIntegrations.instance.capture('loop_closed');
                if (!context.mounted) return;
                if (widget.controller.retention ==
                    RetentionPolicy.immediately) {
                  Navigator.pop(context);
                } else {
                  setState(() => notice = '필요한 행동이 끝나 Loop를 닫았습니다.');
                }
              },
              icon: const Icon(Icons.check_rounded),
              label: const Text('Loop 닫기'),
            ),
          ],
        ],
      ),
    );
  }
}

@visibleForTesting
Future<bool> showAdaptiveDeleteConfirmation(BuildContext context) async {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return await showCupertinoDialog<bool>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Loop 삭제'),
            content: const Text('이 Loop를 목록에서 삭제할까요?'),
            actions: [
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              CupertinoDialogAction(
                isDestructiveAction: true,
                onPressed: () => Navigator.pop(context, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        ) ??
        false;
  }
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Loop 삭제'),
          content: const Text('이 Loop를 목록에서 삭제할까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제'),
            ),
          ],
        ),
      ) ??
      false;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController urlController;
  late RetentionPolicy retention;
  late ThemeMode themeMode;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.controller.baseUrl);
    retention = widget.controller.retention;
    themeMode = widget.controller.themeMode;
    if (kDebugMode) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _refreshCapabilities(),
      );
    }
  }

  Future<void> _refreshCapabilities() async {
    await widget.controller.refreshCapabilities();
    if (mounted) setState(() {});
  }

  String get _connectionStatus {
    if (widget.controller.baseUrl.trim().isEmpty) {
      return '상태: 로컬 규칙 분석 · 원격 AI 비활성';
    }
    if (widget.controller.capabilitiesLoading) return '상태: AWS 원격 API 상태 확인 중…';
    final capabilities = widget.controller.capabilities;
    if (capabilities == null) return '상태: AWS 원격 API 상태를 확인하지 못했습니다.';
    if (!capabilities.analysisEnabled) {
      return '상태: AWS 원격 API 연결됨 · Gemini 키를 추가하면 AI 분석이 활성화됩니다.';
    }
    return '상태: AWS 원격 AI 분석 사용 중 · ${capabilities.analysisModel ?? 'Gemini'}';
  }

  String get _integrationStatus {
    final capabilities = widget.controller.capabilities;
    if (capabilities == null) return '';
    // A configured provider can still be awaiting a provider-side approval
    // (for example, KMA API utilization). Avoid claiming that it is live.
    String state(bool enabled) => enabled ? '설정됨' : '준비됨';
    return '장소 ${state(capabilities.placesEnabled)} · 날씨 ${state(capabilities.weatherEnabled)} · '
        '푸시 ${state(capabilities.pushEnabled)}';
  }

  @override
  void dispose() {
    urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('설정')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          '화면 테마',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          '앱의 테마를 선택할 수 있습니다.',
          style: TextStyle(color: OLColors.muted, height: 1.45),
        ),
        const SizedBox(height: 12),
        _NativeThemeSlider(
          selectedMode: widget.controller.themeMode,
          onChanged: (mode) => widget.controller.updateThemeMode(mode),
        ),
        const SizedBox(height: 28),
        if (kDebugMode) ...[
          const Text(
            '개발자 연결 설정',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            _connectionStatus,
            style: const TextStyle(color: OLColors.muted, height: 1.45),
          ),
          if (_integrationStatus.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _integrationStatus,
              style: const TextStyle(color: OLColors.muted, height: 1.45),
            ),
          ],
          const SizedBox(height: 6),
          const Text(
            '텍스트는 오프라인 규칙 분석을 지원합니다. 이미지 분석 실패는 결과로 대체하지 않고 다시 시도할 수 있게 표시합니다.',
            style: TextStyle(color: OLColors.muted, height: 1.45),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('base-url-field'),
            controller: urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              hintText: 'https://api.example.com',
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _refreshCapabilities,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('연결 상태 새로고침'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              await widget.controller.triggerTestNotification(
                title: 'BHC 뿌링클+콜라1.25L',
                body: '오늘 마감되는 교환권입니다. 잊지 말고 지금 사용하세요!',
                subtitle: '쿠폰 유효기간 알림',
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(
                    content: Text('🔔 쿠폰 유효기간 테스트 알림을 발송했습니다.'),
                  ),
                );
            },
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('쿠폰 유효기간 알림 즉시 테스트'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              await widget.controller.triggerTestNotification(
                title: '김성훈과 만남 (종로5가역)',
                body: '1시간 후 약속이 시작됩니다. 맑음 · 24°C (강수 0%) 이동 준비를 시작하세요!',
                subtitle: '약속 시작 전 알림',
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  const SnackBar(
                    content: Text('🔔 날씨 정보가 포함된 약속 테스트 푸시 알림을 발송했습니다.'),
                  ),
                );
            },
            icon: const Icon(Icons.alarm_on_rounded),
            label: const Text('약속 시작 전 알림 즉시 테스트 (날씨 포함)'),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () async {
              final enabled = await AppIntegrations.instance
                  .enablePushNotifications(apiBaseUrl: urlController.text);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    enabled
                        ? '서버 체크포인트 알림을 켰습니다.'
                        : '알림을 켜지 못했습니다. Firebase 설정과 기기 권한을 확인해 주세요.',
                  ),
                ),
              );
            },
            icon: const Icon(Icons.notifications_outlined),
            label: const Text('서버 체크포인트 알림 켜기'),
          ),
          const SizedBox(height: 28),
        ],
        const Text(
          'Close & Forget',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        const Text(
          '닫힌 Loop의 구조화 데이터 보관 기간입니다. 원본 이미지는 앱에서 별도로 보관하지 않습니다.',
          style: TextStyle(color: OLColors.muted, height: 1.45),
        ),
        const SizedBox(height: 12),
        RadioGroup<RetentionPolicy>(
          groupValue: retention,
          onChanged: (value) => setState(() => retention = value!),
          child: Column(
            children: RetentionPolicy.values
                .map(
                  (policy) => RadioListTile<RetentionPolicy>(
                    value: policy,
                    title: Text(retentionText(policy)),
                    contentPadding: EdgeInsets.zero,
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () async {
            await widget.controller.updateSettings(
              url: urlController.text,
              policy: retention,
            );
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('저장'),
        ),
      ],
    ),
  );
}

@visibleForTesting
bool shouldShowConfidence(
  Map<String, double> confidence, {
  bool debug = kDebugMode,
}) =>
    confidence.isNotEmpty &&
    (debug || confidence.values.any((value) => value < 0.8));

class LoopCard extends StatelessWidget {
  const LoopCard({super.key, required this.loop, required this.onTap});
  final OpenLoop loop;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final expired = isLoopExpired(loop);
    final closed = loop.state == LoopState.closed;
    final urgent = isLoopUrgent(loop);
    final needsInput = loop.state == LoopState.needsInput;

    final IconData iconData = switch (loop.kind) {
      LoopKind.appointment => Icons.calendar_today_rounded,
      LoopKind.deadline => Icons.alarm_rounded,
      LoopKind.coupon => Icons.confirmation_number_outlined,
      LoopKind.place => Icons.place_outlined,
      LoopKind.reservation => Icons.event_available_rounded,
      _ => Icons.task_alt_rounded,
    };

    // 상태/긴급도 기반 통일된 컬러 시스템 (임박: 주황, 진행 중: 블루, 종료: 회색, 확인 필요: 앰버)
    final (badgeText, badgeColor, badgeBg, iconColor, iconBg) = () {
      if (closed || expired) {
        final text = (expired && loop.kind == LoopKind.coupon) ? '만료됨' : '종료';
        final color =
            isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
        final bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9);
        return (text, color, bg, color, bg);
      }
      if (needsInput) {
        const color = Color(0xFFD97706);
        final bg = isDark ? const Color(0xFF3B2510) : const Color(0xFFFEF3C7);
        return ('확인 필요', color, bg, color, bg);
      }
      if (urgent) {
        const color = Color(0xFFEA580C);
        final bg = isDark ? const Color(0xFF381F10) : const Color(0xFFFFEDD5);
        return ('임박', color, bg, color, bg);
      }
      // 일반 진행 중 (블루)
      const color = Color(0xFF2563EB);
      final bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFEEF5FF);
      return ('진행 중', color, bg, color, bg);
    }();

    final meta = loopCardMeta(loop);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161E2E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF26334D) : const Color(0xFFEDF2F7),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(iconData, color: iconColor, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              loop.title,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF0F172A),
                                height: 1.3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3.5,
                            ),
                            decoration: BoxDecoration(
                              color: badgeBg,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              badgeText,
                              style: TextStyle(
                                color: badgeColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          meta,
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFF94A3B8)
                                : const Color(0xFF64748B),
                            fontSize: 13,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: selected
                ? OLColors.cobalt
                : (isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9)),
            borderRadius: BorderRadius.circular(20),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: OLColors.cobalt.withValues(alpha: 0.28),
                      blurRadius: 8,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected
                      ? Colors.white
                      : (isDark
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF475569)),
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  fontSize: 13.5,
                ),
              ),
              if (count != null && count! > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? Colors.white.withValues(alpha: 0.22)
                        : (isDark
                              ? const Color(0xFF334155)
                              : const Color(0xFFE2E8F0)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    count.toString(),
                    style: TextStyle(
                      color: selected
                          ? Colors.white
                          : (isDark
                                ? const Color(0xFFCBD5E1)
                                : const Color(0xFF64748B)),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyLoops extends StatelessWidget {
  const _EmptyLoops();
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return OLCard(
      padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 22),
      child: Column(
        children: [
          const Icon(Icons.inbox_outlined, size: 40, color: OLColors.iconMuted),
          const SizedBox(height: 14),
          const Text(
            '아직 Open Loop가 없습니다.',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            '텍스트나 이미지를 공유해 일정, 장소, 쿠폰을 저장해 보세요.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark ? OLColors.darkMuted : OLColors.muted,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyFilterLoops extends StatelessWidget {
  const _EmptyFilterLoops({required this.filter});
  final HomeFilter filter;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (icon, message) = switch (filter) {
      HomeFilter.urgent => (
        Icons.alarm_off_rounded,
        '임박한 일정이 없습니다.\n여유롭게 하루를 보내세요!',
      ),
      HomeFilter.coupon => (
        Icons.confirmation_number_outlined,
        '저장된 쿠폰이 없습니다.\n기프티콘 이미지를 공유해 보세요.',
      ),
      HomeFilter.schedule => (
        Icons.calendar_month_outlined,
        '등록된 일정이 없습니다.',
      ),
      HomeFilter.place => (
        Icons.place_outlined,
        '저장된 장소가 없습니다.',
      ),
      HomeFilter.closed => (
        Icons.check_circle_outline_rounded,
        '종료되거나 만료된 Loop가 없습니다.',
      ),
      HomeFilter.all => (
        Icons.inbox_outlined,
        '아직 Open Loop가 없습니다.',
      ),
    };

    return OLCard(
      padding: const EdgeInsets.symmetric(vertical: 42, horizontal: 22),
      child: Column(
        children: [
          Icon(
            icon,
            size: 40,
            color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
          ),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              height: 1.45,
              fontWeight: FontWeight.w700,
              color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReviewFieldCard extends StatelessWidget {
  const _ReviewFieldCard({
    super.key,
    required this.icon,
    required this.label,
    required this.child,
    this.trailing,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final Widget child;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: isDark ? OLColors.darkSurface : OLColors.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? OLColors.darkBorder : OLColors.border,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, color: OLColors.cobalt, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: isDark ? OLColors.darkMuted : OLColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    child,
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}

class _FactItem extends StatelessWidget {
  const _FactItem({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E293B)
                  : const Color(0xFFEEF5FF),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              icon,
              color: OLColors.cobalt,
              size: 19,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1.5),
                Text(
                  value,
                  style: TextStyle(
                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: OLColors.cobalt, size: 21),
          const SizedBox(width: 13),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : const Color(0xFF0F172A),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? OLColors.cobaltDarkSoft : OLColors.cobaltSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: OLColors.cobalt.withValues(alpha: isDark ? .4 : .22),
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: isDark ? const Color(0xFFE2E8F0) : OLColors.navy,
          height: 1.45,
        ),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final String summary;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF161E2E) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark ? const Color(0xFF26334D) : const Color(0xFFEDF2F7),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: isDark
                  ? const Color(0xFF1E293B)
                  : const Color(0xFFEEF5FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.auto_awesome_rounded,
              color: OLColors.cobalt,
              size: 18,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AI 요약',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: isDark
                        ? const Color(0xFF94A3B8)
                        : const Color(0xFF64748B),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  summary,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.45,
                    fontWeight: FontWeight.w600,
                    color: isDark
                        ? const Color(0xFFE2E8F0)
                        : const Color(0xFF1E293B),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String dateText(DateTime? date) =>
    date == null ? '날짜 미정' : '${date.month}월 ${date.day}일';

String loopKindLabel(LoopKind kind) => switch (kind) {
  LoopKind.appointment => '일정',
  LoopKind.deadline => '마감',
  LoopKind.place => '장소',
  LoopKind.coupon => '쿠폰',
  LoopKind.purchase => '구매',
  LoopKind.reservation => '예약',
};

IconData loopKindIcon(LoopKind kind) => switch (kind) {
  LoopKind.appointment => Icons.event_outlined,
  LoopKind.deadline => Icons.flag_outlined,
  LoopKind.place => Icons.bookmark_border_rounded,
  LoopKind.coupon => Icons.local_activity_outlined,
  LoopKind.purchase => Icons.shopping_bag_outlined,
  LoopKind.reservation => Icons.confirmation_number_outlined,
};

String reviewPrimaryActionText(OpenLoop loop) => switch (loop.kind) {
  LoopKind.appointment => '저장하기',
  LoopKind.deadline => '저장하기',
  LoopKind.place => '저장하기',
  LoopKind.coupon => '저장하기',
  LoopKind.purchase => '저장하기',
  LoopKind.reservation => '저장하기',
};

String loopCardMeta(OpenLoop loop) => switch (loop.kind) {
  LoopKind.appointment => [
    dateText(loop.date),
    loop.time?.substring(0, 5) ?? '시간 미정',
    if (loop.place != null) loop.place!,
  ].join(' · '),
  LoopKind.deadline => [
    '마감 ${dateText(loop.date)}',
    if (loop.time != null) loop.time!.substring(0, 5),
  ].join(' · '),
  LoopKind.place => loop.place ?? '장소 정보',
  LoopKind.coupon => [
    loop.expiresOn == null ? '기한 정보 없음' : '기한 ${dateText(loop.expiresOn)}',
    if (loop.place != null) loop.place!,
  ].join(' · '),
  LoopKind.purchase => [
    (loop.expiresOn ?? loop.date) == null
        ? '기한 없음'
        : '기한 ${dateText(loop.expiresOn ?? loop.date)}',
    if (loop.place != null) loop.place!,
  ].join(' · '),
  LoopKind.reservation => [
    dateText(loop.date),
    loop.time?.substring(0, 5) ?? '시간 미정',
    if (loop.place != null) loop.place!,
  ].join(' · '),
};

String checkpointTimeText(DateTime dateTime, {DateTime? now}) {
  final local = dateTime.toLocal();
  final reference = (now ?? DateTime.now()).toLocal();
  final date = DateTime(local.year, local.month, local.day);
  final today = DateTime(reference.year, reference.month, reference.day);
  final dayDifference = date.difference(today).inDays;
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (dayDifference == 0) return '오늘 $time';
  if (dayDifference == 1) return '내일 $time';
  if (dayDifference == 2) return '모레 $time';
  const weekdays = ['월', '화', '수', '목', '금', '토', '일'];
  return '${local.month}월 ${local.day}일 (${weekdays[local.weekday - 1]}) $time';
}

String actionDescription(LoopAction action) => switch (action.type) {
  'calendar' => '기기 캘린더에 이 일정을 남깁니다.',
  'reminder' => '필요한 시점에 앱 알림을 자동 예약합니다.',
  'place' => '장소와 날씨 정보를 확인합니다.',
  'checklist' => '마감 전에 빠뜨릴 제출 항목을 확인합니다.',
  'coupon' => '쿠폰을 사용한 뒤 완료로 표시합니다.',
  _ => '이 일정을 실제로 마무리하기 위한 항목입니다.',
};

String stateText(LoopState state) => switch (state) {
  LoopState.open => '진행 중',
  LoopState.needsInput => '확인 필요',
  LoopState.closed => '닫힘',
};
String retentionText(RetentionPolicy policy) => switch (policy) {
  RetentionPolicy.immediately => '닫는 즉시 삭제',
  RetentionPolicy.sevenDays => '7일 후 삭제',
  RetentionPolicy.thirtyDays => '30일 후 삭제',
  RetentionPolicy.keep => '계속 보관',
};

class _NativeThemeSlider extends StatefulWidget {
  const _NativeThemeSlider({
    required this.selectedMode,
    required this.onChanged,
  });

  final ThemeMode selectedMode;
  final ValueChanged<ThemeMode> onChanged;

  @override
  State<_NativeThemeSlider> createState() => _NativeThemeSliderState();
}

class _NativeThemeSliderState extends State<_NativeThemeSlider> {
  late ThemeMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.selectedMode;
  }

  @override
  void didUpdateWidget(covariant _NativeThemeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedMode != widget.selectedMode) {
      _mode = widget.selectedMode;
    }
  }

  void _handleSelect(ThemeMode newMode) {
    if (_mode == newMode) return;
    setState(() => _mode = newMode);
    scheduleMicrotask(() => widget.onChanged(newMode));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDarkModeSelected = _mode == ThemeMode.dark;

    return RepaintBoundary(
      child: Container(
        height: 48,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0),
          borderRadius: BorderRadius.circular(14),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final itemWidth = (constraints.maxWidth - 8) / 2;
            return Stack(
              children: [
                AnimatedAlign(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  alignment: isDarkModeSelected
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: itemWidth,
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: isDark ? const Color(0xFF334155) : Colors.white,
                      borderRadius: BorderRadius.circular(11),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: isDark ? 0.3 : 0.08,
                          ),
                          blurRadius: 4,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _handleSelect(ThemeMode.light),
                        child: Center(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.light_mode_rounded,
                                size: 18,
                                color: !isDarkModeSelected
                                    ? (isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A))
                                    : (isDark
                                        ? const Color(0xFF64748B)
                                        : const Color(0xFF94A3B8)),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '라이트',
                                style: TextStyle(
                                  fontWeight: !isDarkModeSelected
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  fontSize: 14,
                                  color: !isDarkModeSelected
                                      ? (isDark
                                          ? Colors.white
                                          : const Color(0xFF0F172A))
                                      : (isDark
                                          ? const Color(0xFF64748B)
                                          : const Color(0xFF94A3B8)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _handleSelect(ThemeMode.dark),
                        child: Center(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.dark_mode_rounded,
                                size: 18,
                                color: isDarkModeSelected
                                    ? (isDark
                                        ? Colors.white
                                        : const Color(0xFF0F172A))
                                    : (isDark
                                        ? const Color(0xFF64748B)
                                        : const Color(0xFF94A3B8)),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '다크',
                                style: TextStyle(
                                  fontWeight: isDarkModeSelected
                                      ? FontWeight.w800
                                      : FontWeight.w600,
                                  fontSize: 14,
                                  color: isDarkModeSelected
                                      ? (isDark
                                          ? Colors.white
                                          : const Color(0xFF0F172A))
                                      : (isDark
                                          ? const Color(0xFF64748B)
                                          : const Color(0xFF94A3B8)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
