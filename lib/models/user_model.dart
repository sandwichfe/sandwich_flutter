class User {
  final String nickname;
  final String avatarUrl;

  User({required this.nickname, required this.avatarUrl});

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      nickname: json['nickname'],
      avatarUrl: json['avatarUrl'],
    );
  }
}
