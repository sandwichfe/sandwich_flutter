import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/emby_service.dart';
import 'emby_home_page.dart';

class EmbyLoginPage extends StatefulWidget {
  const EmbyLoginPage({super.key});

  @override
  State<EmbyLoginPage> createState() => _EmbyLoginPageState();
}

class _EmbyLoginPageState extends State<EmbyLoginPage> {
  final _serverCtrl = TextEditingController(text: 'http://');
  final _userCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  bool _loading = false;
  bool _pwVisible = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final server = prefs.getString('emby_server');
    final user = prefs.getString('emby_user');
    final pw = prefs.getString('emby_pw');
    if (server != null) _serverCtrl.text = server;
    if (user != null) _userCtrl.text = user;
    if (pw != null) _pwCtrl.text = pw;
  }

  Future<void> _login() async {
    setState(() { _loading = true; _error = null; });
    try {
      await EmbyService().login(_serverCtrl.text.trim(), _userCtrl.text.trim(), _pwCtrl.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('emby_server', _serverCtrl.text.trim());
      await prefs.setString('emby_user', _userCtrl.text.trim());
      await prefs.setString('emby_pw', _pwCtrl.text);
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const EmbyHomePage()),
        );
      }
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('EmbyX', style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              const SizedBox(height: 40),
              _field(_serverCtrl, '服务器地址', hint: 'http://192.168.1.1:8096'),
              const SizedBox(height: 12),
              _field(_userCtrl, '用户名'),
              const SizedBox(height: 12),
              _pwField(),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loading ? null : _login,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _loading ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2) : const Text('登录', style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pwField() {
    return TextField(
      controller: _pwCtrl,
      obscureText: !_pwVisible,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: '密码',
        labelStyle: const TextStyle(color: Colors.grey),
        enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
        focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.green)),
        suffixIcon: IconButton(
          icon: Icon(_pwVisible ? Icons.visibility_off : Icons.visibility, color: Colors.grey),
          onPressed: () => setState(() => _pwVisible = !_pwVisible),
        ),
      ),
    );
  }

  Widget _field(TextEditingController ctrl, String label, {String? hint}) {
    return TextField(
      controller: ctrl,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: const TextStyle(color: Colors.grey),
        hintStyle: const TextStyle(color: Colors.grey),
        enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.grey)),
        focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: Colors.green)),
      ),
    );
  }
}
