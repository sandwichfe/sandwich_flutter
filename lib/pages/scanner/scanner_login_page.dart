import 'package:flutter/material.dart';
import '../../app.dart';
import '../../services/api_service.dart';

class ScannerLoginPage extends StatefulWidget {
  const ScannerLoginPage({Key? key}) : super(key: key);

  @override
  State<ScannerLoginPage> createState() => _ScannerLoginPageState();
}

class _ScannerLoginPageState extends State<ScannerLoginPage> {
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoading = false;

  Future<void> _login() async {
    final username = _usernameCtrl.text;
    final password = _passwordCtrl.text;
    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('用户名和密码不能为空')));
      return;
    }
    setState(() { _isLoading = true; });
    try {
      final apiResponse = await ApiService().login(username, password);
      if (apiResponse.code == 200) {
        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => MyApp(token: apiResponse.data as String)),
            (route) => false,
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('登录失败: ${apiResponse.msg}')));
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('网络错误: $e')));
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('用户登录')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(labelText: '用户名', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock)),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _login,
                child: _isLoading ? const CircularProgressIndicator(color: Colors.white) : const Text('登录', style: TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
