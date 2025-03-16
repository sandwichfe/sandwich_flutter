class ApiConstants {
  // Base URL
  static const String baseUrl = 'http://49.235.149.110:9088';
  
  // API端点
  static const String loginEndpoint = '/user/login';
  static const String userInfoEndpoint = '/sys/user/current';
  static const String logoutEndpoint = '/user/logout';

  // QR码相关常量
  static const String qrCodePrefix = 'http://49.235.149.110:9088/user/qrCode/scan?qrCodeId=';
  static const String qrCodeConsentEndpoint = '/user/qrCode/consent';

  // 完整URL
  static String getLoginUrl() => '$baseUrl$loginEndpoint';
  static String getUserInfoUrl() => '$baseUrl$userInfoEndpoint';
  static String getLogoutUrl() => '$baseUrl$logoutEndpoint';
  static String qrCodeConsentUrl() => '$baseUrl$qrCodeConsentEndpoint';

  // QR码同意URL
  static String getQrCodeConsentUrl() => '$baseUrl$qrCodeConsentEndpoint';
}

class AppConstants {
  static const String appName = 'Flutter Demo';
  static const String welcomeMessage = '欢迎使用';
  static const String useTopButtons = '请使用右上角的按钮登录或扫描';
  static const String noScanResult = 'No scan yet';
} 