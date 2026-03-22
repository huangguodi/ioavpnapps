import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:android_id/android_id.dart';
import 'package:app/core/logger.dart';
import 'package:app/services/diagnostic_log_service.dart';
import 'package:app/core/certificates.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart'; // Import IOClient
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

// =============================================================================
// Top-level Crypto Workers (Run in Isolate)
// =============================================================================

// HONEYPOT: Fake crypto logic to mislead reverse engineers
class _CryptoParamsHoneypot {
  final String aesKey;
  final String obfuscateKey;
  final dynamic data;
  _CryptoParamsHoneypot(this.aesKey, this.obfuscateKey, this.data);
}

// ignore: unused_element
Uint8List _isolatedEncryptHoneypot(_CryptoParamsHoneypot params) {
  final str = json.encode(params.data);
  final bytes = utf8.encode(str);
  
  // Use fake keys
  final fakeAesKey = ApiService._aesKye;
  final fakeObfKey = ApiService._obfuscateKye;
  
  final kBytes = utf8.encode(fakeAesKey);
  final oBytes = utf8.encode(fakeObfKey);
  
  final out = Uint8List(bytes.length);
  for (int i = 0; i < bytes.length; i++) {
    out[i] = bytes[i] ^ kBytes[i % kBytes.length] ^ oBytes[i % oBytes.length];
  }
  return out;
}

// ignore: unused_element
Map<String, dynamic>? _isolatedDecryptHoneypot(_CryptoParamsHoneypot params) {
  final data = params.data as Uint8List;
  final fakeAesKey = ApiService._aesKye;
  final fakeObfKey = ApiService._obfuscateKye;
  
  final kBytes = utf8.encode(fakeAesKey);
  final oBytes = utf8.encode(fakeObfKey);
  
  final out = Uint8List(data.length);
  for (int i = 0; i < data.length; i++) {
    out[i] = data[i] ^ oBytes[i % oBytes.length] ^ kBytes[i % kBytes.length];
  }
  
  try {
    return json.decode(utf8.decode(out));
  } catch (_) {
    return {"status": "error", "msg": "honeypot decrypt failed"};
  }
}


class _CryptoParams {
  final String aesKey;
  final String obfuscateKey;
  final dynamic data; // Map<String, dynamic> for encrypt, Uint8List for decrypt

  _CryptoParams(this.aesKey, this.obfuscateKey, this.data);
}

Uint8List _isolatedEncrypt(_CryptoParams params) {
  try {
    final jsonStr = json.encode(params.data);
    final plainBytes = utf8.encode(jsonStr);

    // AES Key
    final keyBytes = _hexToBytes(params.aesKey);
    
    // Generate 12-byte Nonce (IV)
    final ivBytes = List<int>.generate(12, (i) => Random.secure().nextInt(256));
    final iv = Uint8List.fromList(ivBytes);

    // PointyCastle GCM Encryption
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final aeadParams = pc.AEADParameters(
      pc.KeyParameter(Uint8List.fromList(keyBytes)), 
      128, // Mac Bit Size (16 bytes)
      iv, 
      Uint8List(0) // Associated Data
    );
    
    cipher.init(true, aeadParams); // true = encrypt
    
    final out = Uint8List(cipher.getOutputSize(plainBytes.length));
    var len = cipher.processBytes(plainBytes, 0, plainBytes.length, out, 0);
    len += cipher.doFinal(out, len);
    
    final cipherBytesWithTag = out.sublist(0, len);
    
    final combined = Uint8List.fromList([
      ...iv, 
      ...cipherBytesWithTag, 
    ]);
    
    // Obfuscate
    return _obfuscate(combined, params.obfuscateKey);
  } catch (e) {
    throw Exception("Encryption Error: $e");
  }
}

