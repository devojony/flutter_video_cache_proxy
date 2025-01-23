class ChunkInfo {
  final int index;
  final int start;
  final int end;
  final int size;
  final bool isComplete;

  ChunkInfo({
    required this.index,
    required this.start,
    required this.end,
    required this.size,
    this.isComplete = false,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': start,
        'end': end,
        'size': size,
        'isComplete': isComplete,
      };

  factory ChunkInfo.fromJson(Map<String, dynamic> json) => ChunkInfo(
        index: json['index'] as int,
        start: json['start'] as int,
        end: json['end'] as int,
        size: json['size'] as int,
        isComplete: json['isComplete'] as bool,
      );
} 