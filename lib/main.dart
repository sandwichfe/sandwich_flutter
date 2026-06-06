import 'package:flutter/material.dart';

import 'pages/launcher_page.dart';
import 'services/emby_service.dart';
import 'utils/constants.dart';
import 'utils/storage_util.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await StorageUtil.init();
  await EmbyService().loadFromStorage();

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
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const LauncherPage(),
    );
  }
}