class UserModel {
  final String? nickname;
  final String? avatarUrl;
  final Map<String, dynamic> rawData;

  UserModel({
    this.nickname,
    this.avatarUrl,
    required this.rawData,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    return UserModel(
      nickname: json['nickname'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      rawData: json,
    );
  }

  // 获取任意字段
  dynamic get(String key) => rawData[key];
}
