import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'pages/emby-pc/emby_pc_page.dart';
import 'services/emby_service.dart';
import 'utils/constants.dart';
import 'utils/storage_util.dart';
import 'utils/theme_manager.dart';
import 'widgets/windows_title_bar.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize media_kit before creating any Player or VideoController.
  MediaKit.ensureInitialized();

  await StorageUtil.init();
  await EmbyService().loadFromStorage();
  await ThemeManager().load();

  String? savedBaseUrl = StorageUtil.getBaseUrl();
  if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
    ApiConstants.setBaseUrl(savedBaseUrl);
  }

  String? token = StorageUtil.getToken();

  // Windows 使用 Flutter 自绘标题栏，其他平台继续沿用系统默认窗口样式。
  final isWindowsDesktop =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  if (isWindowsDesktop) {
    await windowManager.ensureInitialized();

    final windowOptions = WindowOptions(
      size: const Size(1024, 768),
      minimumSize: const Size(720, 520),
      center: true,
      backgroundColor: ThemeManager().themeData.scaffoldBackgroundColor,
      title: '媒体中心',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );

    // 在首帧绘制前完成窗口尺寸和位置设置，避免窗口显示后再跳动。
    await windowManager.waitUntilReadyToShow(windowOptions);
  }

  runApp(MyApp(token: token));
}

class MyApp extends StatelessWidget {
  final String? token;

  const MyApp({super.key, this.token});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeManager(),
      builder:
          (context, _) => MaterialApp(
            title: '媒体中心',
            theme: ThemeManager().themeData,
            // 应用仅提供 EmbyPc 功能，启动后直接交由入口页恢复会话或展示登录页。
            home: const EmbyPcEntryPage(),
            // 标题栏放在 Navigator 外层，确保弹窗和所有子页面都共用同一窗口框架。
            builder: (context, child) {
              final content = child ?? const SizedBox.shrink();
              if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) {
                return content;
              }
              return WindowsTitleBar(child: content);
            },
          ),
    );
  }
}
