import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'emby-pc/emby_pc_page.dart';
import 'scanner/scanner_home_page.dart';
import 'settings_page.dart';

class LauncherPage extends StatelessWidget {
  const LauncherPage({super.key});

  Future<bool> _onWillPop(BuildContext context) async {
    return await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出应用'),
        content: const Text('确定要退出应用吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('退出')),
        ],
      ),
    ) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _onWillPop(context)) SystemNavigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('选择功能'),
          automaticallyImplyLeading: false,
          actions: [
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('选择功能', style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 28, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                const SizedBox(height: 48),
                _AppCard(
                  icon: Icons.play_circle_fill,
                  title: 'Emby 播放器',
                  subtitle: '连接 Emby 服务器，浏览并播放媒体',
                  color: Colors.green,
                  // 桌面端入口统一交给 EmbyPcEntryPage，负责会话恢复与登录分流。
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const EmbyPcEntryPage()),
                  ),
                ),
                const SizedBox(height: 16),
                _AppCard(
                  icon: Icons.qr_code_scanner,
                  title: '扫码登录',
                  subtitle: '扫描二维码进行账号登录',
                  color: Colors.deepPurple,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const ScannerHomePage(title: '扫码登录'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback onTap;

  const _AppCard({required this.icon, required this.title, required this.subtitle, required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Row(
            children: [
              Icon(icon, color: color, size: 48),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: TextStyle(color: cs.onSurface, fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
