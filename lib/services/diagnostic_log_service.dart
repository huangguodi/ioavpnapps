import 'dart:collection';

class DiagnosticLogService {
  static const int _maxEntries = 600;
  static final ListQueue<String> _entries = ListQueue<String>(_maxEntries);

  static void add(String tag, String message) {
    final now = DateTime.now().toIso8601String();
    _entries.addLast('[$now][$tag] $message');
    if (_entries.length > _maxEntries) {
      _entries.removeFirst();
    }
  }

  static String dump() {
    if (_entries.isEmpty) {
      return 'No logs collected.';
    }
    return _entries.join('\n');
  }
}
