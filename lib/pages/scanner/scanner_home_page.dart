import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import '../../utils/constants.dart';
import '../../models/user_model.dart';
import '../scanner/scanner_page.dart';
import 'scanner_login_page.dart';

class ScannerHomePage extends StatefulWidget {
  const ScannerHomePage({super.key, required this.title, this.token});

  final String title;
  final String? token;

  @override
  State<ScannerHomePage> createState() => _ScannerHomePageState();
}

class _ScannerHomePageState extends State<ScannerHomePage> {
  String _scanResult = AppConstants.noScanResult;
  UserModel? _userModel;
  bool _isLoading = true;
  bool get _isLoggedIn => widget.token != null;

  @override
  void initState() {
    super.initState();
    if (_isLoggedIn) {
      _fetchUserInfo();
    } else {
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _fetchUserInfo() async {
    try {
      final apiResponse = await ApiService().getUserInfo();
      if (apiResponse.code == 200) {
        setState(() { _userModel = UserModel.fromJson(apiResponse.data!); _isLoading = false; });
      } else if (apiResponse.code == 401) {
        setState(() { _isLoading = false; });
        if (mounted) _showMessage('登录已过期，请重新登录');
      } else {
        setState(() { _isLoading = false; });
        if (mounted) _showMessage('获取用户信息失败: ${apiResponse.msg}');
      }
    } catch (e) {
      if (mounted) { setState(() { _isLoading = false; }); _showMessage('网络错误: $e'); }
    }
  }

  void _scanBarcode() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (context) => ScannerPage(
        onDetect: (String value) {
          setState(() { _scanResult = value; });
          _showMessage('扫描结果: $value');
        },
      ),
    ));
  }

  void _navigateToLogin() {
    Navigator.of(context).push(MaterialPageRoute(builder: (context) => const ScannerLoginPage()));
  }

  void _logout() {
    ApiService().logout().then((_) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const ScannerHomePage(title: 'Flutter Demo Home Page', token: null)),
        (route) => false,
      );
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          if (_isLoggedIn)
            IconButton(icon: const Icon(Icons.logout), tooltip: '退出登录', onPressed: _logout)
          else
            TextButton(onPressed: _navigateToLogin, child: const Text('登录', style: TextStyle(color: Colors.white))),
          IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: _scanBarcode),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _isLoggedIn
              ? Center(
                  child: _userModel == null
                      ? const Text('未能获取用户信息')
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text('欢迎回来, ${_userModel!.nickname ?? "用户"}'),
                            const SizedBox(height: 20),
                            if (_userModel!.avatarUrl != null) Image.network(_userModel!.avatarUrl!),
                          ],
                        ),
                )
              : Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 40),
                      const Text(AppConstants.welcomeMessage),
                      const SizedBox(height: 20),
                      const Text(AppConstants.useTopButtons),
                      const SizedBox(height: 20),
                      if (_scanResult != AppConstants.noScanResult) ...[
                        const Text('扫描结果:'),
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Text(_scanResult, style: Theme.of(context).textTheme.bodyLarge),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }
}
