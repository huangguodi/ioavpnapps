import 'package:app/views/widgets/custom_dialog.dart';
import 'package:flutter/material.dart';

class GlobalAppErrorReporter {
  static GlobalKey<NavigatorState>? _navigatorKey;
  static bool _showing = false;

  static void initialize(GlobalKey<NavigatorState> navigatorKey) {
    _navigatorKey = navigatorKey;
  }

  static Future<void> showError({
    String title = '应用错误',
    required String message,
    String? detail,
  }) async {
    if (_showing) return;
    final context = _navigatorKey?.currentContext;
    if (context == null) return;
    _showing = true;
    await showAnimatedDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(title),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message),
                  if (detail != null && detail.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      detail,
                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
    _showing = false;
  }
}
