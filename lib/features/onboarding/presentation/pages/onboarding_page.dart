import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../data/onboarding_store.dart';

const _background = Color(0xFF0A0E17);
const _card = Color(0xFF151B28);
const _accent = Colors.cyanAccent;

/// Welcome screen shown on first launch: what the app does, how to use it,
/// and the usage policy the user must accept before continuing.
///
/// With [review] set (opened from "How to use"), the terms are already
/// accepted and the last page just closes the guide.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    this.review = false,
    this.store = const OnboardingStore(),
  });

  final bool review;
  final OnboardingStore store;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _controller = PageController();
  int _page = 0;
  late bool _agreed = widget.review;
  late bool _checking = !widget.review;

  static const _pageCount = 5;
  bool get _isLast => _page == _pageCount - 1;

  @override
  void initState() {
    super.initState();
    if (!widget.review) _skipIfAccepted();
  }

  Future<void> _skipIfAccepted() async {
    final accepted = await widget.store.isAccepted();
    if (!mounted) return;
    if (accepted) {
      Get.offAllNamed('/');
    } else {
      setState(() => _checking = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _goTo(int page) => _controller.animateToPage(
        page,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );

  Future<void> _finish() async {
    if (widget.review) {
      Get.back<void>();
      return;
    }
    await widget.store.accept();
    Get.offAllNamed('/');
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(backgroundColor: _background);
    }
    return Scaffold(
      backgroundColor: _background,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Visibility(
                visible: !_isLast,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: TextButton(
                  onPressed: () => _goTo(_pageCount - 1),
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  const _WelcomeStep(),
                  const _StepsPage(
                    icon: Icons.auto_awesome_motion,
                    title: 'How it works',
                    subtitle: 'From tap to finished video in five steps',
                    steps: [
                      ('Join', 'Camera phones enter the session code'),
                      ('Go live', 'Every angle streams to the director over Wi-Fi'),
                      ('Record', 'All phones start at the same instant'),
                      ('Transfer', 'Files move to the director automatically'),
                      ('Render', 'One video, cut where you switched'),
                    ],
                  ),
                  const _StepsPage(
                    icon: Icons.dashboard,
                    title: 'Director phone',
                    subtitle: 'Run the shoot from Admin Mode',
                    steps: [
                      ('Create a session', 'Open Admin Mode and tap Create Session'),
                      ('Share the code', 'Give the 6-digit code to each camera operator'),
                      ('Go live', 'Pick the quality and audio source'),
                      ('Record and cut', 'START REC, then tap a camera to put it on air'),
                      ('Stop', 'STOP REC collects the files and renders the video'),
                    ],
                  ),
                  const _StepsPage(
                    icon: Icons.videocam,
                    title: 'Camera phones',
                    subtitle: 'Join once, then just frame the shot',
                    steps: [
                      ('Join', 'Open Camera Mode and enter the code'),
                      ('Allow access', 'Grant camera and microphone permissions'),
                      ('Stay open', 'Recording starts and stops on the director\'s command'),
                      ('Wait for transfer', 'Keep the app open until the file is sent'),
                    ],
                    tip: 'Keep every phone on the same Wi-Fi and charged. '
                        'Use 720p on older phones and your newest phone for audio.',
                  ),
                  const _PolicyStep(),
                ],
              ),
            ),
            if (_isLast && !widget.review)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: CheckboxListTile(
                  value: _agreed,
                  onChanged: (v) => setState(() => _agreed = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    'I have read and agree to the Terms and Privacy Policy',
                    style: TextStyle(fontSize: 14, color: Colors.white),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Row(
                children: [
                  for (var i = 0; i < _pageCount; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsetsDirectional.only(end: 6),
                      width: i == _page ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _page ? _accent : Colors.white24,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  const Spacer(),
                  if (_isLast)
                    FilledButton(
                      onPressed: _agreed ? _finish : null,
                      style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
                      child: Text(widget.review ? 'Done' : 'Get started'),
                    )
                  else
                    FilledButton(
                      onPressed: () => _goTo(_page + 1),
                      style: FilledButton.styleFrom(minimumSize: const Size(140, 48)),
                      child: const Text('Next'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomeStep extends StatelessWidget {
  const _WelcomeStep();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.videocam, size: 100, color: _accent),
          const SizedBox(height: 24),
          const Text(
            'Multicam Studio',
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
          ),
          const SizedBox(height: 12),
          const Text(
            'Turn a few Android phones into a synced studio: shoot from every '
            'angle, cut live, and get one finished video.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: Colors.white70, height: 1.5),
          ),
          const SizedBox(height: 48),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              children: [
                Text(
                  'SYSTEM DEVELOPER',
                  style: TextStyle(fontSize: 11, letterSpacing: 2, color: Colors.white38),
                ),
                SizedBox(height: 4),
                Text(
                  'Baraa Alhaddad',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StepsPage extends StatelessWidget {
  const _StepsPage({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.steps,
    this.tip,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<(String, String)> steps;
  final String? tip;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      children: [
        Icon(icon, size: 56, color: _accent),
        const SizedBox(height: 16),
        Text(
          title,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: const TextStyle(fontSize: 15, color: Colors.white54)),
        const SizedBox(height: 24),
        for (final (i, (name, detail)) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                  child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        detail,
                        style: const TextStyle(fontSize: 14, color: Colors.white60, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (tip != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lightbulb_outline, color: Colors.amberAccent, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    tip!,
                    style: const TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _PolicyStep extends StatelessWidget {
  const _PolicyStep();

  static const _points = [
    (Icons.phone_android, 'Your videos stay on your phones and move only over your local Wi-Fi.'),
    (Icons.person_off, 'No account needed: the app signs in anonymously and collects no personal data.'),
    (Icons.timer, 'Session codes expire after 24 hours and session data is deleted when it ends.'),
    (Icons.record_voice_over, 'Get consent from everyone you record and follow local laws.'),
    (Icons.info_outline, 'The app is provided as is; keep backups of important footage.'),
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      children: [
        const Icon(Icons.shield, size: 56, color: _accent),
        const SizedBox(height: 16),
        const Text(
          'Usage & privacy',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
        ),
        const SizedBox(height: 6),
        const Text(
          'Please read before you start',
          style: TextStyle(fontSize: 15, color: Colors.white54),
        ),
        const SizedBox(height: 20),
        for (final (icon, text) in _points)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 20, color: _accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    text,
                    style: const TextStyle(fontSize: 14, color: Colors.white70, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => Get.toNamed<void>('/border'),
              child: const Text('Full Terms'),
            ),
            TextButton(
              onPressed: () => Get.toNamed<void>('/policy'),
              child: const Text('Privacy Policy'),
            ),
          ],
        ),
      ],
    );
  }
}
