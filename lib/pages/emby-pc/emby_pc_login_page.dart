import 'package:flutter/material.dart';

import 'emby_pc_service.dart';

class EmbyPcLoginPage extends StatefulWidget {
  final VoidCallback onLogin;

  const EmbyPcLoginPage({super.key, required this.onLogin});

  @override
  State<EmbyPcLoginPage> createState() => _EmbyPcLoginPageState();
}

class _EmbyPcLoginPageState extends State<EmbyPcLoginPage> {
  final _serverController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _rememberPassword = false;
  bool _passwordVisible = false;
  bool _loading = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _restoreSavedLogin();
  }

  // 登录页只恢复用户主动保存的账号信息，会话恢复由入口页负责。
  Future<void> _restoreSavedLogin() async {
    final saved = await EmbyPcService.instance.readSavedLogin();
    if (!mounted) return;
    setState(() {
      _serverController.text = saved.serverUrl;
      _usernameController.text = saved.username;
      _passwordController.text = saved.password;
      _rememberPassword = saved.rememberPassword;
    });
  }

  Future<void> _login() async {
    if (_serverController.text.trim().isEmpty ||
        _usernameController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      setState(() => _error = '请填写服务器地址、用户名和密码');
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      await EmbyPcService.instance.login(
        server: _serverController.text,
        username: _usernameController.text,
        password: _passwordController.text,
        rememberPassword: _rememberPassword,
      );
      if (mounted) widget.onLogin();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      body: ColoredBox(
        color: colors.surfaceContainerLowest,
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 430),
                  child: Material(
                    color: colors.surface,
                    elevation: 10,
                    shadowColor: Colors.black26,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: AutofillGroup(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  Icons.play_circle_fill_rounded,
                                  color: colors.primary,
                                  size: 36,
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  'Emby',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.headlineSmall?.copyWith(
                                    // 登录页品牌标题与桌面端其它标题保持统一字体。
                                    fontFamily: 'Microsoft YaHei UI',
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 28),
                            TextField(
                              controller: _serverController,
                              enabled: !_loading,
                              autofillHints: const [AutofillHints.url],
                              decoration: const InputDecoration(
                                labelText: '服务器地址',
                                hintText: 'http://localhost:8096',
                                prefixIcon: Icon(Icons.dns_outlined),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _usernameController,
                              enabled: !_loading,
                              autofillHints: const [AutofillHints.username],
                              decoration: const InputDecoration(
                                labelText: '用户名',
                                prefixIcon: Icon(Icons.person_outline),
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _passwordController,
                              enabled: !_loading,
                              obscureText: !_passwordVisible,
                              autofillHints: const [AutofillHints.password],
                              onSubmitted: (_) => _loading ? null : _login(),
                              decoration: InputDecoration(
                                labelText: '密码',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  tooltip: _passwordVisible ? '隐藏密码' : '显示密码',
                                  onPressed:
                                      _loading
                                          ? null
                                          : () => setState(
                                            () =>
                                                _passwordVisible =
                                                    !_passwordVisible,
                                          ),
                                  icon: Icon(
                                    _passwordVisible
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                  ),
                                ),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 8),
                            CheckboxListTile(
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: const Text('记住密码'),
                              value: _rememberPassword,
                              onChanged:
                                  _loading
                                      ? null
                                      : (value) => setState(
                                        () =>
                                            _rememberPassword = value ?? false,
                                      ),
                            ),
                            if (_error.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                _error,
                                style: TextStyle(color: colors.error),
                              ),
                            ],
                            const SizedBox(height: 18),
                            FilledButton.icon(
                              onPressed: _loading ? null : _login,
                              icon:
                                  _loading
                                      ? const SizedBox.square(
                                        dimension: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                      : const Icon(Icons.login),
                              label: Text(_loading ? '正在登录' : '登录'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
