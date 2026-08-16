import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'app_controller.dart';
import 'design_system.dart';
import 'models/open_loop.dart';
import 'services/external_integrations.dart';

class OpenLoopApp extends StatefulWidget {
  const OpenLoopApp({super.key, required this.controller});
  final AppController controller;
  @override
  State<OpenLoopApp> createState() => _OpenLoopAppState();
}

class _OpenLoopAppState extends State<OpenLoopApp> {
  final navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<List<SharedMediaFile>>? shareSubscription;

  @override
  void initState() {
    super.initState();
    widget.controller.initialize();
    _listenForShares();
    AppIntegrations.instance.pendingLoopId.addListener(_openPushLoop);
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
    if (items.isEmpty) return;
    final firstImage = items
        .where((item) => item.type == SharedMediaType.image)
        .firstOrNull;
    final text = items
        .where(
          (item) =>
              item.type == SharedMediaType.text ||
              item.type == SharedMediaType.url,
        )
        .map((item) => item.path)
        .join('\n');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final navigator = navigatorKey.currentState;
      if (navigator == null) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => CaptureScreen(
            controller: widget.controller,
            initialText: text,
            initialImagePath: firstImage?.path,
          ),
        ),
      );
      ReceiveSharingIntent.instance.reset();
    });
  }

  @override
  void dispose() {
    shareSubscription?.cancel();
    AppIntegrations.instance.pendingLoopId.removeListener(_openPushLoop);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'OpenLoop',
    debugShowCheckedModeBanner: false,
    theme: openLoopTheme(),
    home: AnimatedBuilder(
      animation: widget.controller,
      builder: (_, __) => widget.controller.ready
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

class _HomeScreenState extends State<HomeScreen> {
  LoopState? filter;
  @override
  Widget build(BuildContext context) {
    final loops = filter == null
        ? widget.controller.loops
        : widget.controller.loops
              .where((loop) => loop.state == filter)
              .toList();
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 28, 22, 110),
          children: [
            Row(
              children: [
                const CircleAvatar(
                  radius: 22,
                  backgroundColor: OLColors.cobalt,
                  foregroundColor: Colors.white,
                  child: Text(
                    'O',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'OpenLoop',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                  ),
                ),
                IconButton(
                  key: const Key('settings-button'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          SettingsScreen(controller: widget.controller),
                    ),
                  ),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
            const SizedBox(height: 44),
            const Text(
              '캡처만 하세요.\n일정은 OpenLoop가 만듭니다.',
              style: TextStyle(
                color: OLColors.navy,
                fontSize: 34,
                height: 1.24,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.5,
              ),
            ),
            const SizedBox(height: 11),
            const Text(
              '애매한 정보는 추측하지 않고 한 번만 물어봅니다.',
              style: TextStyle(color: OLColors.muted, height: 1.5),
            ),
            const SizedBox(height: 26),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterChip(
                    label: '전체',
                    selected: filter == null,
                    onTap: () => setState(() => filter = null),
                  ),
                  _FilterChip(
                    label: '진행 중',
                    selected: filter == LoopState.open,
                    onTap: () => setState(() => filter = LoopState.open),
                  ),
                  _FilterChip(
                    label: '확인 필요',
                    selected: filter == LoopState.needsInput,
                    onTap: () => setState(() => filter = LoopState.needsInput),
                  ),
                  _FilterChip(
                    label: '닫힘',
                    selected: filter == LoopState.closed,
                    onTap: () => setState(() => filter = LoopState.closed),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            if (loops.isEmpty)
              const _EmptyLoops()
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
            const SizedBox(height: 20),
            const _PrivacyNote(),
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
          '캡처 추가',
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
  });
  final AppController controller;
  final String initialText;
  final String? initialImagePath;
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late final TextEditingController textController;
  String source = 'text';
  XFile? image;
  String? error;

  @override
  void initState() {
    super.initState();
    textController = TextEditingController(text: widget.initialText);
    if (widget.initialImagePath != null) {
      image = XFile(widget.initialImagePath!);
      source = 'image';
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
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = '사진 권한이 없거나 이미지를 열 수 없습니다. 텍스트로 계속할 수 있어요.');
      }
    }
  }

  Future<void> _analyze() async {
    final text = textController.text.trim();
    if (text.isEmpty && image == null) {
      setState(() => error = '분석할 텍스트나 이미지를 추가해 주세요.');
      return;
    }
    final result = image == null
        ? widget.controller.analyze(text: text, source: source)
        : widget.controller.analyzeImage(
            imagePath: image!.path,
            companionText: text,
          );
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            ProcessingScreen(result: result, controller: widget.controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('OpenLoop에 공유')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        const Text(
          '이미 이해한 정보를 다시 입력하지 마세요.',
          style: TextStyle(color: OLColors.muted),
        ),
        const SizedBox(height: 22),
        TextField(
          key: const Key('capture-text'),
          controller: textController,
          minLines: 5,
          maxLines: 10,
          decoration: const InputDecoration(hintText: '대화, 공지, 예약 내용을 붙여 넣으세요'),
          onChanged: (_) => setState(() => source = 'text'),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('스크린샷'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickImage(ImageSource.gallery),
                icon: const Icon(Icons.photo_outlined),
                label: const Text('이미지'),
              ),
            ),
          ],
        ),
        if (image != null) ...[
          const SizedBox(height: 12),
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
              onPressed: () => setState(() => image = null),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: const TextStyle(color: OLColors.warning)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('analyze-button'),
          onPressed: _analyze,
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 17),
          ),
          child: const Text(
            '일정 분석',
            style: TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 18),
        const _PrivacyNote(),
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
      await Navigator.pushReplacement(
        context,
        MaterialPageRoute<void>(
          builder: (_) => loop.state == LoopState.needsInput
              ? AmbiguityScreen(controller: widget.controller, loop: loop)
              : ReviewScreen(controller: widget.controller, loop: loop),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('분석하지 못했습니다: $error')));
      Navigator.pop(context);
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

class _AmbiguityScreenState extends State<AmbiguityScreen> {
  TimeOfDay? selectedTime;
  DateTime? selectedDate;
  late final TextEditingController textController;

  String get field => widget.loop.missingFields.firstOrNull ?? 'start_time';

  List<String> get _participants => textController.text
      .split(RegExp(r'[,\n]'))
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();

  @override
  void initState() {
    super.initState();
    textController = TextEditingController(
      text: switch (field) {
        'place' => widget.loop.place ?? '',
        'title' => widget.loop.title == '새 Open Loop' ? '' : widget.loop.title,
        'purpose' => widget.loop.purpose ?? '',
        'participants' => widget.loop.participants.join(', '),
        _ => '',
      },
    );
  }

  @override
  void dispose() {
    textController.dispose();
    super.dispose();
  }

  String get question => switch (field) {
    'start_time' => '몇 시로 등록할까요?',
    'date' => '언제인지 알려줄래요?',
    'place' => '어디에서 만날까요?',
    'title' => '이 일정의 이름은 무엇인가요?',
    'purpose' => '무엇을 위한 일정인가요?',
    'participants' => '누구와 함께하나요?',
    _ => '한 가지만 확인할게요',
  };

  Object? get value => switch (field) {
    'start_time' =>
      selectedTime == null
          ? null
          : '${selectedTime!.hour.toString().padLeft(2, '0')}:${selectedTime!.minute.toString().padLeft(2, '0')}:00',
    'date' =>
      selectedDate == null
          ? null
          : '${selectedDate!.year.toString().padLeft(4, '0')}-${selectedDate!.month.toString().padLeft(2, '0')}-${selectedDate!.day.toString().padLeft(2, '0')}',
    'participants' => _participants.isEmpty ? null : _participants,
    _ => textController.text.trim().isEmpty ? null : textController.text.trim(),
  };

  Widget _input(BuildContext context) => switch (field) {
    'start_time' => InkWell(
      key: const Key('time-picker'),
      onTap: () async {
        final selected = await showTimePicker(
          context: context,
          initialTime: const TimeOfDay(hour: 19, minute: 0),
        );
        if (selected != null) setState(() => selectedTime = selected);
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
          selectedTime == null ? '시간 선택' : selectedTime!.format(context),
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
        ),
      ),
    ),
    'date' => InkWell(
      key: const Key('date-picker'),
      onTap: () async {
        final selected = await showDatePicker(
          context: context,
          initialDate: widget.loop.date ?? DateTime.now(),
          firstDate: DateTime.now().subtract(const Duration(days: 365)),
          lastDate: DateTime.now().add(const Duration(days: 3650)),
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
          selectedDate == null ? '날짜 선택' : dateText(selectedDate),
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
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
    appBar: AppBar(title: const Text('한 가지만 확인할게요')),
    body: Padding(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            question,
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            widget.loop.title,
            style: const TextStyle(color: OLColors.muted),
          ),
          const SizedBox(height: 26),
          _input(context),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: value == null
                  ? null
                  : () async {
                      final resolved = await widget.controller.resolveAmbiguity(
                        widget.loop,
                        field: field,
                        value: value!,
                      );
                      if (!context.mounted) return;
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => resolved.state == LoopState.needsInput
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
              child: const Text('확인'),
            ),
          ),
        ],
      ),
    ),
  );
}

