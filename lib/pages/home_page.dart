import 'package:flutter/material.dart';
import '../app.dart';
import '../services/api_service.dart';
import '../utils/constants.dart';
import '../models/user_model.dart';
import 'login_page.dart';
import 'scanner_page.dart';

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title, this.token});

  final String title;
  final String? token;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
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
      setState(() {
        _isLoading = false;
      });
    }
  }

  // 获取用户信息
  Future<void> _fetchUserInfo() async {
    try {
      final apiResponse = await ApiService().getUserInfo();

      if (apiResponse.code == 200) {
        setState(() {
          _userModel = UserModel.fromJson(apiResponse.data!);
          _isLoading = false;
        });
      } else if (apiResponse.code == 401) {
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          _showMessage('登录已过期，请重新登录');
        }
      } else {
        setState(() {
          _isLoading = false;
        });
        if (mounted) {
          _showMessage('获取用户信息失败: ${apiResponse.msg}');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _showMessage('网络错误: $e');
      }
    }
  }

  // 扫描二维码
  void _scanBarcode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ScannerPage(
          onDetect: (String value) {
            setState(() {
              _scanResult = value;
            });
            _showMessage('扫描结果: $value');
          },
        ),
      ),
    );
  }

  // 导航到登录页
  void _navigateToLogin() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const LoginPage(),
      ),
    );
  }

  // 退出登录
  void _logout() {
    ApiService().logout().then((_) {
      // 不要导入app.dart，直接使用main.dart的功能
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => const MyHomePage(title: 'Flutter Demo Home Page', token: null),
        ),
        (route) => false,
      );
    });
  }

  // 显示消息
  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: _buildAppBarActions(),
      ),
      body: _buildBody(),
    );
  }

  // 构建AppBar按钮
  List<Widget> _buildAppBarActions() {
    return [
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
    ];
  }

  // 构建主体内容
  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    } else if (_isLoggedIn) {
      return _buildLoggedInView();
    } else {
      return _buildLoggedOutView();
    }
  }

  // 已登录视图
  Widget _buildLoggedInView() {
    return Center(
      child: _userModel == null
          ? const Text('未能获取用户信息')
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('欢迎回来, ${_userModel!.nickname ?? "用户"}'),
                const SizedBox(height: 20),
                if (_userModel!.avatarUrl != null)
                  Image.network(_userModel!.avatarUrl!),
              ],
            ),
    );
  }

  // 未登录视图
  Widget _buildLoggedOutView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const SizedBox(height: 40),
          const Text(AppConstants.welcomeMessage),
          const SizedBox(height: 20),
          const Text(AppConstants.useTopButtons),
          const SizedBox(height: 20),
          if (_scanResult != AppConstants.noScanResult) ...[
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
    );
  }
} 