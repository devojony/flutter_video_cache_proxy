// ignore_for_file: unused_element

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' hide log;
import 'dart:developer' show log;

import 'package:crypto/crypto.dart';

class CacheFile {
  late String id;
  late int totalSize;
  static String rootPath = "";
  late String url;
  late Directory dir;
  late int chunkCount;
  late int _chunkSize;

  CacheFile.fromUrl({required String src}) {
    url = src;
    CacheFile(id: generateName(src));
  }

  CacheFile({required this.id}) {
    dir = Directory("$rootPath/$id");

    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final metadataFile = File("$dir/metadata.json");

    if (metadataFile.existsSync()) {
      final metadata = jsonDecode(metadataFile.readAsStringSync());
      totalSize = metadata['totalSize'] as int;
      chunkCount = metadata['chunkCount'] as int;
      _chunkSize = metadata['chunkSize'] as int;
      final tempUrl = metadata['url'] as String;
      if (tempUrl != url) {
        log("url 不一致, 更新 url 为 metadata 内的内容", level: 900);
      }
      url = tempUrl;
    } else {
      totalSize = 0;
      chunkCount = 0;
      _chunkSize = 5 * 1024 * 1024; // 5MB
      url = '';
    }
  }

  Stream<List<int>> read({int start = 0, int? end}) async* {
    final s = start;
    final e = end ?? totalSize;
    if (s < 0 || e > totalSize || s >= e) {
      throw ArgumentError('Invalid range: start=$start, end=$end');
    }

    var currentPos = s;

    while (currentPos < e) {
      try {
        final chunkIndex = currentPos ~/ _chunkSize;
        final chunkStart = currentPos - (chunkIndex * _chunkSize);
        final chunkFile = File('$rootPath/$id/chunk_$chunkIndex');

        if (!chunkFile.existsSync()) {
          throw Exception('Chunk file not found: chunk_$chunkIndex');
        }

        final bytesToRead = min(e - currentPos, _chunkSize - chunkStart).toInt();
        if (bytesToRead <= 0) {
          throw Exception('Invalid read range: start=$chunkStart, end=$e');
        }

        await for (final data in chunkFile.openRead(chunkStart, chunkStart + bytesToRead)) {
          yield data;
        }
        currentPos += bytesToRead;

        // If we've reached the end of this chunk but not the end of the requested range,
        // continue with the next chunk
        if (chunkStart + bytesToRead == _chunkSize && currentPos < e) {
          continue;
        }
      } catch (e) {
        throw Exception('Failed to read chunk: $e');
      }
    }
  }

  static String generateName(String value) {
    return md5.convert(utf8.encode(value)).toString();
  }

  Future<void> save() async {
    final metadataFile = File("$dir/metadata.json");

    // Calculate actual chunk count
    final chunkFiles =
        dir.listSync().where((file) => file.path.contains('chunk_') && !file.path.endsWith('.temp')).length;

    final metadata = {
      'totalSize': totalSize,
      'chunkCount': chunkFiles,
      'chunkSize': _chunkSize,
      'url': url,
    };

    try {
      await metadataFile.writeAsString(jsonEncode(metadata));
    } catch (e) {
      throw Exception('Failed to save metadata: $e');
    }
  }

  Future<void> write(List<int> data, {int offset = 0}) async {
    if (data.isEmpty) return;

    var remainingBytes = data.length;
    var currentOffset = offset;
    var chunkIndex = currentOffset ~/ _chunkSize;

    while (remainingBytes > 0) {
      final chunkStart = currentOffset % _chunkSize;
      final bytesToWrite = min(remainingBytes, _chunkSize - chunkStart);
      final tempChunkFile = File('$rootPath/$id/chunk_$chunkIndex.temp');
      final chunkFile = File('$rootPath/$id/chunk_$chunkIndex');

      try {
        if (chunkStart == 0 && bytesToWrite == _chunkSize) {
          // Write full chunk to temp file
          await tempChunkFile.writeAsBytes(data.sublist(currentOffset - offset, currentOffset - offset + bytesToWrite));
        } else {
          // Rebuild chunk file
          final newData = List<int>.filled(_chunkSize, 0);
          newData.setRange(chunkStart, chunkStart + bytesToWrite,
              data.sublist(currentOffset - offset, currentOffset - offset + bytesToWrite));
          await tempChunkFile.writeAsBytes(newData);
        }

        // Rename temp file to final name
        if (tempChunkFile.existsSync()) {
          if (chunkFile.existsSync()) {
            await chunkFile.delete();
          }
          await tempChunkFile.rename(chunkFile.path);
        }

        currentOffset += bytesToWrite;
        remainingBytes -= bytesToWrite;
        chunkIndex++;

        // Update metadata
        totalSize = max(totalSize, currentOffset);
      } catch (e) {
        throw Exception('Failed to write chunk $chunkIndex: $e');
      }
    }
    await save();
  }

  Future<void> writeStream(Stream<List<int>> stream) async {
    var chunkIndex = 0;
    var currentOffset = 0;
    var buffer = <int>[];
    var isFirstChunk = true;

    await for (final data in stream) {
      if (data.isEmpty) continue;

      buffer.addAll(data);

      while (buffer.length >= _chunkSize) {
        final chunkData = buffer.sublist(0, _chunkSize);
        buffer = buffer.sublist(_chunkSize);

        final tempChunkFile = File('$rootPath/$id/chunk_$chunkIndex.temp');
        final chunkFile = File('$rootPath/$id/chunk_$chunkIndex');

        try {
          // Delete existing chunk file if it's not the first chunk
          if (!isFirstChunk && chunkFile.existsSync()) {
            await chunkFile.delete();
          }

          await tempChunkFile.writeAsBytes(chunkData);
          if (tempChunkFile.existsSync()) {
            await tempChunkFile.rename(chunkFile.path);
          }

          currentOffset += _chunkSize;
          chunkIndex++;
          isFirstChunk = false;
        } catch (e) {
          // Clean up temp file if error occurs
          if (tempChunkFile.existsSync()) {
            await tempChunkFile.delete();
          }
          throw Exception('Failed to write chunk $chunkIndex: $e');
        }
      }
    }

    // Write remaining data
    if (buffer.isNotEmpty) {
      final tempChunkFile = File('$rootPath/$id/chunk_$chunkIndex.temp');
      final chunkFile = File('$rootPath/$id/chunk_$chunkIndex');

      try {
        // Pad buffer to _chunkSize if needed
        if (buffer.length < _chunkSize) {
          buffer = List<int>.from(buffer)..addAll(List.filled(_chunkSize - buffer.length, 0));
        }

        await tempChunkFile.writeAsBytes(buffer);
        if (tempChunkFile.existsSync()) {
          if (chunkFile.existsSync()) {
            await chunkFile.delete();
          }
          await tempChunkFile.rename(chunkFile.path);
        }

        currentOffset += buffer.length;
      } catch (e) {
        // Clean up temp file if error occurs
        if (tempChunkFile.existsSync()) {
          await tempChunkFile.delete();
        }
        throw Exception('Failed to write final chunk $chunkIndex: $e');
      }
    }

    // Update metadata
    totalSize = max(totalSize, currentOffset);
    chunkCount = max(chunkCount, chunkIndex);
    await save();
  }
}
