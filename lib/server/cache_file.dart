// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class CacheFile {
  static const int chunkSize = 5 * 1024 * 1024; // 5MB

  final Directory cacheDir;
  String? url;
  String? id;
  int? totalSize;
  DateTime? lastModified;

  CacheFile(String basePath, {String? url, String? id}) : cacheDir = Directory('$basePath/${id ?? getCacheId(url!)}') {
    print("CacheFile:\ncacheDir: $cacheDir\nbasePath: $basePath\n");

    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
      _saveMetadata();
    } else {
      _loadMetadata();
    }
  }

  static String getCacheId(String url) {
    return md5.convert(utf8.encode(url)).toString();
  }

  Future<void> write(String url, Stream<Uint8List> dataStream, {int start = 0}) async {
    this.url = url;
    id = getCacheId(url);
    lastModified = DateTime.now();
    totalSize = start;

    var chunkIndex = start ~/ chunkSize;
    var buffer = Uint8List(0);

    // Skip initial bytes if start position is not at chunk boundary
    if (start % chunkSize != 0) {
      try {
        final initialChunk = await _readChunk(chunkIndex);
        buffer.addAll(initialChunk.sublist(start % chunkSize));
        chunkIndex++;
      } catch (e) {
        // If chunk doesn't exist, fill with zeros up to start position
        final zerosNeeded = chunkSize - (start % chunkSize);
        buffer = Uint8List(zerosNeeded);
        chunkIndex++;
      }
    }

    await for (final chunk in dataStream) {
      buffer = Uint8List.fromList([...buffer, ...chunk]);
      totalSize = totalSize! + chunk.length;

      while (buffer.length >= chunkSize) {
        final chunkData = Uint8List.sublistView(buffer, 0, chunkSize);
        await _writeChunk(chunkData, chunkIndex);
        buffer = Uint8List.sublistView(buffer, chunkSize);
        chunkIndex++;
      }
    }

    // Write remaining data
    if (buffer.isNotEmpty) {
      await _writeChunk(buffer, chunkIndex);
      totalSize = totalSize! + buffer.length;
    }

    await _saveMetadata();
  }

  Future<int> getSize() async {
    return totalSize ?? 0;
  }

  Future<int> getRangeSize(int start, int end) async {
    if (start < 0 || end < 0 || start > end) {
      return 0;
    }

    final total = await getSize();
    if (start >= total) {
      return 0;
    }

    end = end.clamp(0, total);
    var cachedSize = 0;

    // Calculate first chunk
    final firstChunkIndex = start ~/ chunkSize;
    final firstChunkStart = firstChunkIndex * chunkSize;
    final firstChunkEnd = (firstChunkIndex + 1) * chunkSize;

    try {
      final firstChunk = await _readChunk(firstChunkIndex);
      final firstChunkRangeStart = start - firstChunkStart;
      final firstChunkRangeEnd = (end - firstChunkStart).clamp(0, firstChunk.length);
      cachedSize += firstChunkRangeEnd - firstChunkRangeStart;
    } catch (e) {
      // Chunk not found
      return 0;
    }

    // Calculate middle chunks
    var chunkIndex = firstChunkIndex + 1;
    while (chunkIndex * chunkSize < end) {
      try {
        final chunk = await _readChunk(chunkIndex);
        final chunkStart = chunkIndex * chunkSize;
        final chunkEnd = (chunkIndex + 1) * chunkSize;
        final chunkRangeEnd = (end - chunkStart).clamp(0, chunk.length);
        cachedSize += chunkRangeEnd;
        chunkIndex++;
      } catch (e) {
        break;
      }
    }

    return cachedSize;
  }

  Stream<Uint8List> read(String url, {int? start, int? end}) async* {
    if (start != null && start < 0) {
      throw ArgumentError('Start position cannot be negative');
    }
    if (end != null && end < 0) {
      throw ArgumentError('End position cannot be negative');
    }
    if (start != null && end != null && start > end) {
      throw ArgumentError('Start position cannot be greater than end position');
    }

    var chunkIndex = start != null ? start ~/ chunkSize : 0;

    while (true) {
      try {
        final chunk = await _readChunk(chunkIndex);
        final chunkStart = chunkIndex * chunkSize;
        final chunkEnd = chunkStart + chunk.length;

        // Calculate slice positions
        final sliceStart = start != null ? start - chunkStart : 0;
        final sliceEnd = end != null ? end - chunkStart : chunk.length;

        if (sliceStart < chunk.length) {
          final slice = chunk.sublist(
            sliceStart.clamp(0, chunk.length),
            sliceEnd.clamp(0, chunk.length),
          );
          yield slice;
        }

        // Stop if we've reached the end position
        if (end != null && chunkEnd >= end) {
          break;
        }

        chunkIndex++;
      } catch (e) {
        break;
      }
    }
  }

  Future<void> _writeChunk(Uint8List data, int chunkIndex) async {
    final file = File('${cacheDir.path}/chunk_$chunkIndex');
    await file.writeAsBytes(data);
  }

  Future<Uint8List> _readChunk(int chunkIndex) async {
    final file = File('${cacheDir.path}/chunk_$chunkIndex');
    if (!await file.exists()) {
      throw Exception('Chunk not found');
    }
    return await file.readAsBytes();
  }

  Future<void> _saveMetadata() async {
    final metadataFile = File('${cacheDir.path}/metadata.json');
    final metadata = {
      'url': url ?? '',
      'id': id ?? '',
      'chunkSize': chunkSize,
      'totalSize': totalSize ?? '',
      'lastModified': lastModified?.toIso8601String() ?? '',
    };
    await metadataFile.writeAsString(jsonEncode(metadata));
  }

  Future<void> _loadMetadata() async {
    final metadataFile = File('${cacheDir.path}/metadata.json');

    if (!await metadataFile.exists()) {
      throw Exception('Cache not found');
    }

    final metadata = jsonDecode(await metadataFile.readAsString());
    url = metadata['url'];
    totalSize = metadata['totalSize'];
    lastModified = DateTime.parse(metadata['lastModified']);
  }
}
