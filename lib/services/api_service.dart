import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/api_response.dart';
import '../utils/constants.dart';
import '../utils/storage_util.dart';

class ApiService {
  // 单例模式
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();
  
  // 登录
  Future<ApiResponse<String>> login(String username, String password) async {
    try {
      final response = await http.post(
        Uri.parse(ApiConstants.getLoginUrl()),
        body: {
          'username': username,
          'password': password,
        },
      );
      
      print('登录响应状态码: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final responseData = jsonDecode(utf8.decode(response.bodyBytes));
        final apiResponse = ApiResponse.fromJson(
          responseData,
          (dynamic json) => json != null && json is String ? json : '',
        );
        
        // 登录成功，保存token
        if (apiResponse.code == 200 && apiResponse.data != null) {
          await StorageUtil.saveToken(apiResponse.data as String);
        }
        
        return apiResponse;
      } else {
        return ApiResponse(
          code: response.statusCode,
          msg: 'HTTP错误: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('登录异常: $e');
      return ApiResponse(
        code: 500,
        msg: '网络错误: $e',
      );
    }
  }
  
  // 获取用户信息
  Future<ApiResponse<Map<String, dynamic>>> getUserInfo() async {
    try {
      String? token = StorageUtil.getToken();
      
      if (token == null) {
        return ApiResponse(
          code: 401,
          msg: '未登录',
        );
      }
      
      final response = await http.get(
        Uri.parse(ApiConstants.getUserInfoUrl()),
        headers: {
          'Authorization': token,
        },
      );
      
      if (response.statusCode == 200) {
        final responseData = jsonDecode(utf8.decode(response.bodyBytes));
        return ApiResponse.fromJson(
          responseData,
          (dynamic json) => json != null ? json as Map<String, dynamic> : <String, dynamic>{},
        );
      } else if (response.statusCode == 401) {
        // 未登录或token失效
        await StorageUtil.removeToken();
        return ApiResponse(
          code: 401,
          msg: '登录已过期',
        );
      } else {
        return ApiResponse(
          code: response.statusCode,
          msg: 'HTTP错误: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('获取用户信息异常: $e');
      return ApiResponse(
        code: 500,
        msg: '网络错误: $e',
      );
    }
  }
  
  // 处理二维码扫描
  Future<ApiResponse<Map<String, dynamic>>> processQrCode(String url) async {
    try {
      print('开始请求扫码接口: $url');
      final response = await http.get(Uri.parse(url));
      print('扫码接口返回状态码: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final responseData = jsonDecode(utf8.decode(response.bodyBytes));
        print('扫码接口返回数据: $responseData');
        return ApiResponse.fromJson(
          responseData,
          (dynamic json) => json != null && json is Map<String, dynamic> ? json : <String, dynamic>{},
        );
      } else {
        return ApiResponse(
          code: response.statusCode,
          msg: 'HTTP错误: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('扫码接口请求异常: $e');
      return ApiResponse(
        code: 500,
        msg: '网络错误: $e',
      );
    }
  }
  
  // 确认二维码登录
  Future<ApiResponse<dynamic>> confirmQrCodeLogin(String qrCodeId, String qrCodeTicket) async {
    try {
      String? token = StorageUtil.getToken();
      
      final requestBody = {
        'qrCodeId': qrCodeId,
        'qrCodeTicket': qrCodeTicket,
      };
      
      print('开始请求确认登录接口, 请求参数: $requestBody');
      final response = await http.post(
        Uri.parse(ApiConstants.getQrCodeConsentUrl()),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': '$token',
        },
        body: jsonEncode(requestBody),
      );
      
      print('确认登录接口返回状态码: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        final responseData = jsonDecode(utf8.decode(response.bodyBytes));
        print('确认登录接口返回数据: $responseData');
        return ApiResponse.fromJson(
          responseData,
          (dynamic json) => json,
        );
      } else {
        return ApiResponse(
          code: response.statusCode,
          msg: 'HTTP错误: ${response.statusCode}',
        );
      }
    } catch (e) {
      print('确认登录接口请求异常: $e');
      return ApiResponse(
        code: 500,
        msg: '网络错误: $e',
      );
    }
  }
  
  // 退出登录
  Future<void> logout() async {
    try {
      await StorageUtil.removeToken();
    } catch (e) {
      print('退出登录异常: $e');
    }
  }
} 