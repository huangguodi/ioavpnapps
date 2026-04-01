import 'dart:io';

import 'package:app/services/mihomo_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IosTunnelDebugPage extends StatefulWidget {
  const IosTunnelDebugPage({super.key});

  @override
  State<IosTunnelDebugPage> createState() => _IosTunnelDebugPageState();
}

class _IosTunnelDebugPageState extends State<IosTunnelDebugPage> {
  final MihomoService _mihomoService = MihomoService();
  final ScrollController _scrollController = ScrollController();
  String _logContent = '';
  bool _isLoading = true;
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _loadLog();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadLog({bool showRefreshing = false}) async {
    if (!Platform.isIOS) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _isRefreshing = false;
        _logContent = '当前仅支持 iOS';
      });
      return;
    }

    if (mounted) {
      setState(() {
        if (showRefreshing) {
          _isRefreshing = true;
        } else {
          _isLoading = true;
        }
      });
    }

    try {
      final content = await _mihomoService.getTunnelDebugLog();
      if (!mounted) {
        return;
      }
      setState(() {
        _logContent = content.trim().isEmpty ? '暂无 Tunnel 日志' : content;
      });
    } catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _logContent = '读取 Tunnel 日志失败：$e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isRefreshing = false;
        });
      }
    }
  }

  Future<void> _copyLog() async {
    await Clipboard.setData(ClipboardData(text: _logContent));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制 Tunnel 日志')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF101F2D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101F2D),
        foregroundColor: Colors.white,
        title: const Text('iOS Tunnel 日志'),
        actions: [
          IconButton(
            onPressed: _isRefreshing ? null : () => _loadLog(showRefreshing: true),
            icon: _isRefreshing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            onPressed: _logContent.isEmpty ? null : _copyLog,
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: const Color(0xFF96CBFF).withValues(alpha: 0.45),
              ),
            ),
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : Scrollbar(
                    controller: _scrollController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        _logContent,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
