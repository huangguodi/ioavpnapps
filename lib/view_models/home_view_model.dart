import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:app/core/constants.dart';
import 'package:app/core/utils.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/mihomo_service.dart';

class ExpiredTrafficLogNotice {
  final String label;
  final int trafficBytes;
  final String createDate;

  const ExpiredTrafficLogNotice({
    required this.label,
    required this.trafficBytes,
    required this.createDate,
  });
}

class HomeViewModel extends ChangeNotifier {
  // State
  ConnectionMode _connectionMode;
  bool _isSwitching = false;
  String _uploadSpeed = "0 B/s";
  String _downloadSpeed = "0 B/s";
  int _quotaBytes = 0;
  
  HomeViewModel({ConnectionMode initialMode = ConnectionMode.off}) 
      : _connectionMode = initialMode;
  
  // Node Info
  String _globalNodeName = '--';
  String _globalNodeType = '--';
  String _globalNodeCountry = '--';
  bool _globalNodeUdp = false;
  
  // Private
  bool _isPolling = false;
  StreamSubscription? _trafficSubscription;
  Timer? _userInfoTimer;
  bool _isFetchingUserInfo = false;
  DateTime? _lastSwitchTime;
  DateTime _lastNodeInfoRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isRefreshingNodeInfo = false;
  final List<ExpiredTrafficLogNotice> _pendingExpiredTrafficLogNotices = [];
  static const Set<String> _excludedProxyNames = {
    'DIRECT', 'REJECT', 'GLOBAL', 'REJECT-DROP', 'COMPATIBLE', 'PASS',
    'SMVPN', '自动选择', '故障转移', '负载均衡'
  };

  // Getters
  ConnectionMode get connectionMode => _connectionMode;
  bool get isSwitching => _isSwitching;
  String get uploadSpeed => _uploadSpeed;
  String get downloadSpeed => _downloadSpeed;
  int get quotaBytes => _quotaBytes;
  String get globalNodeName => _globalNodeName;
  String get globalNodeType => _globalNodeType;
  String get globalNodeCountry => _globalNodeCountry;
  bool get globalNodeUdp => _globalNodeUdp;
  List<ExpiredTrafficLogNotice> get pendingExpiredTrafficLogNotices =>
      List<ExpiredTrafficLogNotice>.unmodifiable(_pendingExpiredTrafficLogNotices);

  // Init
  void init() {
    // Initialize state
    _initServiceState();
    _refreshGlobalNodeInfo();
    _startPolling();
    
    _trafficSubscription = MihomoService().trafficStream.listen((data) {
      final up = data['up'];
      final down = data['down'];
      _uploadSpeed = formatSpeed(up);
      _downloadSpeed = formatSpeed(down);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _stopPolling();
    _trafficSubscription?.cancel();
    super.dispose();
  }

  void onAppResumed() {
    _startPolling();
  }

  void onAppPaused() {
    _stopPolling();
  }

  // Service State Init
  Future<void> _initServiceState() async {
    ConnectionMode resolvedMode = ConnectionMode.off;
    final initialQuota = _toNonNegativeInt(ApiService().userInfo?['quota']);
    final quotaChanged = _quotaBytes != initialQuota;
    _quotaBytes = initialQuota;
    try {
      final isRunning = await MihomoService().checkIsRunning();
      if (isRunning) {
        final mode = await MihomoService().getMode();
        resolvedMode = _modeFromNative(mode);
        MihomoService().ensureTrafficMonitor();
      }
    } catch (_) {
      resolvedMode = _connectionMode;
    }

    if (resolvedMode != _connectionMode || quotaChanged) {
      _connectionMode = resolvedMode;
      notifyListeners();
    }
  }

  ConnectionMode _modeFromNative(String mode) {
    if (mode == 'direct') return ConnectionMode.off;
    if (mode == 'global') return ConnectionMode.global;
    return ConnectionMode.smart;
  }

  // Mode Switching
  Future<bool> setMode(ConnectionMode mode) async {
    if (_isSwitching) return false;
    if (_connectionMode == mode) return true;

    final now = DateTime.now();
    if (_lastSwitchTime != null && now.difference(_lastSwitchTime!) < const Duration(milliseconds: 500)) {
      return false;
    }
    _lastSwitchTime = now;

    if (MihomoService().isRunning && _connectionMode == mode) {
      return true;
    }

    String targetMode;
    switch (mode) {
      case ConnectionMode.off:
        targetMode = 'direct';
        break;
      case ConnectionMode.smart:
        targetMode = 'rule';
        break;
      case ConnectionMode.global:
        targetMode = 'global';
        break;
    }

    final previousMode = _connectionMode;
    _connectionMode = mode;
    _isSwitching = true;
    notifyListeners();

    try {
      if (!MihomoService().isRunning) {
         final userInfo = ApiService().userInfo;
         final url = userInfo?['subscribe_url'];
         if (url != null) {
            await MihomoService().start(subscribeUrl: url);
         } else {
            _connectionMode = previousMode;
            _isSwitching = false;
            notifyListeners();
            return false; // Subscription not found
         }
      }

      await Future.delayed(const Duration(milliseconds: 50));
      
      final success = await MihomoService().switchMode(targetMode);
      if (success) {
        final actualMode = await MihomoService().getMode();
        final resolvedActual = _modeFromNative(actualMode);
        if (resolvedActual != mode) {
           _connectionMode = resolvedActual;
        }
        if (resolvedActual == ConnectionMode.global) {
          await _selectDefaultNodeForGlobalMode();
        }
        _refreshGlobalNodeInfo(force: true);
      } else {
        _connectionMode = previousMode;
      }
      return success;
    } catch (e) {
      _connectionMode = previousMode;
      return false;
    } finally {
      _isSwitching = false;
      notifyListeners();
    }
  }

  // Polling
  void _startPolling() {
    if (_isPolling) return;
    _isPolling = true;
    _userInfoTimer?.cancel();
    _tickUserInfoPolling();
    _userInfoTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _tickUserInfoPolling();
    });
  }

