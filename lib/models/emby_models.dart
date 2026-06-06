class EmbyConfig {
  String server;
  String userId;
  String token;
  String deviceId;
  bool isJellyfin;

  EmbyConfig({
    this.server = '',
    this.userId = '',
    this.token = '',
    this.deviceId = '',
    this.isJellyfin = false,
  });
}

class EmbyLibrary {
  final String id;
  final String name;
  final String collectionType;

  const EmbyLibrary({required this.id, required this.name, required this.collectionType});

  factory EmbyLibrary.fromJson(Map<String, dynamic> json) => EmbyLibrary(
        id: json['Id'] ?? '',
        name: json['Name'] ?? '',
        collectionType: json['CollectionType'] ?? '',
      );
}

class EmbyItem {
  final String id;
  final String name;
  final String overview;
  final int runTimeTicks;
  final String? seriesName;
  final int? indexNumber;
  final bool isFavorite;

  const EmbyItem({
    required this.id,
    required this.name,
    this.overview = '',
    this.runTimeTicks = 0,
    this.seriesName,
    this.indexNumber,
    this.isFavorite = false,
  });

  factory EmbyItem.fromJson(Map<String, dynamic> json) => EmbyItem(
        id: json['Id'] ?? '',
        name: json['Name'] ?? '',
        overview: json['Overview'] ?? '',
        runTimeTicks: json['RunTimeTicks'] ?? 0,
        seriesName: json['SeriesName'],
        indexNumber: json['IndexNumber'],
        isFavorite: json['UserData']?['IsFavorite'] ?? false,
      );

  EmbyItem copyWith({bool? isFavorite}) => EmbyItem(
        id: id,
        name: name,
        overview: overview,
        runTimeTicks: runTimeTicks,
        seriesName: seriesName,
        indexNumber: indexNumber,
        isFavorite: isFavorite ?? this.isFavorite,
      );

  Duration get duration => Duration(microseconds: runTimeTicks ~/ 10);

  String get durationLabel {
    final d = duration;
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
