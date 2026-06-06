import 'package:flutter/material.dart';
import 'emby/emby_login_page.dart';
import 'emby/emby_home_page.dart';
import 'scanner/scanner_home_page.dart';
import '../services/emby_service.dart';

class LauncherPage extends StatelessWidget {
  const LauncherPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('选择功能', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 48),
              _AppCard(
                icon: Icons.play_circle_fill,
                title: 'Emby 播放器',
                subtitle: '连接 Emby 服务器，浏览并播放媒体',
                color: Colors.green,
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => EmbyService().isLoggedIn ? const EmbyHomePage() : const EmbyLoginPage(),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _AppCard(
                icon: Icons.qr_code_scanner,
                title: '扫码登录',
                subtitle: '扫描二维码进行账号登录',
                color: Colors.deepPurple,
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                    builder: (_) => const ScannerHomePage(title: '扫码登录'),
                  ),
                ),
              ),
            ],
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
    return Material(
      color: Colors.grey[900],
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
                    Text(title, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text(subtitle, style: TextStyle(color: Colors.grey[400], fontSize: 13)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Colors.grey[600]),
            ],
          ),
        ),
      ),
    );
  }
}
