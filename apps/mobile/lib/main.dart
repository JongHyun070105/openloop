import 'package:flutter/material.dart';

void main() => runApp(const OpenLoopApp());

class OpenLoopApp extends StatelessWidget {
  const OpenLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenLoop',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF151714),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD8FF66),
          surface: Color(0xFF1D201C),
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const loops = [
    LoopPreview(
      title: '난포 저녁 약속',
      meta: '오늘 · 19:00 · 성수',
      status: 'OPEN',
      accent: Color(0xFFD8FF66),
      icon: Icons.restaurant_outlined,
    ),
    LoopPreview(
      title: 'AI 공모전 제출',
      meta: '8월 22일 · 3개 남음',
      status: 'D-7',
      accent: Color(0xFFFFBD66),
      icon: Icons.flag_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 22, 24, 8),
              sliver: SliverList.list(
                children: [
                  const _Header(),
                  const SizedBox(height: 42),
                  Text(
                    '오늘',
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: Colors.white54),
                  ),
                  const SizedBox(height: 12),
                  ...loops.map(
                    (loop) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: LoopCard(loop: loop),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const _CapturePanel(),
                  const SizedBox(height: 28),
                  const _PrivacyNote(),
                  const SizedBox(height: 100),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('capture-button'),
        onPressed: () => _showCaptureSheet(context),
        backgroundColor: const Color(0xFFD8FF66),
        foregroundColor: const Color(0xFF151714),
        icon: const Icon(Icons.add_rounded),
        label: const Text(
          '캡처 추가',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  void _showCaptureSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF242721),
      showDragHandle: true,
      builder: (context) => const Padding(
        padding: EdgeInsets.fromLTRB(24, 4, 24, 38),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'OpenLoop에 공유',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 8),
            Text(
              '이미 이해한 정보를 다시 입력하지 마세요.',
              style: TextStyle(color: Colors.white54),
            ),
            SizedBox(height: 22),
            Wrap(
              spacing: 10,
              children: [
                _InputChip(icon: Icons.image_outlined, label: '스크린샷'),
                _InputChip(icon: Icons.photo_outlined, label: '이미지'),
                _InputChip(icon: Icons.text_fields_rounded, label: '텍스트'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: Color(0xFFD8FF66),
              child: Text(
                'O',
                style: TextStyle(
                  color: Color(0xFF151714),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            SizedBox(width: 10),
            Text(
              'OpenLoop',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.8,
              ),
            ),
          ],
        ),
        IconButton(
          onPressed: () {},
          icon: const Icon(Icons.settings_outlined, color: Colors.white54),
        ),
      ],
    );
  }
}

class LoopPreview {
  const LoopPreview({
    required this.title,
    required this.meta,
    required this.status,
    required this.accent,
    required this.icon,
  });
  final String title;
  final String meta;
  final String status;
  final Color accent;
  final IconData icon;
}

class LoopCard extends StatelessWidget {
  const LoopCard({super.key, required this.loop});
  final LoopPreview loop;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF1D201C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: loop.accent.withValues(alpha: .12),
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(loop.icon, color: loop.accent),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  loop.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  loop.meta,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: loop.accent.withValues(alpha: .35)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              loop.status,
              style: TextStyle(
                color: loop.accent,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapturePanel extends StatelessWidget {
  const _CapturePanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: const Color(0xFFE7E4DA),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Capture → Create → Close',
            style: TextStyle(
              color: Color(0xFF657052),
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: 14),
          Text(
            '캡처 한 장이\n행동이 되는 순간.',
            style: TextStyle(
              color: Color(0xFF151714),
              fontSize: 27,
              height: 1.18,
              fontWeight: FontWeight.w800,
              letterSpacing: -1.1,
            ),
          ),
          SizedBox(height: 11),
          Text(
            'AI가 최종 합의와 빠진 정보를 구분해\n필요한 결정만 물어봅니다.',
            style: TextStyle(color: Color(0xFF62675D), height: 1.55),
          ),
        ],
      ),
    );
  }
}

class _PrivacyNote extends StatelessWidget {
  const _PrivacyNote();
  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Icon(Icons.lock_outline_rounded, size: 17, color: Colors.white38),
      SizedBox(width: 9),
      Expanded(
        child: Text(
          '직접 공유한 정보만 처리하고 원본 보관은 최소화합니다.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ),
    ],
  );
}

class _InputChip extends StatelessWidget {
  const _InputChip({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(icon, size: 18),
    label: Text(label),
    side: BorderSide.none,
    backgroundColor: Colors.white10,
  );
}
