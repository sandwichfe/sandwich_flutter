import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';  // 导入 shared_preferences
import 'api_response.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();  // 确保 Flutter 初始化完成
  SharedPreferences prefs = await SharedPreferences.getInstance();
  String? token = prefs.getString('token');  // 读取 token
  print('token is $token');
  runApp(MyApp(token: token));  // 将 token 传递给 MyApp
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
      home: token == null ? const MyHomePage(title: 'Flutter Demo Home Page') : const MainPage(),  // 根据 token 是否存在决定首页
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  Map<String, dynamic>? _userInfo;

  @override
  void initState() {
    super.initState();
    _fetchUserInfo();
  }

  Future<void> _fetchUserInfo() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? token = prefs.getString('token');

    if (token == null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => const LoginPage(),
        ),
      );
      return;
    }

    try {
      final response = await http.get(
        Uri.parse('http://49.235.149.110:9088/sys/user/current'),
        headers: {
          'Authorization': '$token',
        },
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(utf8.decode(response.bodyBytes));
        if (responseData['code'] == 200) {
          setState(() {
            _userInfo = responseData['data'];
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('获取用户信息失败: ${responseData['msg']}')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取用户信息失败: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('网络错误: $e')),
      );
    }
  }

  void _scanBarcode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ScannerPage(
          onDetect: (String value) async {
            if (value.startsWith('http://49.235.149.110:9088/user/qrCode/scan?qrCodeId=')) {
              try {
                print('开始请求扫码接口: $value');  // 打印请求的URL
                final response = await http.get(Uri.parse(value));
                print('扫码接口返回状态码: ${response.statusCode}');  // 打印返回状态码
                if (response.statusCode == 200) {
                  final responseData = jsonDecode(utf8.decode(response.bodyBytes));
                  print('扫码接口返回数据: $responseData');  // 打印返回数据
                  if (responseData['code'] == 200) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (context) => ConfirmLoginPage(
                          qrCodeUrl: value,
                          qrCodeTicket: responseData['data']['qrCodeTicket'],
                        ),
                      ),
                    );
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('获取二维码信息失败: ${responseData['msg']}')),
                    );
                  }
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('获取二维码信息失败: ${response.statusCode}')),
                  );
                }
              } catch (e) {
                print('扫码接口请求异常: $e');  // 打印异常信息
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('网络错误: $e')),
                );
              }
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('扫描结果: $value')),
              );
            }
          },
        ),
      ),
    );
  }

  void _navigateToLogin() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => const LoginPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('主页面'),
        actions: [
          IconButton(
            icon: const Icon(Icons.login),
            onPressed: _navigateToLogin,
          ),
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: _scanBarcode,
          ),
        ],
      ),
      body: Center(
        child: _userInfo == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('欢迎回来, ${_userInfo!['nickname']}'),
                  const SizedBox(height: 20),
                  Image.network(_userInfo!['avatarUrl']),
                ],
              ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  String _scanResult = 'No scan yet';

  void _incrementCounter() {
    setState(() {
      _counter+=8;
    });
  }

  void _scanBarcode() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ScannerPage(
          onDetect: (String value) {
            setState(() {
              _scanResult = value;
            });
            Navigator.of(context).pop();
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
        actions: [
          TextButton(
            onPressed: _navigateToLogin,
            child: const Text(
              '登录',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 40),  // 添加间距
            const Text('扫描结果:'),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(
                _scanResult,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
            ElevatedButton(
              onPressed: _scanBarcode,
              child: const Text('开始扫码'),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ), // This trailing comma makes auto-formatting nicer for build methods.
    );
  }
}

class ScannerPage extends StatelessWidget {
  final Function(String) onDetect;
  
  const ScannerPage({Key? key, required this.onDetect}) : super(key: key);
  
  @override
  Widget build(BuildContext context) {
    bool hasScanned = false;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描二维码'),
      ),
      body: MobileScanner(
        onDetect: (capture) {
          final List<Barcode> barcodes = capture.barcodes;
          if (!hasScanned && barcodes.isNotEmpty && barcodes[0].rawValue != null) {
            hasScanned = true; // 标记已扫描
            
            Future.delayed(const Duration(milliseconds: 500), () {
              onDetect(barcodes[0].rawValue!);
            });
          }
        },
      ),
    );
  }
}

class ConfirmLoginPage extends StatelessWidget {
  final String qrCodeUrl;
  final String qrCodeTicket;

  const ConfirmLoginPage({Key? key, required this.qrCodeUrl, required this.qrCodeTicket}) : super(key: key);

  Future<void> _confirmLogin(BuildContext context) async {
    // 解析 qrCodeUrl 获取 qrCodeId
    Uri uri = Uri.parse(qrCodeUrl);
    String qrCodeId = uri.queryParameters['qrCodeId'] ?? '';

    if (qrCodeId.isEmpty || qrCodeTicket.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('二维码信息不完整')),
      );
      return;
    }

    try {
      SharedPreferences prefs = await SharedPreferences.getInstance();
      String? token = prefs.getString('token');

      final requestBody = {
        'qrCodeId': qrCodeId,
        'qrCodeTicket': qrCodeTicket,
      };
      print('开始请求确认登录接口, 请求参数: $requestBody');  // 打印请求参数
      final response = await http.post(
        Uri.parse('http://49.235.149.110:9088/user/qrCode/consent'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': '$token',  // 添加 Authorization 请求头
        },
        body: jsonEncode(requestBody),
      );
      print('确认登录接口返回状态码: ${response.statusCode}');  // 打印返回状态码
      if (response.statusCode == 200) {
        final responseData = jsonDecode(utf8.decode(response.bodyBytes));
        print('确认登录接口返回数据: $responseData');  // 打印返回数据
        if (responseData['code'] == 200) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录成功')),
          );
          Navigator.of(context).pop();
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('登录失败: ${responseData['msg']}')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录失败: ${response.statusCode}')),
        );
      }
    } catch (e) {
      print('确认登录接口请求异常: $e');  // 打印异常信息
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('网络错误: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('确认登录'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('您正在尝试登录'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _confirmLogin(context),
              child: const Text('确认登录'),
            ),
          ],
        ),
      ),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({Key? key}) : super(key: key);

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isLoading = false;

  Future<void> _saveToken(String token) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('token', token);  // 存储 token
  }

  Future<void> _login() async {
    final username = _usernameController.text;
    final password = _passwordController.text;

    if (username.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('用户名和密码不能为空')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final response = await http.post(
        Uri.parse('http://49.235.149.110:9088/user/login'),
        body: {
          'username': username,
          'password': password,
        },
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(utf8.decode(response.bodyBytes));
        final apiResponse = ApiResponse.fromJson(
          responseData,
          (dynamic json) => json != null && json is Map<String, dynamic> ? json : <String, dynamic>{},
        );
        print(apiResponse);
        if (apiResponse.code == 200) {
          String token =responseData?['data'] as String;
          await _saveToken(token);  // 保存 token

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('登录成功: ${responseData['message'] ?? "欢迎回来"}')),
          );

          Navigator.of(context).pushReplacement(MaterialPageRoute(
            builder: (context) => const MainPage(),  // 跳转到主页面
          ));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('登录失败: ${apiResponse.msg}')),
          );
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录失败: ${response.statusCode}')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('网络错误: $e')),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('用户登录'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(
                labelText: '用户名',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _login,
                child: _isLoading 
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('登录', style: TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
