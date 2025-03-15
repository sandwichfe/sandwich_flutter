import 'package:flutter/material.dart';
import '../services/api_service.dart';

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
      final apiResponse = await ApiService().confirmQrCodeLogin(qrCodeId, qrCodeTicket);
      
      if (apiResponse.code == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录成功')),
        );
        Navigator.of(context).pop();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录失败: ${apiResponse.msg}')),
        );
      }
    } catch (e) {
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
            const Text('您正在尝试登录', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => _confirmLogin(context),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 12),
              ),
              child: const Text('确认登录', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
