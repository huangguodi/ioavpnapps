import 'dart:async';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/mihomo_service.dart';
import 'package:app/core/constants.dart';
import 'package:app/views/widgets/custom_dialog.dart';
import 'home_page.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  @override
  void initState() {
    super.initState();
    // 设置沉浸式导航栏
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
    ));
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    // 延迟一帧执行，确保上下文准备好
    // 缩短等待时间，提升启动速度
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) {
        _initApp();
      }
    });
  }

  Future<void> _initApp() async {
    // 1. Request Android Permissions First
    if (!kIsWeb && Platform.isAndroid) {
      try {
        // 请求通知权限 (Android 13+)
        if (await Permission.notification.isDenied) {
          await Permission.notification.request();
        }

        // 请求忽略电池优化 (华为/小米等保活关键)
        // 注意：部分应用商店可能禁止直接请求此权限，但在国内环境这是必须的
        if (await Permission.ignoreBatteryOptimizations.isDenied) {
           await Permission.ignoreBatteryOptimizations.request();
        }
      } catch (e) {
        // 忽略权限请求错误，避免阻塞后续流程
      }
    }

    final hasLocalToken = await ApiService().checkLocalToken();

    if (hasLocalToken) {
      await ApiService().fetchUserInfo();
    }

    String? errorMsg;
    try {
      errorMsg = await ApiService().login();
    } catch (e) {
      errorMsg = "Exception: $e";
    }
    
    // Check if widget is still mounted after async operations
    if (!mounted) return;

    final success = errorMsg == null;
    
    if (success) {
      final redeemed = await _ensureGiftCardRedeemed();
      if (!redeemed || !mounted) return;
      bool started = await _startMihomo();
      if (started) {
        final initialMode = await _resolveInitialMode();
        await _prepareHomeResources();
        _navigateToHome(initialMode);
      }
    } else {
      // 失败退出APP
      SystemNavigator.pop();
    }
  }

  Future<void> _showPermissionDeniedDialog(String title, String message) async {
    if (!mounted) return;
    await showAnimatedDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
          ),
          title: Text(
            '$title被拒绝',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          content: Text(
            '$message\n\n请在系统设置中手动授权，然后重新打开应用。',
            style: const TextStyle(color: Colors.white70, fontSize: 15, height: 1.5),
          ),
          actions: [
            TextButton(
              onPressed: () {
                SystemNavigator.pop();
              },
              child: const Text('退出应用', style: TextStyle(color: Color(0xFF96CBFF), fontSize: 16)),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _ensureGiftCardRedeemed() async {
    if (!mounted) return false;
    if (!ApiService().isDpidInvalid) return true;
    await _showGiftCardRedeemFullscreenDialog();
    return mounted;
  }

  Future<void> _showGiftCardTipDialog({
    required BuildContext dialogContext,
    required String message,
    bool isError = true,
  }) async {
    await showAnimatedDialog<void>(
      context: dialogContext,
      barrierDismissible: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.cardBackground,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF96CBFF), width: 1.1),
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  isError ? '兑换失败' : '提示',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, color: Colors.white60, size: 20),
              ),
            ],
          ),
          content: Text(
            message,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                '确定',
                style: TextStyle(
                  color: isError ? Colors.redAccent : const Color(0xFF96CBFF),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showGiftCardRedeemFullscreenDialog() async {
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'gift_card_redeem',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, animation, secondaryAnimation) {
        final controller = TextEditingController();
        bool isSubmitting = false;

        return StatefulBuilder(
          builder: (context, setState) {
            final canRedeem = controller.text.trim().isNotEmpty;
            return PopScope(
              canPop: false,
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Stack(
                  children: [
                    Positioned.fill(
                      child: Image.asset(
                        AppAssets.resolveImage(context, 'gradient3.png'),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    ),
                    SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 28),
                            const Text(
                              '礼品卡密兑换',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 16),
                            const Text(
                              '礼品卡密兑换，即可获得 100GB 高速流量包，流量实时到账，立即生效使用',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                height: 1.6,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              '获取方案：请联系群主或您的推荐人获取卡密',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 13,
                                height: 1.6,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: controller,
                                    enabled: !isSubmitting,
                                    onChanged: (_) => setState(() {}),
                                    style: const TextStyle(color: Colors.white),
                                    decoration: InputDecoration(
                                      hintText: '输入礼品卡密',
                                      hintStyle: const TextStyle(color: Colors.white38),
                                      filled: true,
                                      fillColor: Colors.white.withValues(alpha: 0.09),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.24)),
                                      ),
                                      focusedBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: const BorderSide(color: Color(0xFF96CBFF), width: 1.2),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  height: 48,
                                  child: OutlinedButton.icon(
                                    onPressed: isSubmitting
                                        ? null
                                        : () async {
                                            final clipData = await Clipboard.getData('text/plain');
                                            final text = clipData?.text?.trim() ?? '';
                                            if (text.isEmpty) return;
                                            controller.text = text;
                                            controller.selection = TextSelection.fromPosition(
                                              TextPosition(offset: controller.text.length),
                                            );
                                            setState(() {});
                                          },
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: const Color(0xFF96CBFF),
                                      side: const BorderSide(color: Color(0xFF96CBFF), width: 1),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    icon: const Icon(Icons.content_paste_rounded, size: 16),
                                    label: const Text('粘贴'),
                                  ),
                                ),
                              ],
                            ),
                            const Spacer(),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: isSubmitting || !canRedeem
                                    ? null
                                    : () async {
                                        final invite = controller.text.trim();
                                        setState(() {
                                          isSubmitting = true;
                                        });
                                        final result = await ApiService().submitGiftCard(invite: invite);
                                        if (!context.mounted) return;
                                        if (result.isSuccess) {
                                          final reloginError = await ApiService().login();
                                          if (!context.mounted) return;
                                          if (reloginError == null || !ApiService().isDpidInvalid) {
                                            Navigator.of(context).pop();
                                            return;
                                          }
                                          setState(() {
                                            isSubmitting = false;
                                          });
                                          await _showGiftCardTipDialog(
                                            dialogContext: context,
                                            message: '卡密已提交，但账号状态未更新，请重试',
                                          );
                                          return;
                                        }
                                        setState(() {
                                          isSubmitting = false;
                                        });
                                        await _showGiftCardTipDialog(
                                          dialogContext: context,
                                          message: result.msg,
                                        );
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF96CBFF),
                                  foregroundColor: Colors.black,
                                  disabledBackgroundColor: const Color(0xFF96CBFF).withValues(alpha: 0.7),
                                  disabledForegroundColor: Colors.black54,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(14),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                  elevation: 0,
                                ),
                                child: isSubmitting
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.2,
                                          color: Colors.black87,
                                        ),
                                      )
                                    : const Text(
                                        '兑换',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.black,
                                        ),
                                      ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
      transitionBuilder: (context, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.05),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<bool> _startMihomo() async {
    try {
      // Initialize service (copy assets, MMDB, etc.)
      await MihomoService().init();
      
      // Stop any existing instance to ensure a fresh cold start with correct ports
      if (await MihomoService().checkIsRunning()) {
         await MihomoService().stop();
         await Future.delayed(const Duration(seconds: 1));
      }
      
      final userInfo = ApiService().userInfo;
      if (userInfo != null) {
        final subscribeUrl = userInfo['subscribe_url'];
        if (subscribeUrl != null && subscribeUrl.toString().isNotEmpty) {
           await MihomoService().start(subscribeUrl: subscribeUrl.toString());
           return true;
        } else {
           return false;
        }
      }
      return false;
    } on PlatformException catch (e) {
      if (e.code == "VPN_PERMISSION_DENIED") {
        if (mounted) {
          await showAnimatedDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('权限被拒绝'),
              content: const Text('加速器需要 VPN 权限才能工作。请手动打开权限或重新启动应用授权。'),
              actions: [
                TextButton(
                  onPressed: () {
                    SystemNavigator.pop();
                  },
                  child: const Text('确定并退出'),
                ),
              ],
            ),
          );
        }
      } else {
        // Handle generic start error
        if (mounted) {
           await showAnimatedDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('启动失败'),
              content: Text('服务启动失败，请检查网络或重试。\n错误: $e'),
              actions: [
                TextButton(
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('退出应用'),
                ),
              ],
            ),
          );
        }
      }
      return false;
    } catch (e) {
       // Catch-all for non-PlatformExceptions (like the Exception thrown by start() after 3 retries)
       if (mounted) {
          await showAnimatedDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('启动失败'),
              content: Text('服务启动失败 (3次重试无效)。\n错误: $e'),
              actions: [
                TextButton(
                  onPressed: () => SystemNavigator.pop(),
                  child: const Text('退出应用'),
                ),
              ],
            ),
          );
       }
       return false;
    }
  }

  Future<ConnectionMode> _resolveInitialMode() async {
    try {
      final isRunning = await MihomoService().checkIsRunning();
      if (!isRunning) return ConnectionMode.off;
      final mode = await MihomoService().getMode();
      if (mode == 'global') return ConnectionMode.global;
      if (mode == 'direct') return ConnectionMode.off;
      return ConnectionMode.smart;
    } catch (_) {
      return ConnectionMode.off;
    }
  }

  Future<void> _prepareHomeResources() async {
    if (!mounted) return;
    await Future.wait([
      precacheImage(AssetImage(AppAssets.resolveImage(context, 'gradient.png')), context),
      precacheImage(AssetImage(AppAssets.resolveImage(context, 'gradient1.png')), context),
      precacheImage(AssetImage(AppAssets.resolveImage(context, 'gradient2.png')), context),
      precacheImage(AssetImage(AppAssets.resolveImage(context, 'logo.png')), context),
    ]);
  }

  Future<void> _navigateToHome(ConnectionMode initialMode) async {
    // 确保服务完全启动后再跳转
    // MihomoService().start() 现在已经是 awaitable 的，并在内部验证了连接。
    // 所以这里无需额外等待。
    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => HomePage(initialMode: initialMode),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFF101F2D),
        body: Center(
          child: Hero(
            tag: 'app_logo',
            child: Material(
              color: Colors.transparent,
              child: Image.asset(
                AppAssets.resolveImage(context, 'logo.png'),
                scale: 4.0, // 强制指定 scale 为 4.0 (xxxhdpi)，使大小与原生启动图一致
              ),
            ),
          ),
        ),
      ),
    );
  }
}
