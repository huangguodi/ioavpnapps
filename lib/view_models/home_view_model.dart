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

class HomeAd {
  final int? id;
  final String title;
  final String imageUrl;
  final String content;
  final String linkUrl;

  const HomeAd({
    this.id,
    required this.title,
    required this.imageUrl,
    required this.content,
    required this.linkUrl,
  });
}

class HomeViewModel extends ChangeNotifier {
  static const Duration _userInfoPollInterval = Duration(seconds: 5);
  static const Duration _initialUserInfoPollDelay = Duration(seconds: 2);
  static const Duration _initialNodeInfoRefreshDelay = Duration(
    milliseconds: 250,
  );

  // State
  ConnectionMode _connectionMode;
  bool _isSwitching = false;
  String _uploadSpeed = "0 B/s";
  String _downloadSpeed = "0 B/s";
  int _quotaBytes = 0;
  List<HomeAd> _ads = const [];
  bool _isDeviceBound = false;

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
  bool _isDisposed = false;
  DateTime? _lastSwitchTime;
  DateTime _lastNodeInfoRefreshAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isRefreshingNodeInfo = false;
  final List<ExpiredTrafficLogNotice> _pendingExpiredTrafficLogNotices = [];
  static const Set<String> _excludedProxyNames = {
    'DIRECT',
    'REJECT',
    'GLOBAL',
    'REJECT-DROP',
    'COMPATIBLE',
    'PASS',
    'SMVPN',
    '自动选择',
    '故障转移',
    '负载均衡',
  };

  // Getters
  ConnectionMode get connectionMode => _connectionMode;
  bool get isSwitching => _isSwitching;
  String get uploadSpeed => _uploadSpeed;
  String get downloadSpeed => _downloadSpeed;
  int get quotaBytes => _quotaBytes;
  bool get isDeviceBound => _isDeviceBound;
  String get globalNodeName => _globalNodeName;
  String get globalNodeType => _globalNodeType;
  String get globalNodeCountry => _globalNodeCountry;
  bool get globalNodeUdp => _globalNodeUdp;
  List<HomeAd> get ads => List<HomeAd>.unmodifiable(_ads);
  String get adsSignature => _adsSignature(_ads);
  HomeAd? get primaryAd => _ads.isEmpty ? null : _ads.first;
  int get pendingExpiredTrafficLogNoticeCount =>
      _pendingExpiredTrafficLogNotices.length;
  List<ExpiredTrafficLogNotice> get pendingExpiredTrafficLogNotices =>
      List<ExpiredTrafficLogNotice>.unmodifiable(
        _pendingExpiredTrafficLogNotices,
      );