class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.controller, required this.loop});
  final AppController controller;
  final OpenLoop loop;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('분석 결과')),
    body: ListView(
      padding: const EdgeInsets.all(22),
      children: [
        if (controller.lastAnalysisWasLocal)
          const _InfoBanner(text: 'API가 연결되지 않아 로컬 데모 분석을 사용했습니다.'),
        const SizedBox(height: 12),
        Text(
          loop.kind == LoopKind.deadline ? 'DEADLINE' : 'APPOINTMENT',
          style: const TextStyle(
            color: OLColors.cobalt,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          loop.title,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 22),
        _Fact(icon: Icons.calendar_today_outlined, label: dateText(loop.date)),
        _Fact(
          icon: Icons.schedule_outlined,
          label: loop.time?.substring(0, 5) ?? '시간 미정',
        ),
        if (loop.place != null)
          _Fact(icon: Icons.place_outlined, label: loop.place!),
        if (loop.participants.isNotEmpty)
          _Fact(
            icon: Icons.group_outlined,
            label: loop.participants.join(', '),
          ),
        if (loop.purpose != null)
          _Fact(icon: Icons.subject_outlined, label: loop.purpose!),
        if (loop.resolutionNote != null) ...[
          const SizedBox(height: 18),
          _InfoBanner(text: loop.resolutionNote!),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('save-loop-button'),
          onPressed: () async {
            await controller.saveLoop(loop);
            if (context.mounted) {
              Navigator.popUntil(context, (route) => route.isFirst);
            }
          },
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 17),
          ),
          child: Text(
            loop.kind == LoopKind.deadline ? 'OpenLoop 생성' : '일정 준비 완료',
          ),
        ),
      ],
    ),
  );
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
      setState(
        () => notice = widget.controller.baseUrl.isEmpty
            ? 'API URL을 설정하면 카카오 장소 검색을 사용할 수 있습니다.'
            : '장소 검색 결과가 없습니다.',
      );
      return;
    }
    final selected = await showModalBottomSheet<PlaceResult>(
      context: context,
      backgroundColor: OLColors.background,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(OLSpacing.md),
          children: [
            const Text(
              '장소 선택',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: OLSpacing.sm),
            ...results.map(
              (place) => ListTile(
                title: Text(place.name),
                subtitle: Text(place.address),
                trailing: const Icon(
                  Icons.chevron_right,
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
    final snapshot = await api.weather(
      latitude: selected.latitude,
      longitude: selected.longitude,
      at: loop.startsAt,
    );
    if (!mounted) return;
    final mapOpened = await api.openKakaoMap(selected);
    if (mapOpened) {
      await widget.controller.completeActionByType(loop, 'place');
      AppIntegrations.instance.capture('place_opened');
    }
    if (!mounted) return;
    setState(() {
      weather = snapshot;
      notice = mapOpened
          ? (snapshot.available
                ? '기상청 예보를 불러오고 카카오맵을 열었습니다.'
                : '카카오맵을 열었습니다. 현재 제공 가능한 기상청 예보가 없습니다.')
          : '기상청 예보를 불러왔지만 카카오맵을 열지 못했습니다.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final loop = widget.controller.loops
        .where((item) => item.id == widget.loopId)
        .firstOrNull;
    if (loop == null) {
      return const Scaffold(
        body: Center(child: Text('보관 기간에 따라 삭제된 Loop입니다.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(loop.state == LoopState.closed ? '닫힌 Loop' : 'Open Loop'),
        actions: loop.state == LoopState.closed
            ? null
            : [
                IconButton(
                  tooltip: '삭제',
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
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
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('삭제'),
                          ),
                        ],
                      ),
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
        padding: const EdgeInsets.all(22),
        children: [
          Icon(
            loop.state == LoopState.closed
                ? Icons.check_circle
                : (loop.kind == LoopKind.deadline
                      ? Icons.flag_outlined
                      : Icons.event_available),
            size: 50,
            color: loop.state == LoopState.closed
                ? OLColors.iconMuted
                : OLColors.cobalt,
          ),
          const SizedBox(height: 18),
          Text(
            loop.title,
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 26),
          _Fact(
            icon: Icons.calendar_today_outlined,
            label: dateText(loop.date),
          ),
          _Fact(
            icon: Icons.schedule_outlined,
            label: loop.time?.substring(0, 5) ?? '시간 미정',
          ),
          if (loop.place != null)
            _Fact(icon: Icons.place_outlined, label: loop.place!),
          if (loop.participants.isNotEmpty)
            _Fact(
              icon: Icons.group_outlined,
              label: loop.participants.join(', '),
            ),
          if (loop.purpose != null)
            _Fact(icon: Icons.subject_outlined, label: loop.purpose!),
          if (weather?.available == true) ...[
            const SizedBox(height: OLSpacing.md),
            OLCard(
              child: Row(
                children: [
                  const Icon(Icons.cloud_outlined, color: OLColors.cobalt),
                  const SizedBox(width: OLSpacing.md),
                  Expanded(
                    child: Text(
                      '${weather!.summary ?? '날씨'} · ${weather!.temperatureC?.toStringAsFixed(1) ?? '-'}°C · 강수 ${weather!.precipitationProbability ?? '-'}%',
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (loop.checklist.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              '체크리스트',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ...loop.checklist.map(
              (item) => CheckboxListTile(
                value: item.completed,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    Expanded(child: Text(item.title)),
                    const SizedBox(width: 8),
                    Text(
                      item.isRequired ? '필수' : '선택',
                      style: TextStyle(
                        color: item.isRequired
                            ? OLColors.cobalt
                            : OLColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                onChanged: loop.state == LoopState.closed
                    ? null
                    : (value) async {
                        await widget.controller.updateChecklist(
                          loop,
                          item,
                          value ?? false,
                        );
                        if (mounted) setState(() {});
                      },
              ),
            ),
          ],
          if (loop.actions.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              '실행 항목',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ...loop.actions.map(
              (item) => CheckboxListTile(
                value: item.completed,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    Expanded(child: Text(item.title)),
                    const SizedBox(width: 8),
                    Text(
                      item.completed ? '완료' : '대기',
                      style: TextStyle(
                        color: item.completed
                            ? OLColors.cobalt
                            : OLColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                onChanged: loop.state == LoopState.closed
                    ? null
                    : (value) async {
                        await widget.controller.updateAction(
                          loop,
                          item,
                          value ?? false,
                        );
                        if (mounted) setState(() {});
                      },
              ),
            ),
          ],
          if (loop.checkpoints.isNotEmpty) ...[
            const SizedBox(height: 22),
            const Text(
              '체크포인트',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ...loop.checkpoints.map(
              (item) => CheckboxListTile(
                value: item.completed,
                contentPadding: EdgeInsets.zero,
                title: Row(
                  children: [
                    Expanded(child: Text(item.title)),
                    const SizedBox(width: 8),
                    Text(
                      item.completed ? '완료' : item.offset,
                      style: TextStyle(
                        color: item.completed
                            ? OLColors.cobalt
                            : OLColors.muted,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                subtitle: item.dueAt == null
                    ? null
                    : Text(
                        item.dueAt!.toLocal().toString(),
                        style: const TextStyle(fontSize: 12),
                      ),
                onChanged: loop.state == LoopState.closed
                    ? null
                    : (value) async {
                        await widget.controller.updateCheckpoint(
                          loop,
                          item,
                          value ?? false,
                        );
                        if (mounted) setState(() {});
                      },
              ),
            ),
          ],
          if (notice != null) ...[
            const SizedBox(height: 14),
            _InfoBanner(text: notice!),
          ],
          const SizedBox(height: 24),
          if (loop.state != LoopState.closed) ...[
            if (loop.place != null)
              OutlinedButton.icon(
                onPressed: () => _openPlaceContext(loop),
                icon: const Icon(Icons.map_outlined),
                label: const Text('장소·날씨 보기'),
              ),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await widget.controller.deviceActions.addToCalendar(
                  loop,
                );
                if (ok) {
                  await widget.controller.completeActionByType(
                    loop,
                    'calendar',
                  );
                }
                if (mounted) {
                  setState(
                    () => notice = ok
                        ? '기기 캘린더 작성 화면을 열었습니다.'
                        : '캘린더를 열 수 없습니다. 날짜 또는 기기 권한을 확인해 주세요.',
                  );
                }
              },
              icon: const Icon(Icons.calendar_month_outlined),
              label: const Text('캘린더에 추가'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final ok = await widget.controller.deviceActions
                    .scheduleReminder(loop);
                if (ok) {
                  await widget.controller.completeActionByType(
                    loop,
                    'reminder',
                  );
                }
                if (mounted) {
                  setState(
                    () => notice = ok
                        ? '로컬 알림을 예약했습니다.'
                        : '알림 권한이 꺼져 있습니다. Loop는 그대로 저장됩니다.',
                  );
                }
              },
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('알림 예약'),
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

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController urlController;
  late RetentionPolicy retention;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.controller.baseUrl);
    retention = widget.controller.retention;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCapabilities());
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
          '분석 API',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          _connectionStatus,
          style: TextStyle(color: OLColors.muted, height: 1.45),
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
          '요청 실패 시 결과 화면에 로컬 fallback 사용 여부를 표시합니다. OPENLOOP_API_BASE_URL로 빌드별 서버를 지정할 수 있습니다.',
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

class LoopCard extends StatelessWidget {
  const LoopCard({super.key, required this.loop, required this.onTap});
  final OpenLoop loop;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final accent = loop.state == LoopState.closed
        ? OLColors.iconMuted
        : loop.state == LoopState.needsInput
        ? OLColors.warning
        : loop.kind == LoopKind.deadline
        ? OLColors.deadline
        : OLColors.cobalt;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: OLCard(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Icon(
              loop.kind == LoopKind.deadline
                  ? Icons.flag_outlined
                  : Icons.event_outlined,
              color: accent,
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    loop.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${dateText(loop.date)} · ${loop.time?.substring(0, 5) ?? '시간 미정'}${loop.place == null ? '' : ' · ${loop.place}'}',
                    style: const TextStyle(color: OLColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Text(
              stateText(loop.state),
              style: TextStyle(
                color: accent,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
    ),
  );
}

class _EmptyLoops extends StatelessWidget {
  const _EmptyLoops();
  @override
  Widget build(BuildContext context) => const OLCard(
    padding: EdgeInsets.symmetric(vertical: 42, horizontal: 22),
    child: Column(
      children: [
        Icon(Icons.inbox_outlined, size: 40, color: OLColors.iconMuted),
        SizedBox(height: 14),
        Text(
          '아직 Open Loop가 없습니다.',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 6),
        Text(
          '텍스트나 이미지를 공유해 첫 일정을 만들어 보세요.',
          textAlign: TextAlign.center,
          style: TextStyle(color: OLColors.muted),
        ),
      ],
    ),
  );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Icon(icon, color: OLColors.cobalt, size: 21),
        const SizedBox(width: 13),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 16))),
      ],
    ),
  );
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: OLColors.cobaltSoft,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: OLColors.cobalt.withValues(alpha: .22)),
    ),
    child: Text(text, style: const TextStyle(height: 1.45)),
  );
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();
  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Icon(Icons.lock_outline_rounded, size: 17, color: OLColors.iconMuted),
      SizedBox(width: 9),
      Expanded(
        child: Text(
          '직접 공유한 정보만 처리하고 원본 이미지는 저장하지 않습니다.',
          style: TextStyle(color: OLColors.muted, fontSize: 12),
        ),
      ),
    ],
  );
}

String dateText(DateTime? date) =>
    date == null ? '날짜 미정' : '${date.month}월 ${date.day}일';
String stateText(LoopState state) => switch (state) {
  LoopState.open => 'OPEN',
  LoopState.needsInput => '확인 필요',
  LoopState.closed => 'CLOSED',
};
String retentionText(RetentionPolicy policy) => switch (policy) {
  RetentionPolicy.immediately => '닫는 즉시 삭제',
  RetentionPolicy.sevenDays => '7일 후 삭제',
  RetentionPolicy.thirtyDays => '30일 후 삭제',
  RetentionPolicy.keep => '계속 보관',
};