  void _stopPolling() {
    _isPolling = false;
    _userInfoTimer?.cancel();
    _userInfoTimer = null;
  }

  Future<void> _tickUserInfoPolling() async {
    if (!_isPolling || _isFetchingUserInfo) return;
    _isFetchingUserInfo = true;
    try {
      await _fetchUserInfo().timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
    } finally {
      _isFetchingUserInfo = false;
    }
  }

  Future<bool> _fetchUserInfo() async {
    final error = await ApiService().fetchUserInfo();
    if (error == null) {
      final newUserInfo = ApiService().userInfo;
      final newQuota = newUserInfo?['quota'];
      final parsedQuota = _toNonNegativeInt(newQuota);
      _quotaBytes = parsedQuota;
      final expiredTrafficLogsRaw = newUserInfo?['expired_traffic_logs'];
      if (expiredTrafficLogsRaw is List && expiredTrafficLogsRaw.isNotEmpty) {
        for (final item in expiredTrafficLogsRaw) {
          if (item is! Map) continue;
          final label = item['label']?.toString() ?? '--';
          final trafficBytes = _toNonNegativeInt(item['traffic']);
          final createDate = _extractDate(item['create_time']?.toString());
          _pendingExpiredTrafficLogNotices.add(
            ExpiredTrafficLogNotice(
              label: label,
              trafficBytes: trafficBytes,
              createDate: createDate,
            ),
          );
        }
      }

      notifyListeners();
      await _refreshGlobalNodeInfo();
      return true;
    }
    return false;
  }

