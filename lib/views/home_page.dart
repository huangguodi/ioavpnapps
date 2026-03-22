import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/diagnostic_log_service.dart';
import 'package:app/services/mihomo_service.dart';
import 'package:app/core/constants.dart';
import 'package:app/core/utils.dart';
import 'package:app/view_models/home_view_model.dart';
import 'package:app/views/widgets/traffic_panel.dart';
import 'package:app/views/widgets/mode_switch.dart';
import 'package:app/views/widgets/node_selector.dart';
import 'package:app/views/dialogs/traffic_purchase_dialog.dart';

class HomePage extends StatelessWidget {
  final ConnectionMode initialMode;

  const HomePage({super.key, this.initialMode = ConnectionMode.off});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => HomeViewModel(initialMode: initialMode)..init(),
      child: const _HomePageContent(),
    );
  }
}

class _HomePageContent extends StatefulWidget {
  const _HomePageContent();

  @override
  State<_HomePageContent> createState() => _HomePageContentState();
}

class _HomePageContentState extends State<_HomePageContent> with WidgetsBindingObserver {
  bool _showingExpiredTrafficDialog = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final vm = context.read<HomeViewModel>();
    if (state == AppLifecycleState.resumed) {
      vm.onAppResumed();
    } else if (state == AppLifecycleState.paused) {
      vm.onAppPaused();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    precacheImage(AssetImage(AppAssets.resolveImage(context, 'gradient.png')), context);
    precacheImage(AssetImage(AppAssets.resolveImage(context, 'gradient1.png')), context);
    precacheImage(AssetImage(AppAssets.resolveImage(context, 'gradient2.png')), context);
  }

  String _getBackgroundImage(BuildContext context, ConnectionMode mode) {
    switch (mode) {
      case ConnectionMode.off:
        return AppAssets.resolveImage(context, 'gradient.png');
      case ConnectionMode.smart:
        return AppAssets.resolveImage(context, 'gradient1.png');
      case ConnectionMode.global:
        return AppAssets.resolveImage(context, 'gradient2.png');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<HomeViewModel>(
      builder: (context, vm, child) {
        if (!_showingExpiredTrafficDialog &&
            vm.pendingExpiredTrafficLogNotices.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showNextExpiredTrafficDialog(vm);
          });
        }
        return Scaffold(
          backgroundColor: AppColors.background,
          body: Stack(
            children: [
              // 首页背景
              Positioned.fill(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                  child: Image.asset(
                    _getBackgroundImage(context, vm.connectionMode),
                    key: ValueKey<String>(_getBackgroundImage(context, vm.connectionMode)),
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) => Container(color: AppColors.background),
                  ),
                ),
              ),
              SafeArea(
                child: Column(
                  children: [
                    // 顶部导航栏
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.bug_report_rounded, color: Colors.white70, size: 22),
                            onPressed: () => _showDiagnosticsDialog(vm),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 15.0),
                            child: Hero(
                              tag: 'app_logo',
                              flightShuttleBuilder: (
                                BuildContext flightContext,
                                Animation<double> animation,
                                HeroFlightDirection flightDirection,
                                BuildContext fromHeroContext,
                                BuildContext toHeroContext,
                              ) {
                                return Material(
                                  color: Colors.transparent,
                                  child: Image.asset(
                                    AppAssets.resolveImage(context, 'logo.png'),
                                    fit: BoxFit.contain,
                                  ),
                                );
                              },
                              child: Material(
                                color: Colors.transparent,
                                child: Image.asset(
                                  AppAssets.resolveImage(context, 'logo.png'),
                                  width: 40,
                                  height: 40,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 40, height: 40),
                        ],
                      ),
                    ),

                    const Spacer(flex: 5),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: vm.connectionMode == ConnectionMode.global
                          ? const Padding(
                              key: ValueKey('global-node-button'),
                              padding: EdgeInsets.symmetric(horizontal: 22),
                              child: NodeSelector(),
                            )
                          : const SizedBox.shrink(key: ValueKey('global-node-empty')),
                    ),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TrafficPanel(
                        onPurchaseTap: () => TrafficPurchaseDialog.show(context),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: ModeSwitch(
                        mode: vm.connectionMode,
                        isSwitching: vm.isSwitching,
                        onModeChanged: vm.setMode,
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showNextExpiredTrafficDialog(HomeViewModel vm) async {
    if (_showingExpiredTrafficDialog || !mounted) return;
    final notice = vm.consumeNextExpiredTrafficLogNotice();
    if (notice == null) return;
    _showingExpiredTrafficDialog = true;
    final shouldPurchase = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('流量包过期提醒'),
          content: Text(
            '${notice.label} 流量包于 ${notice.createDate} 过期\n过期了流量：${formatBytes(notice.trafficBytes)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('知道了'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('购买流量包'),
            ),
          ],
        );
      },
    );
    _showingExpiredTrafficDialog = false;
    if (!mounted) return;
    if (shouldPurchase == true) {
      await TrafficPurchaseDialog.show(context);
    }
    if (vm.pendingExpiredTrafficLogNotices.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showNextExpiredTrafficDialog(vm);
      });
    }
  }

  Future<void> _showDiagnosticsDialog(HomeViewModel vm) async {
    final report = await _buildDiagnosticReport(vm);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('诊断日志'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                report,
                style: const TextStyle(fontSize: 12, height: 1.35),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                await Clipboard.setData(ClipboardData(text: report));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('诊断日志已复制，可直接发给我分析')),
                );
              },
              child: const Text('复制日志'),
            ),
          ],
        );
      },
    );
  }

  Future<String> _buildDiagnosticReport(HomeViewModel vm) async {
    final api = ApiService();
    final userInfo = api.userInfo ?? const <String, dynamic>{};
    String nativeMode = 'unknown';
    bool isRunning = false;
    String selectedGlobal = '--';
    int proxyCount = 0;
    String probeError = '';
    try {
      isRunning = await MihomoService().checkIsRunning();
      nativeMode = await MihomoService().getMode();
      selectedGlobal = await MihomoService().getSelectedProxy('GLOBAL') ?? '--';
      final proxies = await MihomoService().getProxies(forceRefresh: true);
      final proxyMap = proxies['proxies'];
      if (proxyMap is Map) {
        proxyCount = proxyMap.length;
      }
    } catch (e) {
      probeError = e.toString();
    }
    final snapshot = <String, dynamic>{
      'time': DateTime.now().toIso8601String(),
      'uiMode': vm.connectionMode.name,
      'isSwitching': vm.isSwitching,
      'nativeRunning': isRunning,
      'nativeMode': nativeMode,
      'selectedGlobal': selectedGlobal,
      'proxyCount': proxyCount,
      'globalNode': {
        'name': vm.globalNodeName,
        'type': vm.globalNodeType,
        'country': vm.globalNodeCountry,
        'udp': vm.globalNodeUdp,
      },
      'user': {
        'id': userInfo['id'],
        'dpid': userInfo['dpid'],
        'quota': userInfo['quota'],
        'expire_time': userInfo['expire_time'],
        'has_subscribe_url': (userInfo['subscribe_url']?.toString().isNotEmpty ?? false),
      },
      'probeError': probeError,
      'apiDebug': ApiService.lastDebugInfo,
    };
    return '${const JsonEncoder.withIndent('  ').convert(snapshot)}\n\n---- logs ----\n${DiagnosticLogService.dump()}';
  }
}
