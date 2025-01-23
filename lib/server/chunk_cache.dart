import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as path;
import 'package:logging/logging.dart';

class ChunkCache {
  static final Logger _logger = Logger('ChunkCache');
  static const int chunkSize = 5 * 1024 * 1024; // 5MB
  final String cachePath;

  ChunkCache(this.cachePath);

  Future<void> initialize() async {
    final dir = Directory(cachePath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      _logger.fine('Created chunk cache directory at $cachePath');
    }
  }

  Future<void> writeChunk(List<int> data, int startByte) async {
    final chunkIndex = startByte ~/ chunkSize;
    final chunkPath = _getChunkPath(chunkIndex);
    _logger.fine('Writing chunk $chunkIndex (${data.length} bytes) to $chunkPath');
    
    try {
      final file = File(chunkPath);
      await file.writeAsBytes(data, mode: FileMode.writeOnly);
      _logger.finer('Successfully wrote chunk $chunkIndex (${data.length} bytes)');
    } catch (e, stackTrace) {
      _logger.severe('Failed to write chunk $chunkIndex', e, stackTrace);
      rethrow;
    }
  }

  Future<List<int>> readChunk(int chunkIndex) async {
    final chunkPath = _getChunkPath(chunkIndex);
    final file = File(chunkPath);
    
    if (await file.exists()) {
      return await file.readAsBytes();
    }
    
    throw Exception('Chunk $chunkIndex not found');
  }

  Future<List<int>> readRange(int startByte, int endByte) async {
    final startChunk = startByte ~/ chunkSize;
    final endChunk = endByte ~/ chunkSize;
    final result = <int>[];
    
    for (var i = startChunk; i <= endChunk; i++) {
      try {
        final chunkData = await readChunk(i);
        final chunkStart = i * chunkSize;
        final chunkEnd = min((i + 1) * chunkSize, endByte);
        
        final startOffset = max(0, startByte - chunkStart);
        final endOffset = min(chunkData.length, endByte - chunkStart);
        
        result.addAll(chunkData.sublist(startOffset, endOffset));
      } catch (e) {
        _logger.warning('Failed to read chunk $i: $e');
        break;
      }
    }
    
    return result;
  }

  String _getChunkPath(int chunkIndex) {
    return path.join(cachePath, 'chunk_${chunkIndex.toString().padLeft(6, '0')}.dat');
  }

  Future<int> getTotalChunks() async {
    final dir = Directory(cachePath);
    if (!await dir.exists()) return 0;
    
    final files = await dir.list().where((entity) => entity is File).toList();
    return files.length;
  }
}