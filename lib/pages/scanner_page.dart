import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../utils/constants.dart';
import '../services/api_service.dart';
import 'confirm_login_page.dart';

class ScannerPage extends StatefulWidget {
  final Function(String) onDetect;
  
  const ScannerPage({Key? key, required this.onDetect}) : super(key: key);
  
  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool hasScanned = false;
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描二维码'),
      ),
      body: MobileScanner(
        onDetect: (capture) async {
          final List<Barcode> barcodes = capture.barcodes;
          if (!hasScanned && barcodes.isNotEmpty && barcodes[0].rawValue != null) {
            setState(() {
              hasScanned = true; // 标记已扫描并更新状态
            });
            
            String value = barcodes[0].rawValue!;
            
            // 判断是否是有效的二维码URL
            if (value.startsWith(ApiConstants.qrCodePrefix)) {
              try {
                final apiResponse = await ApiService().processQrCode(value);
                
                if (apiResponse.code == 200 && apiResponse.data != null) {
                  if (mounted) {  // 检查组件是否仍然挂载
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (context) => ConfirmLoginPage(
                          qrCodeUrl: value,
                          qrCodeTicket: apiResponse.data!['qrCodeTicket'],
                        ),
                      ),
                    );
                  }
                } else {
                  if (mounted) {  // 检查组件是否仍然挂载
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('获取二维码信息失败: ${apiResponse.msg}')),
                    );
                  }
                }
              } catch (e) {
                if (mounted) {  // 检查组件是否仍然挂载
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('网络错误: $e')),
                  );
                }
              }
            } else {
              // 普通二维码内容，直接回传
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted) {  // 检查组件是否仍然挂载
                  widget.onDetect(value);
                }
              });
            }
          }
        },
      ),
    );
  }
}
