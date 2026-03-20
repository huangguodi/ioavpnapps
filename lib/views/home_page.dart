import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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
                          const SizedBox(width: 24, height: 24),
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
                          const SizedBox(width: 24, height: 24),
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
}