  // Init
  void init() {
    // Initialize state
    unawaited(_initServiceState());
    _startPolling();

    _trafficSubscription = MihomoService().trafficStream.listen((data) {
      final up = data['up'];
      final down = data['down'];
      final nextUploadSpeed = formatSpeed(up);
      final nextDownloadSpeed = formatSpeed(down);
      if (nextUploadSpeed == _uploadSpeed &&
          nextDownloadSpeed == _downloadSpeed) {
        return;
      }
      _uploadSpeed = nextUploadSpeed;
      _downloadSpeed = nextDownloadSpeed;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
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
    var shouldRefreshInitialNodeInfo = false;
    final initialQuota = _toNonNegativeInt(ApiService().userInfo?['quota']);
    final initialAds = _extractAds(ApiService().userInfo?['ads']);
    final initialIsDeviceBound = _toBool(
      ApiService().userInfo?['is_device_bound'],
    );
    final quotaChanged = _quotaBytes != initialQuota;
    final adsChanged = _adsSignature(_ads) != _adsSignature(initialAds);
    final deviceBoundChanged = _isDeviceBound != initialIsDeviceBound;
    _quotaBytes = initialQuota;
    _ads = initialAds;
    _isDeviceBound = initialIsDeviceBound;
    try {
      final isRunning = await MihomoService().checkIsRunning();
      if (isRunning) {
        shouldRefreshInitialNodeInfo = true;
        final mode = await MihomoService().getMode();
        resolvedMode = _modeFromNative(mode);
        MihomoService().ensureTrafficMonitor();
      }
    } catch (_) {
      resolvedMode = _connectionMode;
    }

    if (resolvedMode != _connectionMode ||
        quotaChanged ||
        adsChanged ||
        deviceBoundChanged) {
      _connectionMode = resolvedMode;
      notifyListeners();
    }
    if (shouldRefreshInitialNodeInfo) {
      _scheduleInitialNodeInfoRefresh();
    }
  }

  void _scheduleInitialNodeInfoRefresh() {
    unawaited(
      Future<void>.delayed(_initialNodeInfoRefreshDelay, () async {
        if (_isDisposed) {
          return;
        }
        await _refreshGlobalNodeInfo();
      }),
    );
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
    if (_lastSwitchTime != null &&
        now.difference(_lastSwitchTime!) < const Duration(milliseconds: 500)) {
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
          final startError = await MihomoService().start(
            subscribeUrl: url.toString(),
          );
          if (startError != null) {
            _connectionMode = previousMode;
            _isSwitching = false;
            notifyListeners();
            return false;
          }
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
    AppPollingTaskRegistry.instance.registerTask(
      id: 'user_info_polling',
      interval: _userInfoPollInterval,
      initialDelay: _initialUserInfoPollDelay,
      owner: 'home_view_model',
      active: true,
    );
    _scheduleNextUserInfoPolling(initial: true);
  }

  void _stopPolling() {
    _isPolling = false;
    AppPollingTaskRegistry.instance.setTaskActive('user_info_polling', false);
    _userInfoTimer?.cancel();
    _userInfoTimer = null;
  }

  void _scheduleNextUserInfoPolling({required bool initial}) {
    _userInfoTimer?.cancel();
    if (!_isPolling) {
      return;
    }
    AppPollingTaskRegistry.instance.registerTask(
      id: 'user_info_polling',
      interval: _userInfoPollInterval,
      initialDelay: _initialUserInfoPollDelay,
      owner: 'home_view_model',
      active: true,
    );
    final delay = initial ? _initialUserInfoPollDelay : _userInfoPollInterval;
    _userInfoTimer = Timer(delay, () async {
      await _tickUserInfoPolling();
      if (_isPolling) {
        _scheduleNextUserInfoPolling(initial: false);
      }
    });
  }

  Future<void> _tickUserInfoPolling() async {
    if (!_isPolling || _isFetchingUserInfo) return;
    _isFetchingUserInfo = true;
    try {
      AppPollingTaskRegistry.instance.markTaskExecuted('user_info_polling');
      await _fetchUserInfo().timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
    } finally {
      _isFetchingUserInfo = false;
    }
  }

  Future<bool> refreshUserInfo() async {
    if (_isFetchingUserInfo) return false;
    _isFetchingUserInfo = true;
    try {
      return await _fetchUserInfo().timeout(
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
      final previousQuota = _quotaBytes;
      final previousAdsSignature = _adsSignature(_ads);
      final previousIsDeviceBound = _isDeviceBound;
      final newQuota = newUserInfo?['quota'];
      final parsedQuota = _toNonNegativeInt(newQuota);
      _quotaBytes = parsedQuota;
      _ads = _extractAds(newUserInfo?['ads']);
      _isDeviceBound = _toBool(newUserInfo?['is_device_bound']);
      var hasNewExpiredTrafficNotice = false;
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
          hasNewExpiredTrafficNotice = true;
        }
      }

      if (previousQuota != _quotaBytes ||
          previousAdsSignature != _adsSignature(_ads) ||
          previousIsDeviceBound != _isDeviceBound ||
          hasNewExpiredTrafficNotice) {
        notifyListeners();
      }
      final shouldRefreshGlobalNodeInfo =
          _connectionMode == ConnectionMode.global || _globalNodeName == '--';
      if (shouldRefreshGlobalNodeInfo) {
        await _refreshGlobalNodeInfo();
      }
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

  bool _toBool(dynamic value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final normalized = value?.toString().trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }

  List<HomeAd> _extractAds(dynamic value) {
    if (value is! List || value.isEmpty) return const [];
    final ads = <HomeAd>[];
    for (final item in value) {
      if (item is! Map) continue;
      final imageUrl = item['image_url']?.toString() ?? '';
      if (imageUrl.isEmpty) continue;
      final idRaw = item['id'];
      ads.add(
        HomeAd(
          id: idRaw is int ? idRaw : int.tryParse(idRaw?.toString() ?? ''),
          title: item['title']?.toString() ?? '',
          imageUrl: imageUrl,
          content: item['content']?.toString() ?? '',
          linkUrl: item['link_url']?.toString() ?? '',
        ),
      );
    }
    return ads;
  }

  String _adsSignature(List<HomeAd> ads) {
    if (ads.isEmpty) return '';
    return ads
        .map((ad) => '${ad.id ?? ''}|${ad.imageUrl}|${ad.title}|${ad.linkUrl}')
        .join('||');
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
    if (_isDisposed) return;
    if (_isRefreshingNodeInfo) return;
    _isRefreshingNodeInfo = true;
    try {
      if (!force) {
        await MihomoService().waitForNonCriticalStatusQueryWindow();
        if (_isDisposed) {
          return;
        }
      }
      final now = DateTime.now();
      if (!force &&
          now.difference(_lastNodeInfoRefreshAt) < const Duration(seconds: 2)) {
        return;
      }
      if (force) {
        // Full refresh
        final proxies = await MihomoService().getProxies(forceRefresh: true);
        final info = _extractGlobalNodeInfo(proxies);
        final changed = _applyGlobalNodeInfo(info);
        if (changed) {
          notifyListeners();
        }
      } else {
        // Lightweight refresh: check if selected node changed
        final selectedName = await MihomoService().getSelectedProxy("GLOBAL");
        if (selectedName != null &&
            selectedName.isNotEmpty &&
            selectedName != _globalNodeName) {
          final lightweightInfo = await MihomoService().getSelectedProxyInfo(
            "GLOBAL",
          );
          if (lightweightInfo != null &&
              lightweightInfo['name']?.toString() == selectedName) {
            final changed = _applyGlobalNodeInfo(lightweightInfo);
            if (changed) {
              notifyListeners();
            }
          } else {
            // Node changed, fetch details
            // Use forceRefresh=true because we know the state changed
            final proxies = await MihomoService().getProxies(
              forceRefresh: true,
            );
            final info = _extractGlobalNodeInfo(proxies);
            final changed = _applyGlobalNodeInfo(info);
            if (changed) {
              notifyListeners();
            }
          }
        }
      }
      _lastNodeInfoRefreshAt = now;
    } catch (_) {
    } finally {
      _isRefreshingNodeInfo = false;
    }
  }

  bool _applyGlobalNodeInfo(Map<String, dynamic> info) {
    final nextName = info['name'] as String;
    final nextType = info['type'] as String;
    final nextCountry = info['country'] as String;
    final nextUdp = info['udp'] as bool;
    final changed =
        _globalNodeName != nextName ||
        _globalNodeType != nextType ||
        _globalNodeCountry != nextCountry ||
        _globalNodeUdp != nextUdp;
    _globalNodeName = nextName;
    _globalNodeType = nextType;
    _globalNodeCountry = nextCountry;
    _globalNodeUdp = nextUdp;
    return changed;
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

    return {'name': selectedName, 'type': type, 'country': country, 'udp': udp};
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

  List<Map<String, dynamic>> getNodeListFromProxies(
    Map<String, dynamic> proxies,
  ) {
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
    if (cached != null &&
        cached.isNotEmpty &&
        proxyMapRaw.containsKey(cached)) {
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

    final names =
        proxyMap.keys
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
      final rawDelay = await MihomoService()
          .urlTestProxy(nodeName)
          .timeout(const Duration(milliseconds: 3000), onTimeout: () => -1);
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

  Future<bool> selectGlobalNode(
    String nodeName, {
    String? nodeType,
    String? nodeCountry,
    bool? nodeUdp,
  }) async {
    final switched = await MihomoService().selectProxy(nodeName);
    if (!switched) {
      return false;
    }
    await MihomoService()
        .urlTestProxy(nodeName)
        .timeout(const Duration(seconds: 4), onTimeout: () => -1);
    await MihomoService()
        .urlTestProxy('GLOBAL')
        .timeout(const Duration(seconds: 4), onTimeout: () => -1);
    final canApplyImmediateNodeInfo =
        nodeType != null && nodeCountry != null && nodeUdp != null;
    if (canApplyImmediateNodeInfo) {
      final changed = _applyGlobalNodeInfo({
        'name': nodeName,
        'type': nodeType,
        'country': nodeCountry,
        'udp': nodeUdp,
      });
      _lastNodeInfoRefreshAt = DateTime.now();
      if (changed) {
        notifyListeners();
      }
    } else {
      _refreshGlobalNodeInfo(force: true);
    }
    return true;
  }

  Future<void> _selectDefaultNodeForGlobalMode() async {
    try {
      final proxies = await MihomoService().getProxies(forceRefresh: true);
      final selected = await MihomoService().getSelectedProxy("GLOBAL");
      if (selected != null &&
          selected.isNotEmpty &&
          !_excludedProxyNames.contains(selected)) {
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
    } catch (_) {}
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