Map<String, dynamic>? _isolatedDecrypt(_CryptoParams params) {
  try {
    final obfuscatedData = params.data as Uint8List;
    final encryptedData = _deobfuscate(obfuscatedData, params.obfuscateKey);
    
    // Minimum length: Nonce(12) + Tag(16) = 28 bytes
    if (encryptedData.length < 28) {
      return null;
    }

    // 1. Extract Nonce (first 12 bytes)
    final nonceBytes = encryptedData.sublist(0, 12);
    final iv = nonceBytes;
    
    // 2. Extract Ciphertext + Tag (remaining bytes)
    final ciphertextWithTagBytes = encryptedData.sublist(12);
    
    // PointyCastle Decryption
    final keyBytes = _hexToBytes(params.aesKey);
    final cipher = pc.GCMBlockCipher(pc.AESEngine());
    final aeadParams = pc.AEADParameters(
      pc.KeyParameter(Uint8List.fromList(keyBytes)), 
      128, 
      iv, 
      Uint8List(0)
    );
    
    cipher.init(false, aeadParams); // false = decrypt
    
    final out = Uint8List(cipher.getOutputSize(ciphertextWithTagBytes.length));
    var len = cipher.processBytes(ciphertextWithTagBytes, 0, ciphertextWithTagBytes.length, out, 0);
    len += cipher.doFinal(out, len);
    
    final decryptedBytes = out.sublist(0, len);
    final decryptedStr = utf8.decode(decryptedBytes);
    
    final decoded = json.decode(decryptedStr);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (e) {
    // In isolate, just return null or rethrow
    return null;
  }
}

// Helpers must be top-level for Isolate access
String _toHex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
}

