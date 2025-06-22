import 'package:flutter/material.dart';

import 'pages/login_page.dart';
import 'pages/scanner_page.dart';
import 'services/api_service.dart';
import 'utils/constants.dart';
import 'utils/storage_util.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 初始化本地存储
  await StorageUtil.init();
  
  // 获取保存的baseUrl并设置
  String? savedBaseUrl = StorageUtil.getBaseUrl();
  if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
    ApiConstants.setBaseUrl(savedBaseUrl);
  }
  
  // 获取保存的token
  String? token = StorageUtil.getToken();
  print('token is $token');
  
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
      home: MyHomePage(title: 'Flutter Demo Home Page', token: token),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title, this.token});

  final String title;
  final String? token;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  String _scanResult = 'No scan yet';
  Map<String, dynamic>? _userInfo;
  bool _isLoading = true;
  bool get _isLoggedIn => widget.token != null;

  @override
  void initState() {
    super.initState();
    if (_isLoggedIn) {
      _fetchUserInfo();
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchUserInfo() async {
    try {
      final apiResponse = await ApiService().getUserInfo();
      print('apiResponse is $apiResponse');
      if (apiResponse.code == 200) {
        setState(() {
          _userInfo = apiResponse.data;
          _isLoading = false;
        });
      } else if (apiResponse.code == 401) {
        // 未登录或token失效，清除登录状态
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录已过期，请重新登录')),
          );
        }
      } else {
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('获取用户信息失败: ${apiResponse.msg}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('网络错误: $e')),
        );
      }
    }
  }

  void _scanBarcode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ScannerPage(
          onDetect: (String value) {
            setState(() {
              _scanResult = value;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('扫描结果: $value')),
            );
          },
        ),
      ),
    );
  }

  void _navigateToLogin() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const LoginPage(),
      ),
    ).then((_) {
      // 登录成功后，重新获取用户信息
      if (_isLoggedIn) {
        _fetchUserInfo();
      }
    });
  }

  void _showSettingsDialog() {
    final TextEditingController _controller = TextEditingController(text: ApiConstants.baseUrl);

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('设置服务器地址'),
          content: TextField(
            controller: _controller,
            decoration: const InputDecoration(hintText: 'http://example.com'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final newUrl = _controller.text.trim();
                if (newUrl.isNotEmpty) {
                  ApiConstants.setBaseUrl(newUrl);
                  StorageUtil.saveBaseUrl(newUrl); // 保存到本地
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('地址已保存')),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('地址不能为空')),
                  );
                }
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  void _logout() {
    ApiService().logout().then((_) {
      // 重启应用以清除状态
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const MyApp(token: null),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          if (_isLoggedIn)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: '退出登录',
              onPressed: _logout,
            )
          else
            TextButton(
              onPressed: _navigateToLogin,
              child: const Text(
                '登录',
                style: TextStyle(color: Colors.white),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanBarcode,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isLoggedIn
              ? Center(
                  child: _userInfo == null
                      ? const Text('未能获取用户信息')
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('欢迎回来, ${_userInfo!['nickname']}'),
                            const SizedBox(height: 20),
                            if (_userInfo!.containsKey('avatarUrl') && _userInfo!['avatarUrl'] != null)
                              Image.network(_userInfo!['avatarUrl']),
                          ],
                        ),
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      const SizedBox(height: 40),
                      const Text('欢迎使用'),
                      const SizedBox(height: 20),
                      const Text('请使用右上角的按钮登录或扫描'),
                      const SizedBox(height: 20),
                      if (_scanResult != 'No scan yet') ...[
                        const Text('扫描结果:'),
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(
                            _scanResult,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }
}
