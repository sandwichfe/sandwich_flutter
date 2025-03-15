import 'package:json_annotation/json_annotation.dart';
import 'package:intl/intl.dart'; // 确保正确导入 intl 包

part 'api_response.g.dart';

@JsonSerializable(genericArgumentFactories: true)
class ApiResponse<T> {
  @JsonKey(name: 'code')
  int code;

  @JsonKey(name: 'msg')
  String msg;

  @JsonKey(name: 'data')
  T? data;

  @JsonKey(name: 'time')
  String time;

  ApiResponse({
    required this.code,
    required this.msg,
    this.data,
    String? time,
  }) : time = time ?? DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

  factory ApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(Object? json) fromJsonT,
  ) =>
      _$ApiResponseFromJson(json, fromJsonT);

  Map<String, dynamic> toJson(Object Function(T value) toJsonT) =>
      _$ApiResponseToJson(this, toJsonT);
}

@JsonSerializable()
class User {
  User({
    this.name,
    this.email,
    this.userId,
  });

  String? name;
  String? email;
  @JsonValue("user_id")
  String? userId;


  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);

  Map<String, dynamic> toJson() => _$UserToJson(this);
}