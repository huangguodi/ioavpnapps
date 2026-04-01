import 'dart:io';

import 'package:app/core/logger.dart';
import 'package:app/views/ios_tunnel_debug_page.dart';
import 'package:app/views/widgets/custom_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DebugOverlayButton extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const DebugOverlayButton({super.key, required this.navigatorKey});

  @override
  State<DebugOverlayButton> createState() => _DebugOverlayButtonState();
}

class _DebugOverlayButtonState extends State<DebugOverlayButton> {
  bool _didAutoOpen = false;
  bool _isDialogOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeAutoOpen();
    });
  }

  void _maybeAutoOpen() {
    if (_didAutoOpen) {
      return;
    }
    _didAutoOpen = true;
    Future<void>.delayed(const Duration(milliseconds: 500), () async {
      if (!mounted) {
        return;
      }
      await _showLogs();
    });
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 16, bottom: 16),
          child: GestureDetector(
            onTap: _showLogs,
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFF96CBFF), width: 1),
              ),
              child: const Icon(
                Icons.bug_report_rounded,
                color: Color(0xFF96CBFF),
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showLogs() async {
    if (_isDialogOpen) {
      return;
    }
    final dialogContext = widget.navigatorKey.currentContext;
    if (dialogContext == null) {
      AppLogger.e('DebugOverlayButton: navigator context unavailable');
      return;
    }
    _isDialogOpen = true;
    await showAnimatedDialog<void>(
      context: dialogContext,
      barrierDismissible: true,
      builder: (alertContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1B2E40),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1),
          ),
          title: const Text(
            '运行日志',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: SizedBox(
            width: 360,
            height: 460,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.22),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ValueListenableBuilder<int>(
                  valueListenable: AppLogger.changes,
                  builder: (context, _, child) {
                    final logs = AppLogger.dumpLogs();
                    return SingleChildScrollView(
                      reverse: true,
                      child: SelectableText(
                        logs.isEmpty ? '暂无日志' : logs,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          actions: [
            if (Platform.isIOS)
              TextButton(
                onPressed: () async {
                  Navigator.of(alertContext).pop();
                  await Navigator.of(dialogContext).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const IosTunnelDebugPage(),
                    ),
                  );
                },
                child: const Text(
                  'Tunnel',
                  style: TextStyle(
                    color: Color(0xFF96CBFF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            TextButton(
              onPressed: () async {
                final logs = AppLogger.dumpLogs();
                await Clipboard.setData(ClipboardData(text: logs));
                if (alertContext.mounted) {
                  Navigator.of(alertContext).pop();
                }
              },
              child: const Text(
                '复制',
                style: TextStyle(
                  color: Color(0xFF96CBFF),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                AppLogger.clearLogs();
              },
              child: const Text(
                '清空',
                style: TextStyle(
                  color: Color(0xFF96CBFF),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(alertContext).pop(),
              child: const Text(
                '关闭',
                style: TextStyle(
                  color: Color(0xFF96CBFF),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
    _isDialogOpen = false;
  }
}
