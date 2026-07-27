import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'pages/launcher_page.dart';
import 'services/emby_service.dart';
import 'utils/constants.dart';
import 'utils/storage_util.dart';
import 'utils/theme_manager.dart';

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

  runApp(MyApp(token: token));
}

class MyApp extends StatelessWidget {
  final String? token;

  const MyApp({super.key, this.token});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeManager(),
      builder: (context, _) => MaterialApp(
        title: 'Flutter Demo',
        theme: ThemeManager().themeData,
        home: const LauncherPage(),
      ),
    );
  }
}