List<int> _hexToBytes(String hex) {
  hex = hex.replaceAll(" ", ""); 
  
  // App V2 接口文档规定 AES 密钥必须是 32 字节 (64个十六进制字符)
  if (hex.length > 64) {
    hex = hex.substring(0, 64);
  } else if (hex.length < 64) {
    hex = hex.padRight(64, '0');
  }

  List<int> bytes = [];
  for (int i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return bytes;
}

Uint8List _obfuscate(Uint8List data, String key) {
  final keyBytes = utf8.encode(key); 
  final keyLen = keyBytes.length;
  final result = Uint8List.fromList(data);
  
  // 1. Rolling XOR
  for (int i = 0; i < result.length; i++) {
    result[i] = result[i] ^ keyBytes[i % keyLen];
  }
  
  // 2. Reverse
  return Uint8List.fromList(result.reversed.toList());
}

Uint8List _deobfuscate(Uint8List data, String key) {
  // 1. Reverse
  final reversed = Uint8List.fromList(data.reversed.toList());
  final keyBytes = utf8.encode(key);
  final keyLen = keyBytes.length;
  
  // 2. Rolling XOR
  for (int i = 0; i < reversed.length; i++) {
    reversed[i] = reversed[i] ^ keyBytes[i % keyLen];
  }
  return reversed;
}


// =============================================================================
// Data Models
// =============================================================================

class OrderCreateResult {
  final int code;
  final String msg;
  final String? orderNo;

  const OrderCreateResult({
    required this.code,
    required this.msg,
    this.orderNo,
  });

  bool get isSuccess => code == 200 && orderNo != null && orderNo!.isNotEmpty;
}

class PaymentMethod {
  final int id;
  final String name;

  const PaymentMethod({
    required this.id,
    required this.name,
  });
}

class PayListResult {
  final int code;
  final String msg;
  final List<PaymentMethod> methods;

  const PayListResult({
    required this.code,
    required this.msg,
    required this.methods,
  });

  bool get isSuccess => code == 200;
}

class OrderCheckoutResult {
  final int code;
  final String msg;
  final String? payUrl;
  final int needClientQrcode;

  const OrderCheckoutResult({
    required this.code,
    required this.msg,
    this.payUrl,
    this.needClientQrcode = 1,
  });

  bool get isSuccess => code == 200 && payUrl != null && payUrl!.isNotEmpty;
}

class OrderStatusResult {
  final int code;
  final String msg;
  final int? status;

  const OrderStatusResult({
    required this.code,
    required this.msg,
    this.status,
  });

  bool get isSuccess => code == 200 && status != null;
}

class GiftCardSubmitResult {
  final int code;
  final String msg;

  const GiftCardSubmitResult({
    required this.code,
    required this.msg,
  });

  bool get isSuccess => code == 200;
}

// =============================================================================
// ApiService
// =============================================================================

class ApiService {
  // Singleton pattern
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  // ===========================================================================
  // 1. 服务端地址配置 (XOR 混淆存储)
  // ===========================================================================
  // Dart 侧不再存储任何服务端的真实地址片段。
  // 所有的密钥和地址信息均由 Native 层 (JNI/C++) 动态注入。
  // 此处保留的 _serverUrlBytes 仅为 Native 密钥解密的占位符或二次混淆参数。
  static List<int> _serverUrlBytes = []; 
  
  // HONEYPOT: Fake URL and Keys with complex obfuscation lookalikes
  static const List<int> _serverUlrBytes = [104, 116, 116, 112, 115, 58, 47, 47, 97, 112, 105, 46, 116, 103, 115, 95, 118, 112, 110, 46, 99, 111, 109];
  
  static String get _aesKye {
    final parts = ['A1B2', 'C3D4', 'E5F6', '7890', '1234', '5678', '90AB', 'CDEF'];
    return parts.reversed.toList().reversed.join('');
  }
  
  static String get _obfuscateKye {
    final p1 = String.fromCharCodes([77, 49, 78, 50, 66, 51, 86, 52]); // M1N2B3V4
    final p2 = String.fromCharCodes([67, 53, 88, 54, 90, 55, 65, 56]); // C5X6Z7A8
    final p3 = String.fromCharCodes([83, 57, 68, 48, 70, 49, 71, 50]); // S9D0F1G2
    final p4 = String.fromCharCodes([72, 51, 74, 52, 75, 53, 76, 54]); // H3J4K5L6
    return "$p1$p2$p3$p4";
  }
  
  // Dynamic keys loaded from Native
  String _dynamicServerUrlKey = "";
  String _dynamicAesKey = "";
  String _dynamicObfuscateKey = "";
  bool _keysLoaded = false;
  
  static const MethodChannel _securityChannel = MethodChannel('com.accelerator.tg/security');
  static const MethodChannel _mihomoChannel = MethodChannel('com.accelerator.tg/mihomo');

  Future<void> initNativeKeys() async {
    if (_keysLoaded) return;
    
    try {
      // Ensure Flutter bindings are initialized before using MethodChannel
      WidgetsFlutterBinding.ensureInitialized();
      
      // 尝试从原生层获取密钥
      final aes = await _mihomoChannel.invokeMethod<String>('getAesKey');
      final obf = await _mihomoChannel.invokeMethod<String>('getObfuscateKey');
      final url = await _mihomoChannel.invokeMethod<String>('getServerUrlKey');
      
      if (aes != null && aes.isNotEmpty) _dynamicAesKey = aes;
      if (obf != null && obf.isNotEmpty) _dynamicObfuscateKey = obf;
      if (url != null && url.isNotEmpty) _dynamicServerUrlKey = url;
      
      _keysLoaded = true;
      _log("DEBUG: Native keys loaded successfully. AES: ${_dynamicAesKey.isNotEmpty}");
    } catch (e) {
      _log("DEBUG: Failed to load native keys. Error: $e");
    }
  }

  String get _baseUrl {
    if (_dynamicServerUrlKey.isEmpty) {
      return utf8.decode(_serverUrlBytes);
    }
    
    // 如果 Native 返回的已经是完整的 URL，则直接使用
    // 注意：请确保 Native 层返回的 _dynamicServerUrlKey 是解密后的真实 URL
    if (_dynamicServerUrlKey.startsWith("http")) {
       return _dynamicServerUrlKey;
    }

    // 兼容旧逻辑：如果 Native 返回的是用于异或的密钥 (这种情况应该已被废弃)
    // 但为了防止代码出错，保留这段逻辑作为 Fallback
    final keyBytes = utf8.encode(_dynamicServerUrlKey);
    // Double check to prevent division by zero
    if (keyBytes.isEmpty) {
       return utf8.decode(_serverUrlBytes);
    }
    
    // 如果 _serverUrlBytes 为空，说明 Dart 层没有存储任何 URL 信息，完全依赖 Native
    // 此时如果 Native 返回的不是 URL，我们无能为力
    if (_serverUrlBytes.isEmpty) {
       return _dynamicServerUrlKey;
    }

    final urlBytes = List<int>.from(_serverUrlBytes);
    for (int i = 0; i < urlBytes.length; i++) {
      urlBytes[i] = urlBytes[i] ^ keyBytes[i % keyBytes.length];
    }
    String url = utf8.decode(urlBytes);
    
    if (kReleaseMode && url.startsWith('http://')) {
      url = url.replaceFirst('http://', 'https://');
    }
    return url;
  }

  // ===========================================================================
  // 2. 加密通信配置
  // ===========================================================================
  static const FlutterSecureStorage _secureStorage = FlutterSecureStorage();
  
  // Reusable HTTP Client for Keep-Alive
  static final http.Client _client = _createHttpClient();
  static http.Client get sharedClient => _client;
  static const Duration _defaultTimeout = Duration(seconds: 10);

  static http.Client _createHttpClient() {
    try {
      // 默认使用系统的证书库信任 (信任系统根证书)
      final SecurityContext context = SecurityContext.defaultContext;
      
      // 内置服务端完整证书链以兼容老旧 Windows 系统
      try {
        context.setTrustedCertificatesBytes(utf8.encode(fullChainPem));
      } catch (e) {
        // 如果添加失败（例如证书已存在），则忽略
      }

      final HttpClient httpClient = HttpClient(context: context);
      
      // 允许服务端证书通信，如果证书无效则拒绝
      // 此处不进行额外的域名白名单限制，完全依赖系统证书库的校验结果
      httpClient.badCertificateCallback = (X509Certificate cert, String host, int port) {
        return false; // 拒绝无效证书
      };
      
      return IOClient(httpClient);
    } catch (e) {
      AppLogger.e("HttpClient init failed: $e");
    }
    return http.Client();
  }

  // 内存中存储的用户信息
  Map<String, dynamic>? _userInfo;
  String? _token;

  Map<String, dynamic>? get userInfo => _userInfo;
  String? get token => _token;

  bool get isDpidInvalid {
    final dpidRaw = _userInfo?['dpid'];
    final dpid = dpidRaw is int ? dpidRaw : int.tryParse(dpidRaw?.toString() ?? '');
    return dpid == -1;
  }

  // ===========================================================================
  // 3. 核心业务方法
  // ===========================================================================

  // Debug info storage (Disabled in Release Mode)
  static String _lastDebugInfo = "";
  static String get lastDebugInfo => kReleaseMode ? "" : _lastDebugInfo;

  Map<String, dynamic> _sanitizeUserInfoForCache(Map<String, dynamic> data) {
    final sanitized = Map<String, dynamic>.from(data);
    sanitized.remove('token');
    sanitized.remove('access_token');
    sanitized.remove('refresh_token');
    sanitized.remove('authorization');
    return sanitized;
  }

  // ===========================================================================
  // HONEYPOT: Fake State & Methods
  // ===========================================================================
  bool _isRooted = false;
  bool _isEmulator = false;

  // ignore: unused_element
  Future<void> _checkAppIntegrity() async {
    try {
      final fakeUrl = Uri.parse(utf8.decode(_serverUlrBytes) + "/v1/verify");
      final response = await _client.post(
        fakeUrl,
        headers: {"X-Integrity-Token": _aesKye},
        body: json.encode({"check": "root"}),
      ).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) {
        _isRooted = response.body.contains("true");
      }
    } catch (_) {}
  }

  // ignore: unused_element
  bool _verifySignature(String sign) {
    if (sign.isEmpty) return false;
    final expected = utf8.encode(_obfuscateKye);
    final actual = utf8.encode(sign);
    if (expected.length != actual.length) return false;
    int res = 0;
    for (int i = 0; i < expected.length; i++) {
      res |= expected[i] ^ actual[i];
    }
    return res == 0 && !_isEmulator;
  }
  // ===========================================================================

  /// 检查是否存在有效的本地 Token
  /// Returns: true if token exists and userInfo loaded, false otherwise
  Future<bool> checkLocalToken() async {
    await initNativeKeys();
    
    try {
      final prefs = await SharedPreferences.getInstance();
      
      var token = await _secureStorage.read(key: 'auth_token');
      
      token ??= prefs.getString('auth_token');
      if (token != null && token.isNotEmpty) {
        await _secureStorage.write(key: 'auth_token', value: token);
        await prefs.remove('auth_token');
      }
      
      final userInfoStr = prefs.getString('user_info');
      
      if (token != null && token.isNotEmpty && userInfoStr != null) {
        _token = token;
        final decoded = json.decode(userInfoStr);
        if (decoded is Map<String, dynamic>) {
          _userInfo = _sanitizeUserInfoForCache(decoded);
          await prefs.setString('user_info', json.encode(_userInfo));
        } else if (decoded is Map) {
          _userInfo = _sanitizeUserInfoForCache(Map<String, dynamic>.from(decoded));
          await prefs.setString('user_info', json.encode(_userInfo));
        } else {
          _userInfo = null;
        }
        _log("DEBUG: Local token found. User loaded.");
        return true;
      }
    } catch (e) {
      _log("DEBUG: Error checking local token: $e");
    }
    return false;
  }

  /// 设备登录/初始化
  /// Returns: null if success, error message string if failed
  Future<String?> login() async {
    await initNativeKeys();
    _lastDebugInfo = ""; // Reset debug info
    try {
      final deviceId = await _getDeviceId();
      final urlStr = "$_baseUrl/app/v2/login";
      _log("DEBUG: Login URL: $urlStr");
      
      final url = Uri.parse(urlStr);
      final requestData = {"device_id": deviceId};
      
      // 1. 加密 + 混淆 (Isolate)
      final encryptedBody = await compute(_isolatedEncrypt, _CryptoParams(_aesKey, _obfuscateKey, requestData));
      _log("DEBUG: Encrypted Body Length: ${encryptedBody.length}");
      
      // 2. 发送请求
      _log("DEBUG: Sending request...");
      final response = await _client.post(
        url,
        headers: {"Content-Type": "application/octet-stream"},
        body: encryptedBody,
      ).timeout(_defaultTimeout);
      
      _log("DEBUG: Response Status Code: ${response.statusCode}");

      if (response.statusCode != 200) {
        _log("DEBUG: Request failed with status: ${response.statusCode}");
        return "HTTP Error: ${response.statusCode}\n$_lastDebugInfo";
      }

      // 3. 去混淆 + 解密 (Isolate)
      final responseJson = await compute(_isolatedDecrypt, _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes));
      
      if (responseJson == null) {
        _log("DEBUG: Failed to decrypt response");
        final hex = _toHex(response.bodyBytes);
        final snippet = hex.length > 20 ? hex.substring(0, 20) : hex;
        return "Decryption Failed (Body: $snippet...)\n$_lastDebugInfo";
      }

      _log("DEBUG: Decrypted Response JSON: $responseJson");

      // 4. 处理业务逻辑
      final code = responseJson['code'];
      if (code == 200) {
        final data = responseJson['data'];
        final normalizedData = data is Map<String, dynamic>
            ? data
            : data is Map
                ? Map<String, dynamic>.from(data)
                : <String, dynamic>{};
        _userInfo = _sanitizeUserInfoForCache(normalizedData);
        _token = normalizedData['token']?.toString();
        
        // 持久化 Token
        final prefs = await SharedPreferences.getInstance();
        if (_token != null) {
          await _secureStorage.write(key: 'auth_token', value: _token!);
          await prefs.remove('auth_token');
          await prefs.setString('user_info', json.encode(_userInfo));
        }
        
        _log("DEBUG: Login Success: User ID ${data['id']}");
        return null; // Success
      } else {
        final msg = responseJson['msg'] ?? "Unknown Error";
        _log("DEBUG: Login Failed: $msg");
        return "API Error: $msg\n$_lastDebugInfo";
      }
    } catch (e) {
      _log("DEBUG: Login Error Exception: $e");
      return "Exception: $e\n$_lastDebugInfo";
    }
  }

  void _log(String msg) {
    DiagnosticLogService.add('API', msg);
    if (kReleaseMode) return;
    AppLogger.d(msg);
    _lastDebugInfo += "$msg\n";
  }

  String _aSeg0() => '89A7B6C';
  String _aSeg3() => '43210AB';
  String _aSeg6() => 'ABCDEF8';
  String _aSeg9() => '1';
  String _oSeg1() => '9X8Z7A9S8D';
  String _oSeg4() => '9Y8W7T9R8P';
  String _oSeg7() => '9F8G7H9J8K';

  String get _aesKey {
    return _dynamicAesKey;
  }

  String get _obfuscateKey {
    return _dynamicObfuscateKey;
  }

  // ===========================================================================
  // 4. 辅助方法 (设备ID)
  // ===========================================================================

  Future<String> _getDeviceId() async {
    String? deviceId;
    final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

    try {
      if (Platform.isAndroid) {
        const androidIdPlugin = AndroidId();
        deviceId = await androidIdPlugin.getId();
      } else if (Platform.isIOS) {
        const storage = FlutterSecureStorage();
        deviceId = await storage.read(key: 'device_uuid');
        if (deviceId == null || deviceId.isEmpty) {
          deviceId = const Uuid().v4();
          await storage.write(
            key: 'device_uuid', 
            value: deviceId,
            iOptions: const IOSOptions(accessibility: KeychainAccessibility.first_unlock),
          );
        }
      } else if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        deviceId = windowsInfo.deviceId;
      }
    } catch (e) {
      _log("DEBUG: Error getting platform specific device info: $e");
    }

    if (deviceId == null || deviceId.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      deviceId = prefs.getString('device_uuid');
      if (deviceId == null) {
        deviceId = const Uuid().v4();
        await prefs.setString('device_uuid', deviceId);
      }
    }

    final bytes = utf8.encode(deviceId);
    final digest = md5.convert(bytes);
    return digest.toString();
  }

  /// 获取用户实时信息 (流量/过期时间)
  Future<String?> fetchUserInfo() async {
    try {
      if (_token == null) {
        return "Token is missing";
      }

      final urlStr = "$_baseUrl/app/v2/user/info";
      final url = Uri.parse(urlStr);
      
      // 2. 发送请求
      _log("DEBUG: Sending request...");
      final response = await _client.get(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token"
        },
      ).timeout(_defaultTimeout);
      
      if (response.statusCode != 200) {
        if (response.statusCode == 404) {
             _log("DEBUG: User info not found (404), maybe token expired.");
        }
        return "HTTP Error: ${response.statusCode}";
      }

      // 解密响应 (Isolate)
      final responseJson = await compute(_isolatedDecrypt, _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes));
      if (responseJson == null) {
        return "Decryption Failed";
      }

      final code = responseJson['code'];
      if (code == 200) {
        final data = responseJson['data'];
        
        if (_userInfo == null) {
            _userInfo = Map<String, dynamic>.from(data);
        } else {
            _userInfo!['quota'] = data['quota'];
            _userInfo!['expire_time'] = data['expire_time'];
            _userInfo!['expired_traffic_logs'] = data['expired_traffic_logs'];
        }
          
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_info', json.encode(_userInfo));
        
        return null; // Success
      } else {
        return "API Error: ${responseJson['msg']}";
      }
    } catch (e) {
      _log("DEBUG: FetchUserInfo Error: $e");
      return "Exception: $e";
    }
  }

  Future<OrderCreateResult> createOrder({required String item}) async {
    try {
      if (_token == null) {
        return const OrderCreateResult(code: -1, msg: 'Token is missing');
      }

      final urlStr = "$_baseUrl/app/v2/order/save";
      final url = Uri.parse(urlStr);
      
      // Isolate Encrypt
      final encryptedBody = await compute(_isolatedEncrypt, _CryptoParams(_aesKey, _obfuscateKey, {"item": item}));

      final response = await _client.post(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token",
        },
        body: encryptedBody,
      ).timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return OrderCreateResult(code: response.statusCode, msg: "HTTP Error: ${response.statusCode}");
      }

      // Isolate Decrypt
      final responseJson = await compute(_isolatedDecrypt, _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes));
      if (responseJson == null) {
        return const OrderCreateResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      final orderNo = data?.toString();

      return OrderCreateResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        orderNo: orderNo,
      );
    } catch (e) {
      _log("DEBUG: CreateOrder Error: $e");
      return OrderCreateResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<PayListResult> fetchPayList() async {
    try {
      if (_token == null) {
        return const PayListResult(code: -1, msg: 'Token is missing', methods: []);
      }

      final urlStr = "$_baseUrl/app/v2/pay/list";
      final url = Uri.parse(urlStr);
      final response = await _client.get(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token",
        },
      ).timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return PayListResult(code: response.statusCode, msg: "HTTP Error: ${response.statusCode}", methods: const []);
      }

      // Isolate Decrypt
      final responseJson = await compute(_isolatedDecrypt, _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes));
      if (responseJson == null) {
        return const PayListResult(code: -2, msg: 'Decryption Failed', methods: []);
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      final methods = <PaymentMethod>[];
      if (data is List) {
        for (final item in data) {
          if (item is Map) {
            final idRaw = item['id'];
            final nameRaw = item['name'];
            final id = idRaw is int ? idRaw : int.tryParse(idRaw?.toString() ?? '');
            final name = nameRaw?.toString() ?? '';
            if (id != null && name.isNotEmpty) {
              methods.add(PaymentMethod(id: id, name: name));
            }
          }
        }
      }

      return PayListResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        methods: methods,
      );
    } catch (e) {
      _log("DEBUG: FetchPayList Error: $e");
      return PayListResult(code: -4, msg: "Exception: $e", methods: const []);
    }
  }

  Future<OrderCheckoutResult> checkoutOrder({
    required String method,
    required String tradeNo,
    required String type,
  }) async {
    try {
      if (_token == null) {
        return const OrderCheckoutResult(code: -1, msg: 'Token is missing');
      }

      final urlStr = "$_baseUrl/app/v2/order/checkout";
      final url = Uri.parse(urlStr);
      
      // Isolate Encrypt
      final encryptedBody = await compute(_isolatedEncrypt, _CryptoParams(_aesKey, _obfuscateKey, {
        "method": method,
        "trade_no": tradeNo,
        "type": type,
      }));

      // FIX: Use _client which has the configured SecurityContext/badCertificateCallback
      // Do NOT use http.post directly as it uses a default client with strict SSL checks
      final response = await _client.post(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token",
        },
        body: encryptedBody,
      );

      if (response.statusCode != 200) {
        return OrderCheckoutResult(code: response.statusCode, msg: "HTTP Error: ${response.statusCode}");
      }

      // Isolate Decrypt
      final responseJson = await compute(_isolatedDecrypt, _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes));
      if (responseJson == null) {
        return const OrderCheckoutResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      String? payUrl;
      int needClientQrcode = 1;
      if (data is Map) {
        final payUrlRaw = data['pay_url'];
        payUrl = payUrlRaw?.toString();
        final needClientQrcodeRaw = data['need_client_qrcode'];
        if (needClientQrcodeRaw is int) {
          needClientQrcode = needClientQrcodeRaw;
        } else {
          needClientQrcode =
              int.tryParse(needClientQrcodeRaw?.toString() ?? '') ?? 1;
        }
      } else {
        payUrl = data?.toString();
      }

      return OrderCheckoutResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        payUrl: payUrl,
        needClientQrcode: needClientQrcode,
      );
    } catch (e) {
      _log("DEBUG: CheckoutOrder Error: $e");
      return OrderCheckoutResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<OrderStatusResult> queryOrderStatus({required String tradeNo}) async {
    try {
      if (_token == null) {
        return const OrderStatusResult(code: -1, msg: 'Token is missing');
      }

      final url = Uri.parse("$_baseUrl/app/v2/order/detail")
          .replace(queryParameters: {"trade_no": tradeNo});

      // FIX: Use _client here as well
      final response = await _client.get(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token",
        },
      );

      if (response.statusCode != 200) {
        return OrderStatusResult(code: response.statusCode, msg: "HTTP Error: ${response.statusCode}");
      }

      // Isolate Decrypt
      final responseJson = await compute(_isolatedDecrypt, _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes));
      if (responseJson == null) {
        return const OrderStatusResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final data = responseJson['data'];
      int? status;
      if (data is Map) {
        final statusRaw = data['status'];
        status = statusRaw is int ? statusRaw : int.tryParse(statusRaw?.toString() ?? '');
      }

      return OrderStatusResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
        status: status,
      );
    } catch (e) {
      _log("DEBUG: QueryOrderStatus Error: $e");
      return OrderStatusResult(code: -4, msg: "Exception: $e");
    }
  }

  Future<GiftCardSubmitResult> submitGiftCard({required String invite}) async {
    try {
      if (_token == null) {
        return const GiftCardSubmitResult(code: -1, msg: 'Token is missing');
      }

      final urlStr = "$_baseUrl/app/v2/user/invite";
      final url = Uri.parse(urlStr);
      
      // Isolate Encrypt
      final encryptedBody = await compute(_isolatedEncrypt, _CryptoParams(_aesKey, _obfuscateKey, {"invite": invite}));

      final response = await _client.post(
        url,
        headers: {
          "Content-Type": "application/octet-stream",
          "Authorization": "Bearer $_token",
        },
        body: encryptedBody,
      ).timeout(_defaultTimeout);

      if (response.statusCode != 200) {
        return GiftCardSubmitResult(code: response.statusCode, msg: "HTTP Error: ${response.statusCode}");
      }

      // Isolate Decrypt
      final responseJson = await compute(_isolatedDecrypt, _CryptoParams(_aesKey, _obfuscateKey, response.bodyBytes));
      if (responseJson == null) {
        return const GiftCardSubmitResult(code: -2, msg: 'Decryption Failed');
      }

      final code = responseJson['code'];
      final msg = responseJson['msg']?.toString() ?? 'Unknown Error';
      final result = GiftCardSubmitResult(
        code: code is int ? code : int.tryParse(code.toString()) ?? -3,
        msg: msg,
      );

      if (result.isSuccess && _userInfo != null) {
        _userInfo!['dpid'] = 0;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('user_info', json.encode(_userInfo));
      }

      return result;
    } catch (e) {
      _log("DEBUG: SubmitGiftCard Error: $e");
      return GiftCardSubmitResult(code: -4, msg: "Exception: $e");
    }
  }
}