  int _toNonNegativeInt(dynamic value) {
    if (value is num) {
      final intValue = value.toInt();
      return intValue > 0 ? intValue : 0;
    }
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed <= 0) return 0;
    return parsed;
  }

  String _extractDate(String? value) {
    if (value == null || value.isEmpty) return '--';
    try {
      final time = DateTime.parse(value);
      final y = time.year.toString().padLeft(4, '0');
      final m = time.month.toString().padLeft(2, '0');
      final d = time.day.toString().padLeft(2, '0');
      return '$y-$m-$d';
    } catch (_) {
      final tIndex = value.indexOf('T');
      if (tIndex > 0) return value.substring(0, tIndex);
      return value;
    }
  }

  ExpiredTrafficLogNotice? consumeNextExpiredTrafficLogNotice() {
    if (_pendingExpiredTrafficLogNotices.isEmpty) return null;
    final notice = _pendingExpiredTrafficLogNotices.removeAt(0);
    notifyListeners();
    return notice;
  }

  // Node Info
  Future<void> _refreshGlobalNodeInfo({bool force = false}) async {
    if (_isRefreshingNodeInfo) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastNodeInfoRefreshAt) < const Duration(seconds: 2)) {
      return;
    }
    _isRefreshingNodeInfo = true;
    try {
      if (force) {
        // Full refresh
        final proxies = await MihomoService().getProxies(forceRefresh: true);
        final info = _extractGlobalNodeInfo(proxies);
        _globalNodeName = info['name'] as String;
        _globalNodeType = info['type'] as String;
        _globalNodeCountry = info['country'] as String;
        _globalNodeUdp = info['udp'] as bool;
        notifyListeners();
      } else {
        // Lightweight refresh: check if selected node changed
        final selectedName = await MihomoService().getSelectedProxy("GLOBAL");
        if (selectedName != null && selectedName.isNotEmpty && selectedName != _globalNodeName) {
           // Node changed, fetch details
           // Use forceRefresh=true because we know the state changed
           final proxies = await MihomoService().getProxies(forceRefresh: true);
           final info = _extractGlobalNodeInfo(proxies);
           _globalNodeName = info['name'] as String;
           _globalNodeType = info['type'] as String;
           _globalNodeCountry = info['country'] as String;
           _globalNodeUdp = info['udp'] as bool;
           notifyListeners();
        }
      }
      _lastNodeInfoRefreshAt = now;
    } catch (_) {
    } finally {
      _isRefreshingNodeInfo = false;
    }
  }

  Map<String, dynamic> _extractGlobalNodeInfo(Map<String, dynamic> proxies) {
    final dynamic proxyMapRaw = proxies['proxies'];
    if (proxyMapRaw is! Map) {
      return {'name': '--', 'type': '--', 'country': '--', 'udp': false};
    }

    final proxyMap = <String, dynamic>{};
    for (final entry in proxyMapRaw.entries) {
      proxyMap[entry.key.toString()] = entry.value;
    }

    String selectedName = '';
    final globalRaw = proxyMap['GLOBAL'];
    if (globalRaw is Map) {
      final now = globalRaw['now'];
      if (now is String && now.trim().isNotEmpty) {
        selectedName = now.trim();
      }
      if (selectedName.isEmpty) {
        final all = globalRaw['all'];
        if (all is List) {
          for (final item in all) {
            final value = item.toString().trim();
            if (value.isNotEmpty && !_excludedProxyNames.contains(value)) {
              selectedName = value;
              break;
            }
          }
        }
      }
    }
    if (selectedName.isEmpty) {
      final cached = MihomoService().lastSelectedGlobalProxy;
      if (cached != null && cached.isNotEmpty && proxyMap.containsKey(cached)) {
        selectedName = cached;
      }
    }

    if (selectedName.isEmpty) {
      for (final key in proxyMap.keys) {
        if (!_excludedProxyNames.contains(key)) {
          selectedName = key;
          break;
        }
      }
    }

    if (selectedName.isEmpty) {
      return {'name': '--', 'type': '--', 'country': '--', 'udp': false};
    }

    final dynamic nodeRaw = proxyMap[selectedName];
    final Map<String, dynamic> node = nodeRaw is Map
        ? nodeRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final type = _stringOf(node['type'], '--');
    final country = _stringOf(node['country'], '--');
    final udpRaw = node['udp'];
    final udp = udpRaw == true || udpRaw.toString().toLowerCase() == 'true';

    return {
      'name': selectedName,
      'type': type,
      'country': country,
      'udp': udp,
    };
  }

  String _stringOf(dynamic value, String fallback) {
    if (value == null) return fallback;
    final text = value.toString().trim();
    return text.isEmpty ? fallback : text;
  }

  Future<List<Map<String, dynamic>>> getNodeList() async {
    // When opening node selector, use cached proxies first for instant UI
    // then background refresh if needed. But usually cache is fresh enough if we poll.
    // If cache is null, force fetch.
    final cached = MihomoService().cachedProxies;
    if (cached != null) {
       return _extractNodeList(cached);
    }
    final proxies = await MihomoService().getProxies(forceRefresh: true);
    return _extractNodeList(proxies);
  }
  
  String getCurrentGlobalNodeName(Map<String, dynamic>? proxies) {
    // If proxies is null, we can't reliably determine without fetching, 
    // but usually this is called with recently fetched proxies.
    // Or we can return _globalNodeName if proxies is null.
    if (proxies == null) return _globalNodeName;
    
    final dynamic proxyMapRaw = proxies['proxies'];
    if (proxyMapRaw is! Map) return _globalNodeName;
    
    final cached = MihomoService().lastSelectedGlobalProxy;
    if (cached != null && cached.isNotEmpty && proxyMapRaw.containsKey(cached)) {
      return cached;
    }
    final dynamic globalRaw = proxyMapRaw['GLOBAL'];
    if (globalRaw is Map) {
      final now = globalRaw['now'];
      if (now is String && now.trim().isNotEmpty) {
        return now.trim();
      }
    }
    return _globalNodeName;
  }

  List<Map<String, dynamic>> _extractNodeList(Map<String, dynamic> proxies) {
    final dynamic proxyMapRaw = proxies['proxies'];
    if (proxyMapRaw is! Map) return [];
    final proxyMap = <String, dynamic>{};
    for (final entry in proxyMapRaw.entries) {
      proxyMap[entry.key.toString()] = entry.value;
    }

    final names = proxyMap.keys
        .where((name) => !_excludedProxyNames.contains(name))
        .toList()
      ..sort();
    return names.map((name) {
      final raw = proxyMap[name];
      final Map<String, dynamic> node = raw is Map
          ? raw.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};
      final type = _stringOf(node['type'], '--');
      final country = _stringOf(node['country'], '--');
      final udpRaw = node['udp'];
      final udp = udpRaw == true || udpRaw.toString().toLowerCase() == 'true';
      final delay = _extractDelay(node);
      return {
        'name': name,
        'type': type,
        'country': country,
        'udp': udp,
        'delay': delay,
      };
    }).toList();
  }
  
  int? _extractDelay(Map<String, dynamic> node) {
    final directDelay = node['delay'];
    if (directDelay is num && directDelay > 0) {
      return _normalizeDelay(directDelay.toInt());
    }
    final history = node['history'];
    if (history is List) {
      for (final item in history.reversed) {
        if (item is Map) {
          final delay = item['delay'];
          if (delay is num && delay > 0) {
            return _normalizeDelay(delay.toInt());
          }
        }
      }
    }
    return null;
  }

  Future<int?> testNodeLatency(String nodeName) async {
    try {
      final rawDelay = await MihomoService().urlTestProxy(nodeName).timeout(
        const Duration(milliseconds: 3000),
        onTimeout: () => -1,
      );
      return _normalizeDelay(rawDelay);
    } catch (_) {
      return -1;
    }
  }

  int _normalizeDelay(int? delay) {
    if (delay == null) return -1;
    if (delay <= 0) return delay;
    return (delay / 10).round();
  }
  
  Future<bool> selectGlobalNode(String nodeName) async {
    final switched = await MihomoService().selectProxy(nodeName);
    if (!switched) {
      return false;
    }
    await MihomoService().urlTestProxy(nodeName).timeout(
      const Duration(seconds: 4),
      onTimeout: () => -1,
    );
    await MihomoService().urlTestProxy('GLOBAL').timeout(
      const Duration(seconds: 4),
      onTimeout: () => -1,
    );
    _refreshGlobalNodeInfo(force: true);
    return true;
  }

  Future<void> _selectDefaultNodeForGlobalMode() async {
    try {
      final proxies = await MihomoService().getProxies(forceRefresh: true);
      final selected = await MihomoService().getSelectedProxy("GLOBAL");
      if (selected != null &&
          selected.isNotEmpty &&
          !_excludedProxyNames.contains(selected)) {
        await MihomoService().urlTestProxy(selected).timeout(
          const Duration(seconds: 4),
          onTimeout: () => -1,
        );
        return;
      }

      final candidate = _pickGlobalDefaultNode(proxies);
      if (candidate == null || candidate.isEmpty) {
        return;
      }
      final switched = await MihomoService().selectProxy(candidate);
      if (!switched) {
        return;
      }
      await MihomoService().urlTestProxy(candidate).timeout(
        const Duration(seconds: 4),
        onTimeout: () => -1,
      );
      await MihomoService().urlTestProxy('GLOBAL').timeout(
        const Duration(seconds: 4),
        onTimeout: () => -1,
      );
    } catch (_) {
    }
  }

  String? _pickGlobalDefaultNode(Map<String, dynamic> proxies) {
    final dynamic proxyMapRaw = proxies['proxies'];
    if (proxyMapRaw is! Map) return null;

    final proxyMap = <String, dynamic>{};
    for (final entry in proxyMapRaw.entries) {
      proxyMap[entry.key.toString()] = entry.value;
    }

    final candidates = <String>[];
    final globalFromRoot = proxies['GLOBAL'];
    final globalFromMap = proxyMap['GLOBAL'];
    final globalRaw = globalFromRoot is Map ? globalFromRoot : globalFromMap;
    if (globalRaw is Map) {
      final all = globalRaw['all'];
      if (all is List) {
        for (final item in all) {
          final value = item.toString().trim();
          if (value.isEmpty || _excludedProxyNames.contains(value)) continue;
          if (proxyMap.containsKey(value)) {
            candidates.add(value);
          }
        }
      }
    }

    if (candidates.isEmpty) {
      for (final key in proxyMap.keys) {
        if (!_excludedProxyNames.contains(key)) {
          candidates.add(key);
        }
      }
    }
    return candidates.isEmpty ? null : candidates.first;
  }
}
