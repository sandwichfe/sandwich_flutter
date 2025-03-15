import 'package:flutter/material.dart';
import '../services/api_service.dart';
import 'login_page.dart';
import 'scanner_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  Map<String, dynamic>? _userInfo;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchUserInfo();
  }

  Future<void> _fetchUserInfo() async {
    try {
      final apiResponse = await ApiService().getUserInfo();

      if (apiResponse.code == 200) {
        setState(() {
          _userInfo = apiResponse.data;
          _isLoading = false;
        });
      } else if (apiResponse.code == 401) {
        // 未登录或token失效，返回登录页
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (context) => const LoginPage(),
          ),
        );
      } else {
        setState(() {
          _isLoading = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取用户信息失败: ${apiResponse.msg}')),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('网络错误: $e')),
      );
    }
  }

  void _scanBarcode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ScannerPage(
          onDetect: (String value) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('扫描结果: $value')),
            );
          },
        ),
      ),
    );
  }

  void _navigateToLogin() {
    ApiService().logout().then((_) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const LoginPage(),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('主页面'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: '退出登录',
            onPressed: _navigateToLogin,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanBarcode,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Center(
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
            ),
    );
  }
} 