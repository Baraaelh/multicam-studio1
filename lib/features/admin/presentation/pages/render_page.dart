import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/render_service.dart';

class RenderPage extends StatelessWidget {
  const RenderPage({super.key});

  @override
  Widget build(BuildContext context) {
    final service = Get.find<RenderService>();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (!service.isRendering.value) Get.back<void>();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Render'),
          leading: Obx(
            () => service.isRendering.value
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () => Get.back<void>(),
                  ),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Obx(() {
              final isRendering = service.isRendering.value;
              final output = service.outputPath.value;
              final error = service.errorMessage.value;
              final srcs = service.sources;

              if (output != null) {
                return _DoneView(outputPath: output);
              }
              if (error != null) {
                return _ErrorView(
                  error: error,
                  onRetry: service.startRender,
                );
              }
              final hasTimeline = service.segments.isNotEmpty;
              if (isRendering) {
                return _RenderingView(
                  sourceCount: srcs.length,
                  hasTimeline: hasTimeline,
                  onCancel: service.cancelRender,
                );
              }
              return _ReadyView(
                sources: srcs,
                hasTimeline: hasTimeline,
                onRender: service.startRender,
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ready state — shows input list and Start Render button
// ---------------------------------------------------------------------------

class _ReadyView extends StatelessWidget {
  final List<RenderSource> sources;
  final bool hasTimeline;
  final VoidCallback onRender;

  const _ReadyView({
    required this.sources,
    required this.hasTimeline,
    required this.onRender,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${sources.length} recording${sources.length == 1 ? '' : 's'} ready',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _layoutDescription(sources.length),
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 20),
        Expanded(
          child: ListView.separated(
            itemCount: sources.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final src = sources[i];
              return Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.videocam, color: Colors.white38, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            src.label,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(
                            src.filename,
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.check_circle,
                        color: Colors.green, size: 20),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: sources.isEmpty ? null : onRender,
            icon: const Icon(Icons.movie_edit),
            label: const Text('Start Render'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: Colors.deepPurpleAccent,
            ),
          ),
        ),
      ],
    );
  }

  String _layoutDescription(int n) => switch (n) {
        1 => 'Single camera — copy only, no re-encode.',
        _ => hasTimeline
            ? '$n cameras — timeline merge using switching history.'
            : '$n cameras — merged sequentially into one MP4.',
      };
}

// ---------------------------------------------------------------------------
// Rendering state — progress bar + cancel
// ---------------------------------------------------------------------------

class _RenderingView extends StatelessWidget {
  final int sourceCount;
  final bool hasTimeline;
  final VoidCallback onCancel;

  const _RenderingView({
    required this.sourceCount,
    required this.hasTimeline,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.movie_creation, size: 56, color: Colors.deepPurpleAccent),
        const SizedBox(height: 24),
        const Text(
          'Rendering…',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          '$sourceCount track${sourceCount == 1 ? '' : 's'} → ${hasTimeline ? 'timeline merge' : 'sequential merge'}',
          style: const TextStyle(color: Colors.white54),
        ),
        const SizedBox(height: 32),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: const LinearProgressIndicator(
            value: null,
            backgroundColor: Colors.white12,
            valueColor:
                AlwaysStoppedAnimation<Color>(Colors.deepPurpleAccent),
            minHeight: 8,
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Processing…',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 40),
        OutlinedButton.icon(
          onPressed: onCancel,
          icon: const Icon(Icons.close),
          label: const Text('Cancel'),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white54,
            side: const BorderSide(color: Colors.white24),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Done state — success + output path
// ---------------------------------------------------------------------------

class _DoneView extends StatelessWidget {
  final String outputPath;
  const _DoneView({required this.outputPath});

  @override
  Widget build(BuildContext context) {
    final filename = outputPath.split('/').last;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.check_circle_outline,
            size: 72, color: Colors.greenAccent),
        const SizedBox(height: 24),
        const Text(
          'Render Complete',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          filename,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 13),
        ),
        const SizedBox(height: 8),
        Text(
          outputPath,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white30, fontSize: 11),
        ),
        const SizedBox(height: 48),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => Get.back<void>(),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to Session'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
              minimumSize: const Size.fromHeight(48),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Error state — error message + retry
// ---------------------------------------------------------------------------

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error_outline, size: 56, color: Colors.redAccent),
        const SizedBox(height: 20),
        const Text(
          'Render Failed',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.redAccent.withValues(alpha: 0.3)),
          ),
          child: Text(
            error,
            style: const TextStyle(
                color: Colors.white54, fontSize: 12, fontFamily: 'monospace'),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 32),
        FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
          style: FilledButton.styleFrom(
            backgroundColor: Colors.deepPurpleAccent,
            minimumSize: const Size(140, 48),
          ),
        ),
      ],
    );
  }
}
