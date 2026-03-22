import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/core/logger.dart';
import 'package:app/services/api_service.dart'; // Import ApiService
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
// import 'package:http/http.dart' as http; // Removed direct http usage
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class MihomoService {
  static const MethodChannel _channel = MethodChannel('com.accelerator.tg/mihomo');
  static const bool _verboseNativeLogs = bool.fromEnvironment('MIHOMO_VERBOSE_NATIVE_LOGS', defaultValue: true);
  static final MihomoService _instance = MihomoService._internal();

  factory MihomoService() {
    return _instance;
  }

  MihomoService._internal();

  bool _isRunning = false;
  String? _lastSubscribeUrl;
  Timer? _daemonTimer;
  int _restartCount = 0;
  String? _lastSelectedGlobalProxy;
  
  // Cache proxies to avoid first-time lag
  Map<String, dynamic>? _cachedProxies;
  
  // ignore: unused_field
  int _suppressedNativeConnectionLogCount = 0;

  bool get isRunning => _isRunning;
  String? get lastSelectedGlobalProxy => _lastSelectedGlobalProxy;
  Map<String, dynamic>? get cachedProxies => _cachedProxies;

  Stream<dynamic>? _trafficStream;

  Stream<dynamic> get trafficStream {
    _trafficStream ??= const EventChannel('com.accelerator.tg/mihomo/traffic').receiveBroadcastStream();
    return _trafficStream!;
  }

  Future<void> init() async {
    _listenToNativeLogs();
    await _ensureMMDB();
    _startDaemonCheck();
  }

  /// Listen to native logs
  void _listenToNativeLogs() {
    if (!Platform.isAndroid) {
      return;
    }
    const EventChannel('com.accelerator.tg/mihomo/logs').receiveBroadcastStream().listen((event) {
      final message = (event ?? '').toString();
      if (!_verboseNativeLogs && _isNoisyConnectionLog(message)) {
        _suppressedNativeConnectionLogCount++;
        if (_suppressedNativeConnectionLogCount % 50 == 0) {
          AppLogger.d("NATIVE_LOG: suppressed=$_suppressedNativeConnectionLogCount");
        }
        return;
      }
      AppLogger.d("NATIVE_LOG: $message");
    }, onError: (error) {
      AppLogger.e("NATIVE_LOG_ERROR: $error");
    });
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

  Future<void> _ensureMMDB() async {
    try {
      final directory = await getApplicationSupportDirectory();
      if (!await directory.exists()) {
        await directory.create(recursive: true);
      }
      final mmdbFile = File('${directory.path}/Country.mmdb');
      if (!await mmdbFile.exists()) {
        // Copy from assets if needed, or download
        // Assuming asset 'assets/Country.mmdb' exists as per usual Clash setup
        try {
           final byteData = await rootBundle.load('assets/Country.mmdb');
           await mmdbFile.writeAsBytes(byteData.buffer.asUint8List());
           AppLogger.d("MihomoService: Country.mmdb copied to ${mmdbFile.path}");
        } catch (e) {
           AppLogger.e("MihomoService: Failed to copy Country.mmdb: $e");
        }
      }
    } catch (e) {
      AppLogger.e("MihomoService: _ensureMMDB error: $e");
    }
  }

  Future<String> _saveConfig(String content) async {
    final directory = await getApplicationSupportDirectory();
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File('${directory.path}/config.yaml');
    await file.writeAsString(content);
    return file.path;
  }
  
  Future<void> _updateConfigFileMode(String mode) async {
      try {
        final directory = await getApplicationSupportDirectory();
        final configFile = File('${directory.path}/config.yaml');
        if (await configFile.exists()) {
           String content = await configFile.readAsString();
           if (content.contains(RegExp(r'^mode:', multiLine: true))) {
             content = content.replaceAll(RegExp(r'^mode:.*$', multiLine: true), 'mode: $mode');
           } else {
             content = 'mode: $mode\n$content';
           }
           await configFile.writeAsString(content);
           AppLogger.d("MihomoService: Config file updated for persistence.");
        }
      } catch (e) {
        AppLogger.e("Error updating config file: $e");
      }
  }

  Future<String?> start({required String subscribeUrl}) async {
    try {
      final normalizedUrl = _normalizeSubscribeUrl(subscribeUrl);
      if (normalizedUrl == null) {
        return "Invalid subscribe url";
      }
      AppLogger.d("MihomoService: Starting with URL: $normalizedUrl");
      _lastSubscribeUrl = normalizedUrl;
      
      // Download config using ApiService.sharedClient to ensure consistent SSL policy
      final response = await ApiService.sharedClient.get(Uri.parse(normalizedUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return "Config download failed: ${response.statusCode}";
      }
      
      var configContent = utf8.decode(response.bodyBytes);
      final trimmed = configContent.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('<')) {
        return "Config payload is invalid";
      }
      if (!configContent.contains('proxies:') && !configContent.contains('proxy-groups:')) {
        return "Config format invalid";
      }

      final configPath = await _saveConfig(configContent);
      
      return await _startNative(configPath, configContent);
    } catch (e) {
      AppLogger.e("MihomoService: Start error: $e");
      return e.toString();
    }
  }

  Future<bool> requestVpnPermission() async {
    if (!Platform.isIOS) return true;
    try {
      final result = await _channel.invokeMethod('requestVpnPermission');
      return result == true;
    } on PlatformException catch (e) {
      AppLogger.e("MihomoService: requestVpnPermission error: ${e.message}");
      return false;
    } catch (e) {
      AppLogger.e("MihomoService: requestVpnPermission exception: $e");
      return false;
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

  Future<String?> _startNative(String configPath, String configContent) async {
    try {
      await _channel.invokeMethod('start', {
        'configPath': configPath,
        'configContent': configContent,
      });
      
      _isRunning = true;
      _restartCount = 0;
      await _restoreRoutingFromConfig(configContent);
      
      Future.delayed(const Duration(milliseconds: 500), () => getProxies(forceRefresh: true));
      
      return null;
    } on PlatformException catch (e) {
      _isRunning = false;
      return "Native Start Error: ${e.message}";
    } catch (e) {
      _isRunning = false;
      return "Start Exception: $e";
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
    final match = RegExp(r'^mode:\s*([A-Za-z]+)\s*$', multiLine: true).firstMatch(configContent);
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
        currentGroup = trimmed.substring(7).trim().replaceAll('"', '').replaceAll("'", '');
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

        final proxyName = itemTrimmed.substring(2).trim().replaceAll('"', '').replaceAll("'", '');
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
      await _channel.invokeMethod('stop');
      _isRunning = false;
      AppLogger.d("MihomoService: Stopped.");
    } catch (e) {
      AppLogger.e("MihomoService: Stop error: $e");
    }
  }
  
  Future<bool> checkIsRunning() async {
    try {
      final bool? result = await _channel.invokeMethod('isRunning');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  Future<int?> urlTestProxy(String proxyName) async {
    try {
      final dynamic result = await _channel.invokeMethod('urlTest', {'name': proxyName});
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
  
  Future<bool> switchMode(String mode) async {
     try {
       await _channel.invokeMethod('changeMode', {'mode': mode});
       await _updateConfigFileMode(mode);
       return true;
     } catch (e) {
       AppLogger.e("MihomoService: switchMode error: $e");
       return false;
     }
  }
  
  Future<bool> selectProxy(String proxyName) async {
     try {
       final dynamic ok = await _channel.invokeMethod('selectProxy', {'name': proxyName});
       final success = ok is bool ? ok : true;
       if (success) {
         _lastSelectedGlobalProxy = proxyName;
         _cachedProxies = null;
       }
       return success;
     } catch (e) {
       AppLogger.e("MihomoService: selectProxy error: $e");
       return false;
     }
  }
  
  Future<String> getMode() async {
    try {
      final String? mode = await _channel.invokeMethod('getMode');
      return mode ?? 'rule';
    } catch (e) {
      AppLogger.e("MihomoService: getMode error: $e");
      return 'rule';
    }
  }

  Future<String?> getSelectedProxy(String groupName) async {
     try {
       // Prefer synchronous native call on Windows for performance
       if (Platform.isWindows) {
         final result = await _channel.invokeMethod('getSelectedProxySync', {'groupName': groupName});
         if (result is String && result.isNotEmpty) {
           return result;
         }
         // Fallback if sync returns empty (e.g. not found or error)
       }
       
       final result = await _channel.invokeMethod('getSelectedProxy', {'groupName': groupName});
       return result as String?;
     } catch (e) {
       AppLogger.e("MihomoService: getSelectedProxy error: $e");
       return null;
     }
  }

  Future<Map<String, dynamic>> getProxies({bool forceRefresh = false}) async {
    // Return cached if available and not forced
    if (!forceRefresh && _cachedProxies != null) {
      return _cachedProxies!;
    }

    try {
      if (Platform.isWindows) {
        final String? listStr = await _channel.invokeMethod('getProxyListStr');
        if (listStr != null && listStr.isNotEmpty) {
           return await compute(_parseProxyListStr, listStr);
        }
      }

      final dynamic result = await _channel.invokeMethod('getProxies');
      if (result is String) {
         final parsed = await compute(_parseProxiesPayload, result);
         _cachedProxies = parsed;
         return parsed;
      } else if (result is Map) {
         final parsed = _normalizeProxiesObject(result);
         _cachedProxies = parsed;
         return parsed;
      }
      return {};
    } catch (e) {
      AppLogger.e("MihomoService: getProxies error: $e");
      return {};
    }
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
        }
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
      proxies[name] = {
        'name': name,
        'type': 'Unknown',
        'history': [],
      };
      final upper = name.toUpperCase();
      if (upper != 'DIRECT' && upper != 'REJECT' && upper != 'REJECT-DROP' && upper != 'PASS' && upper != 'COMPATIBLE' && upper != 'GLOBAL') {
        allNames.add(name);
      }
    }
    return {
      'proxies': proxies,
      'GLOBAL': {
        'all': allNames,
        'type': 'Selector',
        'now': allNames.isNotEmpty ? allNames.first : '',
      }
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
        'country': countryRaw.isNotEmpty ? countryRaw : _inferCountryFromName(name),
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
        if (upper != 'REJECT' && upper != 'REJECT-DROP' && upper != 'PASS' && upper != 'COMPATIBLE') {
          allNames.add(name);
        }
      }
    }

    final groupNow = allNames.isNotEmpty ? allNames.first : '';
    final globalGroup = {
      'all': allNames,
      'type': 'Selector',
      'now': groupNow,
    };
    final result = <String, dynamic>{
      'proxies': proxies,
      'GLOBAL': globalGroup,
    };
    final selector = selectorName;
    if (selector != null && selector != 'GLOBAL') {
      result[selector] = globalGroup;
    }
    return result;
  }

  static String _inferCountryFromName(String name) {
    final n = name.toLowerCase();
    if (n.contains('hk') || n.contains('hong') || name.contains('香港')) return 'HK';
    if (n.contains('jp') || n.contains('japan') || name.contains('日本')) return 'JP';
    if (n.contains('sg') || n.contains('singapore') || name.contains('新加坡')) return 'SG';
    if (n.contains('tw') || n.contains('taiwan') || name.contains('台湾')) return 'TW';
    if (n.contains('kr') || n.contains('korea') || name.contains('韩国')) return 'KR';
    if (n.contains('us') || n.contains('usa') || n.contains('america') || name.contains('美国')) return 'US';
    if (n.contains('gb') || n.contains('uk') || n.contains('britain') || name.contains('英国')) return 'GB';
    if (n.contains('de') || n.contains('germany') || name.contains('德国')) return 'DE';
    if (n.contains('fr') || n.contains('france') || name.contains('法国')) return 'FR';
    if (n.contains('nl') || n.contains('netherlands') || name.contains('荷兰')) return 'NL';
    if (n.contains('ca') || n.contains('canada') || name.contains('加拿大')) return 'CA';
    if (n.contains('au') || n.contains('australia') || name.contains('澳大利亚')) return 'AU';
    if (n.contains('in') || n.contains('india') || name.contains('印度')) return 'IN';
    if (n.contains('ru') || n.contains('russia') || name.contains('俄罗斯')) return 'RU';
    if (n.contains('cn') || n.contains('china') || name.contains('中国')) return 'CN';
    return '--';
  }


  void ensureTrafficMonitor() {
    // No-op: traffic stream is initialized on access
  }

  void _startDaemonCheck() {
    _daemonTimer?.cancel();
    _restartCount = 0;
    int consecutiveFailures = 0; // Track consecutive failures

    // Android foreground service is fairly robust, but sometimes killed.
    // Windows process might crash.
    // We check every 5 seconds.
    _daemonTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      final running = await checkIsRunning();
      if (!running) {
        consecutiveFailures++;
        AppLogger.w("MihomoService: Daemon check failed ($consecutiveFailures/3).");
        
        if (consecutiveFailures >= 3) {
          _isRunning = false;
          _restartCount++;
          AppLogger.e("MihomoService: Daemon check failed 3 times. Marking as not running. Restart count: $_restartCount");
          
          // Auto-restart logic
          if (_restartCount <= 3) {
             AppLogger.i("MihomoService: Attempting auto-restart...");
             if (_lastSubscribeUrl != null) {
                try {
                  // We use the cached config path
                  final directory = await getApplicationSupportDirectory();
                  final file = File('${directory.path}/config.yaml');
                  if (await file.exists()) {
                    final configContent = await file.readAsString();
                    await _startNative(file.path, configContent);
                    // Reset failure count after restart attempt to give it a chance
                    consecutiveFailures = 0; 
                  } else {
                     AppLogger.e("MihomoService: Config file not found for restart.");
                  } 
                } catch (e) {
                  AppLogger.e("MihomoService: Restart error $e");
                }
             }
          } else {
             AppLogger.e("MihomoService: Restart failed 3 times. Exiting app.");
             timer.cancel();
             _isRunning = false;
          }
        }
      } else {
        // Running successfully
        _isRunning = true;
        _restartCount = 0;
        consecutiveFailures = 0;
      }
    });
  }
}
