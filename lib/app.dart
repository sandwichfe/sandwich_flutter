import 'package:flutter/material.dart';
import 'pages/emby-pc/emby_pc_page.dart';

class MyApp extends StatelessWidget {
  final String? token;

  const MyApp({super.key, this.token});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // 备用应用入口也直接进入 EmbyPc，会话状态由入口页统一处理。
      home: const EmbyPcEntryPage(),
    );
  }
}
