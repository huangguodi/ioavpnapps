import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/core/constants.dart';
import 'package:app/core/logger.dart';
import 'package:app/services/api_service.dart'; // Import ApiService
import 'package:app/views/widgets/custom_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MihomoService {
  static const MethodChannel _channel = MethodChannel(
    'com.accelerator.tg/mihomo',
  );
  static const String _iosPersistedModeKey = 'ios_persisted_vpn_mode';
  static const bool _verboseNativeLogs = bool.fromEnvironment(
    'MIHOMO_VERBOSE_NATIVE_LOGS',
    defaultValue: false,
  );
  static const Duration _proxyCacheTtl = Duration(seconds: 12);
  static const Duration _statusCacheTtl = Duration(seconds: 2);
  static const Duration _daemonCheckInterval = Duration(seconds: 5);
  static const Duration _initialDaemonCheckDelay = Duration(seconds: 3);
  static const Duration _windowsStatusQueryCooldown = Duration(
    milliseconds: 900,
  );
  static const Duration _iosPostStartStatusCooldown = Duration(seconds: 2);
  static const Duration _iosProxyStartupCooldown = Duration(seconds: 8);
  static const Duration _iosDaemonCheckInitialDelay = Duration(seconds: 20);
  static const Duration _iosRunningGraceWindow = Duration(seconds: 45);
  static const Duration _startupReadyProbeTimeout = Duration(milliseconds: 900);
  static const Duration _iosStartupReadyProbeTimeout = Duration(milliseconds: 2500);
  static const Duration _startupReadyPollInterval = Duration(milliseconds: 350);
  static final MihomoService _instance = MihomoService._internal();

  factory MihomoService() {
    return _instance;
  }

  MihomoService._internal();

  bool _isRunning = false;
  String? _lastSubscribeUrl;
  Timer? _daemonTimer;
  int _restartCount = 0;
  int _daemonConsecutiveFailures = 0;
  bool _isShowingStartErrorDialog = false;
  String? _lastSelectedGlobalProxy;
  bool? _cachedIsRunning;
  DateTime? _cachedIsRunningAt;
  String? _cachedMode;
  DateTime? _cachedModeAt;
  final Map<String, String> _cachedSelectedProxyByGroup = {};
  final Map<String, DateTime> _cachedSelectedProxyAtByGroup = {};
  Future<bool>? _pendingIsRunningRequest;
  Future<String>? _pendingModeRequest;
  final Map<String, Future<String?>> _pendingSelectedProxyRequestsByGroup = {};
  Future<Map<String, dynamic>>? _pendingProxiesRequest;
  bool _isDaemonCheckActive = false;
  bool _isDaemonCheckInFlight = false;
  DateTime? _deferNonCriticalStatusQueriesUntil;
  DateTime? _lastNativeStartAt;
  DateTime? _lastStartCallTime;

  // Cache proxies to avoid first-time lag
  Map<String, dynamic>? _cachedProxies;
  DateTime? _cachedProxiesAt;

  // ignore: unused_field
  int _suppressedNativeConnectionLogCount = 0;
  StreamSubscription<dynamic>? _nativeLogsSubscription;
  StreamSubscription<dynamic>? _iosTunnelStatusSubscription;
  final StreamController<bool> _runningStateController =
      StreamController<bool>.broadcast();

  bool get isRunning => _isRunning;
  Stream<bool> get runningStateStream => _runningStateController.stream;
  String? get lastSelectedGlobalProxy => _lastSelectedGlobalProxy;
  Map<String, dynamic>? get cachedProxies {
    if (!_isProxyCacheFresh) {
      return null;
    }
    return _cachedProxies;
  }

  Stream<dynamic>? _trafficStream;

  Stream<dynamic> get trafficStream {
    _trafficStream ??= const EventChannel(
      'com.accelerator.tg/mihomo/traffic',
    ).receiveBroadcastStream();
    return _trafficStream!;
  }

  Duration get nonCriticalStatusQueryDelay {
    final until = _deferNonCriticalStatusQueriesUntil;
    if (until == null) {
      return Duration.zero;
    }
    final remaining = until.difference(DateTime.now());
    if (remaining.isNegative || remaining == Duration.zero) {
      _deferNonCriticalStatusQueriesUntil = null;
      return Duration.zero;
    }
    return remaining;
  }

  bool get _isProxyCacheFresh {
    final cachedAt = _cachedProxiesAt;
    final cachedProxies = _cachedProxies;
    if (cachedAt == null || cachedProxies == null || cachedProxies.isEmpty) {
      return false;
    }
    return DateTime.now().difference(cachedAt) <= _proxyCacheTtl;
  }

  void _updateProxyCache(Map<String, dynamic> proxies) {
    _cachedProxies = proxies;
    _cachedProxiesAt = DateTime.now();
  }

  void _invalidateProxyCache() {
    _cachedProxies = null;
    _cachedProxiesAt = null;
  }

  bool _isStatusCacheFresh(DateTime? cachedAt) {
    if (cachedAt == null) {
      return false;
    }
    return DateTime.now().difference(cachedAt) <= _statusCacheTtl;
  }

  void _cacheRunningState(bool isRunning) {
    final changed = _isRunning != isRunning;
    _cachedIsRunning = isRunning;
    _cachedIsRunningAt = DateTime.now();
    _isRunning = isRunning;
    if (changed && !_runningStateController.isClosed) {
      _runningStateController.add(isRunning);
    }
  }

  void _cacheMode(String mode) {
    _cachedMode = mode;
    _cachedModeAt = DateTime.now();
  }

  void _cacheSelectedProxy(String groupName, String proxyName) {
    _cachedSelectedProxyByGroup[groupName] = proxyName;
    _cachedSelectedProxyAtByGroup[groupName] = DateTime.now();
  }

  void _invalidateLightweightStatusCache() {
    _cachedMode = null;
    _cachedModeAt = null;
    _cachedSelectedProxyByGroup.clear();
    _cachedSelectedProxyAtByGroup.clear();
  }

  void _deferNonCriticalStatusQueries(Duration duration) {
    final until = DateTime.now().add(duration);
    final current = _deferNonCriticalStatusQueriesUntil;
    if (current == null || until.isAfter(current)) {
      _deferNonCriticalStatusQueriesUntil = until;
    }
  }

  Future<void> waitForNonCriticalStatusQueryWindow() async {
    final delay = nonCriticalStatusQueryDelay;
    if (delay <= Duration.zero) {
      return;
    }
    await Future.delayed(delay);
  }

  Future<void> init() async {
    _listenToNativeLogs();
    _listenToIosTunnelStatus();
  }

  void _listenToIosTunnelStatus() {
    if (!Platform.isIOS || _iosTunnelStatusSubscription != null) {
      return;
    }
    _iosTunnelStatusSubscription =
        const EventChannel(
          'com.accelerator.tg/mihomo/status',
        ).receiveBroadcastStream().listen(
          (event) {
            bool? running;
            if (event is Map) {
              final raw = event['running'];
              if (raw is bool) {
                running = raw;
              } else if (raw is num) {
                running = raw != 0;
              } else if (raw is String) {
                final normalized = raw.trim().toLowerCase();
                running = normalized == 'true' || normalized == '1';
              }
            } else if (event is bool) {
              running = event;
            }
            if (running == null) {
              return;
            }
            _cacheRunningState(running);
            if (!running) {
              _invalidateLightweightStatusCache();
              _invalidateProxyCache();
            }
          },
          onError: (error) {
            AppLogger.e("MihomoService: iOS tunnel status stream error: $error");
          },
        );
  }

  /// Listen to native logs
  void _listenToNativeLogs() {
    if (!Platform.isAndroid || _nativeLogsSubscription != null) {
      return;
    }
    _nativeLogsSubscription =
        const EventChannel(
          'com.accelerator.tg/mihomo/logs',
        ).receiveBroadcastStream().listen(
          (event) {
            final message = (event ?? '').toString();
            if (!_verboseNativeLogs && _isNoisyConnectionLog(message)) {
              _suppressedNativeConnectionLogCount++;
              if (_suppressedNativeConnectionLogCount % 50 == 0) {
                AppLogger.d(
                  "NATIVE_LOG: suppressed=$_suppressedNativeConnectionLogCount",
                );
              }
              return;
            }
            AppLogger.d("NATIVE_LOG: $message");
          },
          onError: (error) {
            AppLogger.e("NATIVE_LOG_ERROR: $error");
          },
        );
  }

  bool _isNoisyConnectionLog(String message) {
    final lower = message.toLowerCase();
    // Common noisy patterns in Clash kernel logs
    if (lower.contains(" match ") && lower.contains(" using ")) return true;
    if (lower.contains("dns query")) return true;
    if (lower.contains("connection from")) return true;
    if (lower.contains("dial")) return true;
    if (lower.contains("connect")) return true;
    if (lower.contains("inbound")) return true;
    if (lower.contains("outbound")) return true;
    if (lower.contains("tcp")) return true;
    if (lower.contains("udp")) return true;
    return false;
  }

  Future<Directory> _getWorkingDir() async {
    if (Platform.isIOS) {
      try {
        final path = await _channel.invokeMethod<String>('getAppGroupDirectory');
        if (path != null && path.isNotEmpty) {
          return Directory(path);
        }
      } catch (e) {
        AppLogger.e("MihomoService: Failed to get App Group Directory: $e");
      }
    }
    return await getApplicationSupportDirectory();
  }

  Future<String> _saveConfig(String content) async {
    final directory = await _getWorkingDir();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File('${directory.path}/config.yaml');
    if (await file.exists()) {
      final existing = await file.readAsString();
      if (existing == content) {
        return file.path;
      }
    }
    await file.writeAsString(content);
    return file.path;
  }

  Future<void> _updateConfigFileMode(String mode) async {
    try {
      final directory = await _getWorkingDir();
      final configFile = File('${directory.path}/config.yaml');
      if (await configFile.exists()) {
        final originalContent = await configFile.readAsString();
        String nextContent = originalContent;
        if (nextContent.contains(RegExp(r'^mode:', multiLine: true))) {
          nextContent = nextContent.replaceAll(
            RegExp(r'^mode:.*$', multiLine: true),
            'mode: $mode',
          );
        } else {
          nextContent = 'mode: $mode\n$nextContent';
        }
        if (nextContent == originalContent) {
          return;
        }
        await configFile.writeAsString(nextContent);
        AppLogger.d("MihomoService: Config file updated for persistence.");
      }
    } catch (e) {
      AppLogger.e("Error updating config file: $e");
    }
  }

  Future<bool> persistMode(String mode) async {
    try {
      if (Platform.isIOS) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_iosPersistedModeKey, mode);
      }
      await _updateConfigFileMode(mode);
      final storedMode = await readStoredMode();
      if (storedMode == mode) {
        _cacheMode(mode);
        return true;
      }
      AppLogger.w(
        "MihomoService: persistMode verification failed. expected=$mode actual=$storedMode",
      );
      return false;
    } catch (e) {
      AppLogger.e("MihomoService: persistMode error: $e");
      return false;
    }
  }

  Future<String?> readStoredMode() async {
    try {
      if (Platform.isIOS) {
        final prefs = await SharedPreferences.getInstance();
        final persisted = prefs.getString(_iosPersistedModeKey)?.trim();
        if (persisted != null && persisted.isNotEmpty) {
          _cacheMode(persisted);
          return persisted;
        }
      }
      final directory = await _getWorkingDir();
      final configFile = File('${directory.path}/config.yaml');
      if (!await configFile.exists()) {
        return null;
      }
      final content = await configFile.readAsString();
      final mode = _extractModeFromConfig(content);
      if (mode != null && mode.isNotEmpty) {
        _cacheMode(mode);
      }
      return mode;
    } catch (e) {
      AppLogger.e("MihomoService: readStoredMode error: $e");
      return null;
    }
  }

  Future<String?> start({required String subscribeUrl}) async {
    try {
      if (Platform.isIOS) {
        final now = DateTime.now();
        if (_lastStartCallTime != null && now.difference(_lastStartCallTime!) < const Duration(milliseconds: 300)) {
          AppLogger.d("MihomoService: start debounced");
          return null;
        }
        _lastStartCallTime = now;
      }

      final normalizedUrl = _normalizeSubscribeUrl(subscribeUrl);
      if (normalizedUrl == null) {
        return "Invalid subscribe url";
      }
      AppLogger.d("MihomoService: Starting with URL: $normalizedUrl");
      _lastSubscribeUrl = normalizedUrl;

      // Download config using ApiService.sharedClient to ensure consistent SSL policy
      final response = await ApiService.sharedClient
          .get(Uri.parse(normalizedUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return "Config download failed: ${response.statusCode}";
      }

      var configContent = utf8.decode(response.bodyBytes);
      final trimmed = configContent.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('<')) {
        return "Config payload is invalid";
      }
      if (!configContent.contains('proxies:') &&
          !configContent.contains('proxy-groups:')) {
        return "Config format invalid";
      }

      if (Platform.isIOS) {
        final granted = await requestVpnPermission();
        if (!granted) {
          const error = "VPN permission denied";
          await _showStartErrorDialog(error);
          return error;
        }
        final error = await _startNative('', configContent);
        if (error != null) {
          await _showStartErrorDialog(error);
        }
        return error;
      }

      final configPath = await _saveConfig(configContent);

      final error = await _startNative(configPath, configContent);
      if (error != null) {
        await _showStartErrorDialog(error);
      }
      return error;
    } catch (e) {
      AppLogger.e("MihomoService: Start error: $e");
      final error = e.toString();
      await _showStartErrorDialog(error);
      return error;
    }
  }

  Future<bool> requestVpnPermission() async {
    if (!Platform.isIOS) return true;
    try {
      final result = await _channel.invokeMethod('requestVpnPermission');
      return result == true;
    } on PlatformException catch (e) {
      final message = (e.message ?? '').toLowerCase();
      AppLogger.e("MihomoService: requestVpnPermission error: ${e.message}");
      if (message.contains('permission denied') ||
          message.contains('not authorized')) {
        return false;
      }
      return true;
    } catch (e) {
      AppLogger.e("MihomoService: requestVpnPermission exception: $e");
      return true;
    }
  }

  String? _normalizeSubscribeUrl(String raw) {
    var url = raw.trim().replaceAll('`', '');
    while (url.endsWith(',') || url.endsWith('，') || url.endsWith(';')) {
      url = url.substring(0, url.length - 1).trimRight();
    }
    if (url.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    return uri.toString();
  }

  Future<String?> _startNative(
    String configPath,
    String configContent, {
    bool restartDaemonCheck = true,
  }) async {
    try {
      AppLogger.d("MihomoService: Invoking native start.");
      await _channel.invokeMethod('start', {
        'configPath': configPath,
        'configContent': configContent,
      });

      _isRunning = true;
      _restartCount = 0;
      if (Platform.isIOS) {
        _cachedIsRunning = null;
        _cachedIsRunningAt = null;
      } else {
        _cacheRunningState(true);
      }
      _lastNativeStartAt = DateTime.now();
      await _restoreRoutingFromConfig(configContent);
      final restoredMode = _extractModeFromConfig(configContent);
      if (restoredMode != null) {
        _cacheMode(restoredMode);
      }
      final restoredSelection = _extractPrimarySelection(configContent);
      final restoredProxyName = restoredSelection?['name'];
      if (restoredProxyName != null && restoredProxyName.isNotEmpty) {
        _lastSelectedGlobalProxy = restoredProxyName;
        _cacheSelectedProxy('GLOBAL', restoredProxyName);
      }
      _invalidateProxyCache();
      if (restartDaemonCheck) {
        _startDaemonCheck();
      }

      if (Platform.isIOS) {
        _deferNonCriticalStatusQueries(_iosPostStartStatusCooldown);
      }

      if (!Platform.isIOS) {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!_isRunning) {
            return;
          }
          unawaited(getProxies(forceRefresh: true));
        });
      }

      return null;
    } on PlatformException catch (e) {
      _isRunning = false;
      _cachedIsRunning = null;
      _cachedIsRunningAt = null;
      return "Native Start Error: ${e.message}";
    } catch (e) {
      _isRunning = false;
      _cachedIsRunning = null;
      _cachedIsRunningAt = null;
      return "Start Exception: $e";
    }
  }

  Future<void> _showStartErrorDialog(String message) async {
    if (_isShowingStartErrorDialog) {
      return;
    }
    _isShowingStartErrorDialog = true;
    try {
      await showGlobalMessageDialog(
        title: '启动失败',
        message: message,
      );
    } finally {
      _isShowingStartErrorDialog = false;
    }
  }

  Future<void> _restoreRoutingFromConfig(String configContent) async {
    final mode = _extractModeFromConfig(configContent);
    if (mode != null) {
      try {
        await _channel.invokeMethod('changeMode', {'mode': mode});
      } catch (e) {
        AppLogger.w("MihomoService: restore mode failed: $e");
      }
    }

    final selection = _extractPrimarySelection(configContent);
    if (selection != null) {
      try {
        await _channel.invokeMethod('selectProxyByGroup', selection);
      } catch (e) {
        AppLogger.w("MihomoService: restore group selection failed: $e");
      }
    }
  }

  String? _extractModeFromConfig(String configContent) {
    final match = RegExp(
      r'^mode:\s*([A-Za-z]+)\s*$',
      multiLine: true,
    ).firstMatch(configContent);
    if (match == null) return null;
    final mode = (match.group(1) ?? '').trim().toLowerCase();
    if (mode == 'rule' || mode == 'global' || mode == 'direct') return mode;
    return null;
  }

  Map<String, String>? _extractPrimarySelection(String configContent) {
    final lines = const LineSplitter().convert(configContent);
    var inProxyGroups = false;
    String? currentGroup;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      if (!inProxyGroups) {
        if (trimmed == 'proxy-groups:') {
          inProxyGroups = true;
        }
        continue;
      }

      if (trimmed.isEmpty) continue;
      if (!raw.startsWith(' ') && !raw.startsWith('\t')) break;

      if (trimmed.startsWith('- name:')) {
        currentGroup = trimmed
            .substring(7)
            .trim()
            .replaceAll('"', '')
            .replaceAll("'", '');
        continue;
      }

      if (currentGroup == null || trimmed != 'proxies:') {
        continue;
      }

      for (var j = i + 1; j < lines.length; j++) {
        final itemRaw = lines[j];
        final itemTrimmed = itemRaw.trim();
        if (itemTrimmed.isEmpty) continue;
        if (!itemRaw.startsWith('  ') && !itemRaw.startsWith('\t')) {
          break;
        }
        if (!itemTrimmed.startsWith('- ')) {
          break;
        }

        final proxyName = itemTrimmed
            .substring(2)
            .trim()
            .replaceAll('"', '')
            .replaceAll("'", '');
        if (proxyName.isNotEmpty) {
          return {'groupName': currentGroup, 'name': proxyName};
        }
      }
    }

    return null;
  }

  Future<void> stop() async {
    try {
      _daemonTimer?.cancel();
      _daemonTimer = null;
      _isDaemonCheckActive = false;
      AppPollingTaskRegistry.instance.setTaskActive('daemon_watchdog', false);
      _daemonConsecutiveFailures = 0;
      await _channel.invokeMethod('stop');
      _cacheRunningState(false);
      _invalidateLightweightStatusCache();
      _invalidateProxyCache();
      AppLogger.d("MihomoService: Stopped.");
    } catch (e) {
      AppLogger.e("MihomoService: Stop error: $e");
    }
  }

  Future<bool> checkIsRunning({bool forceRefresh = false}) async {
    if (!forceRefresh &&
        _isStatusCacheFresh(_cachedIsRunningAt) &&
        _cachedIsRunning != null) {
      return _cachedIsRunning!;
    }
    final pending = forceRefresh ? null : _pendingIsRunningRequest;
    if (pending != null) {
      return pending;
    }
    final future = _checkIsRunningNative();
    if (!forceRefresh) {
      _pendingIsRunningRequest = future;
    }
    try {
      return await future;
    } finally {
      if (!forceRefresh && identical(_pendingIsRunningRequest, future)) {
        _pendingIsRunningRequest = null;
      }
    }
  }

  Future<bool> _checkIsRunningNative() async {
    try {
      final bool? result = await _channel.invokeMethod('isRunning');
      var resolved = result ?? false;
      // In iOS, the native channel strictly checks the NEVPNStatus (.connected, .connecting, .reasserting).
      // This is a reliable system-level state. Do not artificially fail it just because of grace windows.
      if (Platform.isIOS) {
        _cacheRunningState(resolved);
        return resolved;
      }
      _cacheRunningState(resolved);
      return resolved;
    } catch (e) {
      _cacheRunningState(false);
      return false;
    }
  }

  Future<int?> urlTestProxy(String proxyName) async {
    try {
      final dynamic result = await _channel.invokeMethod('urlTest', {
        'name': proxyName,
      });
      if (result is int) return result;
      if (result is String) {
        if (result.isEmpty) return null;

        // Clean up string: remove 'ms', spaces, etc. to get pure number
        // Allow digits and minus sign
        final cleanResult = result.replaceAll(RegExp(r'[^0-9-]'), '');
        if (cleanResult.isEmpty) return null;

        final asInt = int.tryParse(cleanResult);
        if (asInt != null) return asInt;

        // Try to parse as JSON (if original string was JSON)
        try {
          final Map<String, dynamic> map = json.decode(result);
          if (map.containsKey('delay')) return map['delay'] as int?;
          if (map.containsKey('mean')) return map['mean'] as int?;
        } catch (_) {}
      }
      return null;
    } catch (e) {
      AppLogger.e("MihomoService: urlTest error: $e");
      return null;
    }
  }

  Future<String> getTunnelDebugLog() async {
    if (!Platform.isIOS) {
      return '当前仅支持 iOS';
    }
    try {
      final String? result = await _channel.invokeMethod('getTunnelDebugLog');
      return result ?? '';
    } catch (e) {
      AppLogger.e("MihomoService: getTunnelDebugLog error: $e");
      return '读取 Tunnel 日志失败：$e';
    }
  }

  Future<bool> switchMode(String mode) async {
    try {
      await _channel.invokeMethod('changeMode', {'mode': mode});
      await _updateConfigFileMode(mode);
      _cacheMode(mode);
      _invalidateProxyCache();
      return true;
    } catch (e) {
      AppLogger.e("MihomoService: switchMode error: $e");
      return false;
    }
  }

  Future<bool> selectProxy(String proxyName) async {
    try {
      final dynamic ok = await _channel.invokeMethod('selectProxy', {
        'name': proxyName,
      });
      final success = ok is bool ? ok : true;
      if (success) {
        _lastSelectedGlobalProxy = proxyName;
        _cacheSelectedProxy('GLOBAL', proxyName);
        _invalidateProxyCache();
      }
      return success;
    } catch (e) {
      AppLogger.e("MihomoService: selectProxy error: $e");
      return false;
    }
  }

  Future<String> getMode({bool forceRefresh = false, Duration? timeout}) async {
    if (!forceRefresh &&
        _isStatusCacheFresh(_cachedModeAt) &&
        _cachedMode != null) {
      return _cachedMode!;
    }
    final pending = forceRefresh ? null : _pendingModeRequest;
    if (pending != null) {
      return pending;
    }
    final future = _getModeNative(timeout: timeout);
    if (!forceRefresh) {
      _pendingModeRequest = future;
    }
    try {
      return await future;
    } finally {
      if (!forceRefresh && identical(_pendingModeRequest, future)) {
        _pendingModeRequest = null;
      }
    }
  }

  Future<String?> probeMode({Duration? timeout}) async {
    try {
      final request = _channel.invokeMethod<String>('getMode');
      final mode = timeout == null
          ? await request
          : await request.timeout(timeout);
      final resolvedMode = mode?.trim();
      if (resolvedMode == null || resolvedMode.isEmpty) {
        return null;
      }
      _cacheMode(resolvedMode);
      return resolvedMode;
    } catch (e) {
      AppLogger.e("MihomoService: getMode error: $e");
      return null;
    }
  }

  Future<String> _getModeNative({Duration? timeout}) async {
    final mode = await probeMode(timeout: timeout);
    return mode ?? 'rule';
  }

  Future<bool> waitUntilReady({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (Platform.isIOS) {
        final running = await checkIsRunning(forceRefresh: true);
        if (running) {
          final mode = await probeMode(timeout: _iosStartupReadyProbeTimeout);
          if (mode != null && mode.isNotEmpty) {
            _cacheRunningState(true);
            return true;
          }
        }
      } else {
        final running = await checkIsRunning(forceRefresh: true);
        if (running) {
          final mode = await probeMode(timeout: _startupReadyProbeTimeout);
          if (mode != null && mode.isNotEmpty) {
            _cacheRunningState(true);
            return true;
          }
        }
      }
      await Future.delayed(_startupReadyPollInterval);
    }
    _cachedIsRunning = null;
    _cachedIsRunningAt = null;
    return false;
  }

  Future<String?> getSelectedProxy(String groupName) async {
    final cachedSelected = _cachedSelectedProxyByGroup[groupName];
    final cachedSelectedAt = _cachedSelectedProxyAtByGroup[groupName];
    if (cachedSelected != null && _isStatusCacheFresh(cachedSelectedAt)) {
      return cachedSelected;
    }
    final pending = _pendingSelectedProxyRequestsByGroup[groupName];
    if (pending != null) {
      return pending;
    }
    final future = _getSelectedProxyNative(groupName);
    _pendingSelectedProxyRequestsByGroup[groupName] = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingSelectedProxyRequestsByGroup[groupName], future)) {
        _pendingSelectedProxyRequestsByGroup.remove(groupName);
      }
    }
  }

  Future<String?> _getSelectedProxyNative(String groupName) async {
    try {
      if (Platform.isWindows) {
        final result = await _channel.invokeMethod('getSelectedProxySync', {
          'groupName': groupName,
        });
        if (result is String && result.isNotEmpty) {
          _cacheSelectedProxy(groupName, result);
          return result;
        }
      }

      final result = await _channel.invokeMethod('getSelectedProxy', {
        'groupName': groupName,
      });
      final resolved = result as String?;
      if (resolved != null && resolved.isNotEmpty) {
        _cacheSelectedProxy(groupName, resolved);
      }
      return resolved;
    } catch (e) {
      AppLogger.e("MihomoService: getSelectedProxy error: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>?> getSelectedProxyInfo(String groupName) async {
    try {
      if (Platform.isAndroid) {
        final dynamic result = await _channel.invokeMethod(
          'getSelectedProxyInfo',
          {'groupName': groupName},
        );
        if (result is Map) {
          final info = result.map(
            (key, value) => MapEntry(key.toString(), value),
          );
          final name = info['name']?.toString().trim() ?? '';
          if (name.isEmpty) {
            return null;
          }
          final type = info['type']?.toString().trim();
          final country = info['country']?.toString().trim();
          final udpRaw = info['udp'];
          final udp =
              udpRaw == true || udpRaw?.toString().toLowerCase() == 'true';
          _lastSelectedGlobalProxy = name;
          _cacheSelectedProxy(groupName, name);
          return {
            'name': name,
            'type': (type == null || type.isEmpty) ? 'Unknown' : type,
            'country': (country == null || country.isEmpty)
                ? 'Unknown'
                : country,
            'udp': udp,
          };
        }
        return null;
      }
      if (!Platform.isWindows) {
        return null;
      }
      final String? result = await _channel.invokeMethod(
        'getSelectedProxyInfoSync',
        {'groupName': groupName},
      );
      if (result == null || result.isEmpty) {
        return null;
      }
      final parts = result.split('|');
      if (parts.length < 4) {
        return null;
      }
      final name = parts[0].trim();
      if (name.isEmpty) {
        return null;
      }
      final type = parts[1].trim().isEmpty ? 'Unknown' : parts[1].trim();
      final country = parts[2].trim().isEmpty ? 'Unknown' : parts[2].trim();
      final udpRaw = parts[3].trim().toLowerCase();
      final udp = udpRaw == 'true' || udpRaw == '1';
      _lastSelectedGlobalProxy = name;
      _cacheSelectedProxy(groupName, name);
      return {'name': name, 'type': type, 'country': country, 'udp': udp};
    } catch (e) {
      AppLogger.e("MihomoService: getSelectedProxyInfo error: $e");
      return null;
    }
  }

  Future<Map<String, dynamic>> getProxies({bool forceRefresh = false}) async {
    // Return cached if available and not forced
    if (!forceRefresh && _isProxyCacheFresh) {
      return _cachedProxies!;
    }
    final pending = _pendingProxiesRequest;
    if (pending != null) {
      return pending;
    }
    final future = _getProxiesWithStartupGuard();
    _pendingProxiesRequest = future;
    try {
      return await future;
    } finally {
      if (identical(_pendingProxiesRequest, future)) {
        _pendingProxiesRequest = null;
      }
    }
  }

  Future<Map<String, dynamic>> _getProxiesWithStartupGuard() async {
    await _waitForSafeIosProxyQueryWindow();
    return _getProxiesNative();
  }

  Future<void> _waitForSafeIosProxyQueryWindow() async {
    if (!Platform.isIOS) {
      return;
    }
    final startedAt = _lastNativeStartAt;
    if (startedAt == null) {
      return;
    }
    final remaining = _iosProxyStartupCooldown - DateTime.now().difference(startedAt);
    if (remaining > Duration.zero) {
      await Future.delayed(remaining);
    }
  }

  Future<Map<String, dynamic>> _getProxiesNative() async {
    try {
      if (Platform.isWindows) {
        final String? listStr = await _channel.invokeMethod('getProxyListStr');
        if (listStr != null && listStr.isNotEmpty) {
          final parsed = await compute(_parseProxyListStr, listStr);
          _updateProxyCache(parsed);
          _syncLightweightCacheFromProxies(parsed);
          return parsed;
        }
      }

      final dynamic result = await _channel.invokeMethod('getProxies');
      if (result is String) {
        final parsed = await compute(_parseProxiesPayload, result);
        _updateProxyCache(parsed);
        _syncLightweightCacheFromProxies(parsed);
        return parsed;
      } else if (result is Map) {
        final parsed = _normalizeProxiesObject(result);
        _updateProxyCache(parsed);
        _syncLightweightCacheFromProxies(parsed);
        return parsed;
      }
      return {};
    } catch (e) {
      AppLogger.e("MihomoService: getProxies error: $e");
      return {};
    }
  }

  void _syncLightweightCacheFromProxies(Map<String, dynamic> proxies) {
    final globalRaw = proxies['GLOBAL'];
    if (globalRaw is! Map) {
      return;
    }
    final now = globalRaw['now']?.toString().trim() ?? '';
    if (now.isEmpty) {
      return;
    }
    _lastSelectedGlobalProxy = now;
    _cacheSelectedProxy('GLOBAL', now);
  }

  // Helper to parse the pipe-separated string format
  static Map<String, dynamic> _parseProxyListStr(String listStr) {
    final Map<String, dynamic> proxies = {};
    // Format: name-type-adds-country-udp|...
    final items = listStr.split('|');

    // Construct a fake "proxies" map and "GLOBAL" group
    final allNames = <String>[];

    for (final item in items) {
      if (item.isEmpty) continue;

      // Split by '-' but be careful about names containing '-'
      // We know the last 4 fields are fixed: type, server, country, udp
      // So we split and take from end.
      // Actually, simple split might fail if name has dashes.
      // Let's assume the user's format implies simple structure or we find last 4 dashes.

      // Safer approach: reverse string, find first 4 dashes.
      // item: "My-Proxy-Node-Shadowsocks-1.2.3.4-Unknown-true"

      final parts = item.split('-');
      if (parts.length < 5) continue;

      final udp = parts.last == 'true';
      final country = parts[parts.length - 2];
      final server = parts[parts.length - 3];
      final type = parts[parts.length - 4];

      // Name is everything before type
      final nameParts = parts.sublist(0, parts.length - 4);
      final name = nameParts.join('-');

      allNames.add(name);

      proxies[name] = {
        'name': name,
        'type': type,
        'server': server, // Using server as "adds" (address)
        'country': country,
        'udp': udp,
        // 'country': country // Not standard field in proxies map usually, but can add
        // Add extra fields expected by UI
        'history': [],
        'now': '',
      };
    }

    return {
      'proxies': proxies,
      'GLOBAL': {
        'all': allNames,
        'type': 'Selector',
        'now': allNames.isNotEmpty ? allNames.first : '',
      },
    };
  }

  static Map<String, dynamic> _parseProxiesPayload(String payload) {
    final raw = payload.trim();
    if (raw.isEmpty) return {};
    if (raw.startsWith('{') || raw.startsWith('[')) {
      final decoded = json.decode(raw);
      return _normalizeProxiesObject(decoded);
    }
    return _parseCommaSeparatedProxyList(raw);
  }

  static Map<String, dynamic> _normalizeProxiesObject(dynamic decoded) {
    if (decoded is Map) {
      return Map<String, dynamic>.from(decoded);
    }
    if (decoded is List) {
      return _parseProxyArray(decoded);
    }
    return {};
  }

  static Map<String, dynamic> _parseCommaSeparatedProxyList(String listStr) {
    final proxies = <String, dynamic>{};
    final allNames = <String>[];
    for (final raw in listStr.split(',')) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      proxies[name] = {'name': name, 'type': 'Unknown', 'history': []};
      final upper = name.toUpperCase();
      if (upper != 'DIRECT' &&
          upper != 'REJECT' &&
          upper != 'REJECT-DROP' &&
          upper != 'PASS' &&
          upper != 'COMPATIBLE' &&
          upper != 'GLOBAL') {
        allNames.add(name);
      }
    }
    return {
      'proxies': proxies,
      'GLOBAL': {
        'all': allNames,
        'type': 'Selector',
        'now': allNames.isNotEmpty ? allNames.first : '',
      },
    };
  }

  static Map<String, dynamic> _parseProxyArray(List<dynamic> list) {
    final proxies = <String, dynamic>{};
    String? selectorName;
    final allNames = <String>[];

    for (final item in list) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final name = (map['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final type = (map['type'] ?? '').toString();
      final countryRaw = (map['country'] ?? '').toString().trim();
      final normalized = <String, dynamic>{
        'name': name,
        'type': type,
        'server': (map['server'] ?? map['adds'] ?? '').toString(),
        'country': countryRaw.isNotEmpty
            ? countryRaw
            : _inferCountryFromName(name),
        'udp': map['udp'] == true,
        'history': map['history'] is List ? map['history'] : <dynamic>[],
      };
      proxies[name] = normalized;

      final isSelector = type.toLowerCase() == 'selector';
      if (isSelector && selectorName == null) {
        selectorName = name;
      }
      if (!isSelector) {
        final upper = name.toUpperCase();
        if (upper != 'REJECT' &&
            upper != 'REJECT-DROP' &&
            upper != 'PASS' &&
            upper != 'COMPATIBLE') {
          allNames.add(name);
        }
      }
    }

    final groupNow = allNames.isNotEmpty ? allNames.first : '';
    final globalGroup = {'all': allNames, 'type': 'Selector', 'now': groupNow};
    final result = <String, dynamic>{'proxies': proxies, 'GLOBAL': globalGroup};
    final selector = selectorName;
    if (selector != null && selector != 'GLOBAL') {
      result[selector] = globalGroup;
    }
    return result;
  }

  static String _inferCountryFromName(String name) {
    final n = name.toLowerCase();
    if (n.contains('hk') || n.contains('hong') || name.contains('香港')) {
      return 'HK';
    }
    if (n.contains('jp') || n.contains('japan') || name.contains('日本')) {
      return 'JP';
    }
    if (n.contains('sg') || n.contains('singapore') || name.contains('新加坡')) {
      return 'SG';
    }
    if (n.contains('tw') || n.contains('taiwan') || name.contains('台湾')) {
      return 'TW';
    }
    if (n.contains('kr') || n.contains('korea') || name.contains('韩国')) {
      return 'KR';
    }
    if (n.contains('us') ||
        n.contains('usa') ||
        n.contains('america') ||
        name.contains('美国')) {
      return 'US';
    }
    if (n.contains('gb') ||
        n.contains('uk') ||
        n.contains('britain') ||
        name.contains('英国')) {
      return 'GB';
    }
    if (n.contains('de') || n.contains('germany') || name.contains('德国')) {
      return 'DE';
    }
    if (n.contains('fr') || n.contains('france') || name.contains('法国')) {
      return 'FR';
    }
    if (n.contains('nl') || n.contains('netherlands') || name.contains('荷兰')) {
      return 'NL';
    }
    if (n.contains('ca') || n.contains('canada') || name.contains('加拿大')) {
      return 'CA';
    }
    if (n.contains('au') || n.contains('australia') || name.contains('澳大利亚')) {
      return 'AU';
    }
    if (n.contains('in') || n.contains('india') || name.contains('印度')) {
      return 'IN';
    }
    if (n.contains('ru') || n.contains('russia') || name.contains('俄罗斯')) {
      return 'RU';
    }
    if (n.contains('cn') || n.contains('china') || name.contains('中国')) {
      return 'CN';
    }
    return '--';
  }

  void ensureTrafficMonitor() {
    // No-op: traffic stream is initialized on access
  }

  void _startDaemonCheck() {
    _daemonTimer?.cancel();
    _isDaemonCheckActive = true;
    _restartCount = 0;
    _daemonConsecutiveFailures = 0;
    AppPollingTaskRegistry.instance.registerTask(
      id: 'daemon_watchdog',
      interval: _daemonCheckInterval,
      initialDelay: _initialDaemonCheckDelay,
      owner: 'mihomo_service',
      active: true,
    );
    _scheduleNextDaemonCheck(initial: true);
  }

  void _scheduleNextDaemonCheck({required bool initial}) {
    _daemonTimer?.cancel();
    if (!_isDaemonCheckActive) {
      AppPollingTaskRegistry.instance.setTaskActive('daemon_watchdog', false);
      return;
    }
    AppPollingTaskRegistry.instance.registerTask(
      id: 'daemon_watchdog',
      interval: _daemonCheckInterval,
      initialDelay: _initialDaemonCheckDelay,
      owner: 'mihomo_service',
      active: true,
    );
    final delay = initial
        ? (Platform.isIOS ? _iosDaemonCheckInitialDelay : _initialDaemonCheckDelay)
        : _daemonCheckInterval;
    _daemonTimer = Timer(delay, () async {
      await _runDaemonCheckTick();
      if (_isDaemonCheckActive) {
        _scheduleNextDaemonCheck(initial: false);
      }
    });
  }

  Future<void> _runDaemonCheckTick() async {
    if (!_isDaemonCheckActive || _isDaemonCheckInFlight) {
      return;
    }
    _isDaemonCheckInFlight = true;
    try {
      AppPollingTaskRegistry.instance.markTaskExecuted('daemon_watchdog');
      if (Platform.isWindows) {
        _deferNonCriticalStatusQueries(_windowsStatusQueryCooldown);
      }
      final running = await checkIsRunning();
      if (!running) {
        _daemonConsecutiveFailures++;
        AppLogger.w(
          "MihomoService: Daemon check failed ($_daemonConsecutiveFailures/3).",
        );

        if (_daemonConsecutiveFailures >= 3) {
          _cacheRunningState(false);
          _restartCount++;
          AppLogger.e(
            "MihomoService: Daemon check failed 3 times. Marking as not running. Restart count: $_restartCount",
          );

          if (_restartCount <= 3) {
            AppLogger.i("MihomoService: Attempting auto-restart...");
            if (_lastSubscribeUrl != null) {
              try {
                final directory = await _getWorkingDir();
                final file = File('${directory.path}/config.yaml');
                if (await file.exists()) {
                  final configContent = await file.readAsString();
                  await _startNative(
                    file.path,
                    configContent,
                    restartDaemonCheck: false,
                  );
                  _daemonConsecutiveFailures = 0;
                } else {
                  AppLogger.e(
                    "MihomoService: Config file not found for restart.",
                  );
                }
              } catch (e) {
                AppLogger.e("MihomoService: Restart error $e");
              }
            }
          } else {
            AppLogger.e("MihomoService: Restart failed 3 times. Exiting app.");
            _isDaemonCheckActive = false;
            _cacheRunningState(false);
          }
        } else {
          _cacheRunningState(false);
        }
      } else {
        _cacheRunningState(true);
        _restartCount = 0;
        _daemonConsecutiveFailures = 0;
      }
    } finally {
      _isDaemonCheckInFlight = false;
    }
  }
}
