import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'services/api_service.dart';
import 'services/global_error_reporter.dart';
import 'services/tray_service.dart';
import 'views/splash_page.dart';

const MethodChannel _securityChannel = MethodChannel('com.accelerator.tg/security');
Timer? _securityWatchdog;
final GlobalKey<NavigatorState> _appNavigatorKey = GlobalKey<NavigatorState>();

class _DirectOnlyHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (_) => 'DIRECT';
    return client;
  }
}

Future<void> _enforceSecurity() async {
  if (!kIsWeb && !kDebugMode) {
    HttpOverrides.global = _DirectOnlyHttpOverrides();
  }
  final isSupportedPlatform = !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isWindows);
  if (!isSupportedPlatform) {
    return;
  }
  try {
    await _securityChannel.invokeMethod('enableSecureMode');
    final isDebuggerAttached = await _securityChannel.invokeMethod<bool>('isDebuggerAttached') ?? false;
    final isAppDebuggable = await _securityChannel.invokeMethod<bool>('isAppDebuggable') ?? false;
    // REMOVED: isProxyDetected because this is a VPN app and it will detect its own proxy
    if (!kDebugMode && (isDebuggerAttached || isAppDebuggable)) {
      await SystemNavigator.pop();
      return;
    }
    _securityWatchdog?.cancel();
    _securityWatchdog = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (kDebugMode) return;
      try {
        final attached = await _securityChannel.invokeMethod<bool>('isDebuggerAttached') ?? false;
        final debuggable = await _securityChannel.invokeMethod<bool>('isAppDebuggable') ?? false;
        if (attached || debuggable) {
          await SystemNavigator.pop();
        }
      } catch (_) {
        // Do not crash on method channel errors in the background
      }
    });
  } catch (_) {
    // Initial setup error, we can ignore to prevent false positive crashes
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  GlobalAppErrorReporter.initialize(_appNavigatorKey);
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    GlobalAppErrorReporter.showError(
      title: '应用错误',
      message: details.exceptionAsString(),
      detail: details.stack?.toString(),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    GlobalAppErrorReporter.showError(
      title: '应用错误',
      message: error.toString(),
      detail: stack.toString(),
    );
    return true;
  };
  
  // Initialize native keys early to prevent api call failures
  await ApiService().initNativeKeys();
  
  await _enforceSecurity();
  
  // Windows 平台适配
  if (!kIsWeb && Platform.isWindows) {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = const WindowOptions(
      size: Size(300, 520), // 调整为更小的 9:16 比例
      minimumSize: Size(300, 520),
      maximumSize: Size(300, 520), // 禁止最大化，固定尺寸
      center: true,
      backgroundColor: Colors.transparent,
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.normal, // 使用系统标题栏，带圆角（Win11默认）
      title: '加速器', // 窗口标题
    );
    
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setResizable(false); // 禁止调整大小
      await windowManager.setMaximizable(false); // 禁止最大化
      await windowManager.setPreventClose(true); // 拦截关闭事件，改为隐藏窗口
      await windowManager.show();
      await windowManager.focus();
    });

    // 初始化系统托盘
    await TrayService().init();
  }
  
  // 设置全屏和透明导航栏，与原生启动页保持一致
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent, // 兼容 Android P+
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarIconBrightness: Brightness.light, // 确保导航栏图标可见
  ));
  
  runZonedGuarded(
    () => runApp(const MyApp()),
    (error, stack) {
      GlobalAppErrorReporter.showError(
        title: '应用错误',
        message: error.toString(),
        detail: stack.toString(),
      );
    },
  );
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isWindows) {
      windowManager.addListener(this);
      _initTray();
    }
  }

  Future<void> _initTray() async {
    // 托盘初始化已移至 main() 中，此处保留空方法或用于后续逻辑
  }

  @override
  void dispose() {
    if (!kIsWeb && Platform.isWindows) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() async {
    if (!kIsWeb && Platform.isWindows) {
      bool _isPreventClose = await windowManager.isPreventClose();
      if (_isPreventClose) {
        await windowManager.hide(); // 隐藏窗口而非退出
      }
    }
    super.onWindowClose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _appNavigatorKey,
      title: 'VPN App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF101F2D)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF101F2D),
      ),
      home: const SplashPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}
