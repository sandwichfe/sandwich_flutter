class ApiConstants {
  // 基础URL
  static const String baseUrl = 'http://49.235.149.110:9088';
  
  // API端点
  static const String loginEndpoint = '/user/login';
  static const String userInfoEndpoint = '/sys/user/current';
  static const String qrCodeScanEndpoint = '/user/qrCode/scan';
  static const String qrCodeConsentEndpoint = '/user/qrCode/consent';
  
  // 完整API URL
  static String loginUrl = '$baseUrl$loginEndpoint';
  static String userInfoUrl = '$baseUrl$userInfoEndpoint';
  static String qrCodeConsentUrl = '$baseUrl$qrCodeConsentEndpoint';
  
  // QR前缀
  static const String qrCodePrefix = 'http://49.235.149.110:9088/user/qrCode/scan?qrCodeId=';
} 