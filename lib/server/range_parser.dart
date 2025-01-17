import 'dart:core';

class Range {
  final int start;
  final int end;

  Range(this.start, this.end);

  static Range? parse(String rangeHeader, int totalSize) {
    final regex = RegExp(r'^bytes=(\d*)-(\d*)$');
    final match = regex.firstMatch(rangeHeader);
    if (match == null) return null;

    final startStr = match.group(1);
    final endStr = match.group(2);

    int? start;
    int? end;

    if (startStr?.isNotEmpty ?? false) {
      start = int.tryParse(startStr!);
      if (start == null || start < 0 || start >= totalSize) {
        return null;
      }
    }

    if (endStr?.isNotEmpty ?? false) {
      end = int.tryParse(endStr!);
      if (end == null || end < 0 || end >= totalSize) {
        return null;
      }
    }

    if (start == null && end == null) {
      return null;
    }

    if (start == null) {
      // Case: bytes=-500 (last 500 bytes)
      start = totalSize - end!;
      end = totalSize - 1;
    } else if (end == null) {
      // Case: bytes=500- (from byte 500 to end)
      end = totalSize - 1;
    }

    if (start > end) {
      return null;
    }

    return Range(start, end + 1); // end is exclusive
  }
}