import 'package:app/core/logger.dart';
import 'package:app/views/widgets/custom_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DebugOverlayButton extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const DebugOverlayButton({
    super.key,
    required this.navigatorKey,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.center,
      child: GestureDetector(
        onTap: () => _showLogs(context),
        child: Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF96CBFF), width: 1),
          ),
          child: const Icon(Icons.bug_report_rounded, color: Color(0xFF96CBFF), size: 24),
        ),
      ),
    );
  }

  Future<void> _showLogs(BuildContext context) async {
    final dialogContext = navigatorKey.currentContext;
    if (dialogContext == null) {
      AppLogger.e('DebugOverlayButton: navigator context unavailable');
      return;
    }
    final logs = AppLogger.dumpLogs();
    await showAnimatedDialog<void>(
      context: dialogContext,
      barrierDismissible: true,
      builder: (alertContext) {
        return AlertDialog(
          title: const Text('调试日志'),
          content: SizedBox(
            width: 360,
            height: 420,
            child: SingleChildScrollView(
              child: SelectableText(
                logs.isEmpty ? '暂无日志' : logs,
                style: const TextStyle(fontSize: 12, height: 1.45),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: logs));
                if (alertContext.mounted) {
                  Navigator.of(alertContext).pop();
                }
              },
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () {
                AppLogger.clearLogs();
                Navigator.of(alertContext).pop();
              },
              child: const Text('清空'),
            ),
            TextButton(
              onPressed: () => Navigator.of(alertContext).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}
