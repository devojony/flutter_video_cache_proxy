import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:path/path.dart' as path;
import '../models/chunk_info.dart';
import 'cache.dart';

class ChunkCache implements Cache {
  static const int chunkSize = 5 * 1024 * 1024; // 5MB
  static const int bufferSize = 64 * 1024; // 64KB buffer
  
  final String cacheDir;
  final String dataDir;
  final String metadataPath;
  final Map<int, ChunkInfo> chunks = {};
  int? contentLength;
  String? contentType;
  bool _isComplete = false;

  ChunkCache(this.cacheDir) : 
    dataDir = path.join(cacheDir, 'data'),
    metadataPath = path.join(cacheDir, 'metadata.json') {
    Directory(dataDir).createSync(recursive: true);
    _loadMetadata();
  }

  // 元数据管理
  void _loadMetadata() {
    final file = File(metadataPath);
    if (file.existsSync()) {
      try {
        final data = jsonDecode(file.readAsStringSync());
        _parseMetadata(data);
      } catch (e) {
        print('[${DateTime.now()}] Error loading metadata: $e');
        _resetState();
      }
    }
  }

  void _parseMetadata(Map<String, dynamic> data) {
    contentLength = data['contentLength'];
    contentType = data['contentType'];
    final List<dynamic> chunkList = data['chunks'] as List<dynamic>? ?? [];
    for (var chunk in chunkList) {
      final chunkInfo = ChunkInfo.fromJson(chunk);
      chunks[chunkInfo.index] = chunkInfo;
    }
    _updateComplete();
  }

  void _saveMetadata() {
    try {
      final data = {
        'contentLength': contentLength,
        'contentType': contentType,
        'chunks': chunks.values.map((c) => c.toJson()).toList(),
      };
      File(metadataPath).writeAsStringSync(jsonEncode(data));
    } catch (e) {
      print('[${DateTime.now()}] Error saving metadata: $e');
    }
  }

  void _resetState() {
    contentLength = null;
    contentType = null;
    chunks.clear();
    _isComplete = false;
  }

  // 缓存状态管理
  void _updateComplete() {
    if (contentLength == null) {
      _isComplete = false;
      return;
    }
    final totalChunks = (contentLength! / chunkSize).ceil();
    _isComplete = chunks.length == totalChunks && 
                 chunks.values.every((chunk) => chunk.isComplete);
  }

  String _getChunkPath(int index) => path.join(dataDir, 'chunk_$index');

  // 块写入相关
  Future<void> _writeChunk(RandomAccessFile file, BytesBuilder builder, int bytesToWrite) async {
    final chunk = builder.takeBytes();
    await file.writeFrom(chunk, 0, bytesToWrite);
    if (chunk.length > bytesToWrite) {
      builder.add(chunk.sublist(bytesToWrite));
    }
  }

  Future<void> _finalizeChunk(RandomAccessFile file, int chunkIndex, int start) async {
    await file.flush();
    await file.close();
    
    final size = await File(_getChunkPath(chunkIndex)).length();
    chunks[chunkIndex] = ChunkInfo(
      index: chunkIndex,
      start: start,
      end: start + size,
      size: size,
      isComplete: true,
    );
    print('[${DateTime.now()}] Completed chunk $chunkIndex: $size bytes (${chunks[chunkIndex]!.start}-${chunks[chunkIndex]!.end})');
  }

  // 块读取相关
  bool _isChunkAvailable(int index) {
    return chunks.containsKey(index) && 
           chunks[index]!.isComplete && 
           File(_getChunkPath(index)).existsSync();
  }

  bool _isRangeFullyCached(int start, int? end) {
    // 1. 检查元数据完整性
    if (contentLength == null) {
      print('[${DateTime.now()}] Cache miss - Content length unknown');
      return false;
    }
    if (contentType == null) {
      print('[${DateTime.now()}] Cache miss - Content type unknown');
      return false;
    }

    // 2. 验证请求范围的有效性
    if (start < 0) {
      print('[${DateTime.now()}] Cache miss - Invalid start position: $start');
      return false;
    }
    if (start >= contentLength!) {
      print('[${DateTime.now()}] Cache miss - Start position beyond content length: $start >= $contentLength');
      return false;
    }
    if (end != null) {
      if (end > contentLength!) {
        print('[${DateTime.now()}] Cache miss - End position beyond content length: $end > $contentLength');
        return false;
      }
      if (end <= start) {
        print('[${DateTime.now()}] Cache miss - Invalid range: end($end) <= start($start)');
        return false;
      }
    }

    // 3. 计算需要的块范围
    final startChunk = start ~/ chunkSize;
    final endChunk = end == null ? 
      (contentLength! - 1) ~/ chunkSize : 
      end ~/ chunkSize;
    
    print('[${DateTime.now()}] Checking chunks from $startChunk to $endChunk');

    // 4. 检查块的连续性和完整性
    var previousChunkEnd = -1;
    for (var i = startChunk; i <= endChunk; i++) {
      // 检查块是否存在且完整
      if (!_isChunkAvailable(i)) {
        print('[${DateTime.now()}] Cache miss - Chunk $i not available');
        return false;
      }
      
      final chunk = chunks[i]!;
      
      // 检查块的连续性
      if (previousChunkEnd != -1 && chunk.start != previousChunkEnd) {
        print('[${DateTime.now()}] Cache miss - Gap between chunks: ${previousChunkEnd} to ${chunk.start}');
        return false;
      }
      
      // 检查块的范围覆盖
      if (i == startChunk) {
        if (chunk.start > start) {
          print('[${DateTime.now()}] Cache miss - First chunk starts too late: ${chunk.start} > $start');
          return false;
        }
      }
      
      if (i == endChunk && end != null) {
        if (chunk.end < end) {
          print('[${DateTime.now()}] Cache miss - Last chunk ends too early: ${chunk.end} < $end');
          return false;
        }
      }
      
      previousChunkEnd = chunk.end;
    }

    print('[${DateTime.now()}] Cache hit - Range fully cached: $start to ${end ?? contentLength}');
    return true;
  }

  Future<Stream<List<int>>> _readChunkRange(int index, int start, int? end) async {
    final file = await File(_getChunkPath(index)).open();
    if (start > 0) {
      await file.setPosition(start);
    }
    
    final length = await file.length();
    final remaining = end == null ? length - start : end - start;
    
    return Stream.fromFuture(file.read(remaining.toInt()))
      .transform(StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          sink.add(data);
        },
        handleDone: (sink) async {
          await file.close();
          sink.close();
        }
      ));
  }

  // Cache 接口实现
  @override
  Future<void> write(Stream<List<int>> stream, int start, int? end) async {
    print('[${DateTime.now()}] Cache miss - Writing chunk: start=$start, end=$end');
    final startChunk = start ~/ chunkSize;
    final builder = BytesBuilder(copy: false);
    var currentChunk = startChunk;
    var currentPosition = start;
    var totalBytesWritten = 0;
    RandomAccessFile? currentFile;

    try {
      await for (final data in stream) {
        builder.add(data);
        totalBytesWritten += data.length;
        
        while (builder.length >= bufferSize || (end != null && currentPosition + builder.length >= end)) {
          if (currentFile == null) {
            currentFile = await File(_getChunkPath(currentChunk)).open(mode: FileMode.writeOnlyAppend);
            print('[${DateTime.now()}] Started writing chunk $currentChunk (${currentChunk * chunkSize}-${(currentChunk + 1) * chunkSize - 1})');
          }

          final bytesToWrite = end != null ? 
            math.min(bufferSize, end - currentPosition) : 
            math.min(bufferSize, builder.length);

          if (bytesToWrite <= 0) break;

          await _writeChunk(currentFile, builder, bytesToWrite);
          currentPosition += bytesToWrite;

          if (currentPosition % chunkSize == 0 || (end != null && currentPosition >= end)) {
            await _finalizeChunk(currentFile, currentChunk, currentChunk * chunkSize);
            currentFile = null;
            currentChunk++;
            
            if (end != null && currentPosition >= end) break;
          }
        }
      }

      print('[${DateTime.now()}] Total bytes written: $totalBytesWritten');

      // 处理剩余数据
      if (builder.length > 0) {
        if (currentFile == null) {
          currentFile = await File(_getChunkPath(currentChunk)).open(mode: FileMode.writeOnlyAppend);
          print('[${DateTime.now()}] Started writing final chunk $currentChunk');
        }
        
        await _writeChunk(currentFile, builder, builder.length);
        await _finalizeChunk(currentFile, currentChunk, currentChunk * chunkSize);
      }

      _updateComplete();
      _saveMetadata();
    } finally {
      if (currentFile != null) {
        try {
          await currentFile.flush();
          await currentFile.close();
        } catch (e) {
          print('[${DateTime.now()}] Error closing file: $e');
        }
      }
    }
  }

  @override
  Stream<List<int>> read(int start, int? end) async* {
    final startChunk = start ~/ chunkSize;
    final endChunk = end == null ? null : (end ~/ chunkSize);
    var totalBytesRead = 0;
    
    print('[${DateTime.now()}] Checking cache for range: start=$start, end=$end');
    
    final isCacheHit = _isRangeFullyCached(start, end);
    if (isCacheHit) {
      print('[${DateTime.now()}] Cache hit - Serving from cache');
    } else {
      print('[${DateTime.now()}] Cache miss - Some chunks not available');
    }
    
    // 读取可用的块
    for (var i = startChunk; i <= (endChunk ?? startChunk); i++) {
      if (!_isChunkAvailable(i)) {
        print('[${DateTime.now()}] Skipping chunk $i - not available');
        continue;
      }
      
      print('[${DateTime.now()}] Reading chunk $i (${chunks[i]!.start}-${chunks[i]!.end})');
      final chunkStart = i == startChunk ? start % chunkSize : 0;
      final chunkEnd = i == endChunk ? end! % chunkSize : null;
      
      await for (final data in await _readChunkRange(i, chunkStart, chunkEnd)) {
        totalBytesRead += data.length;
        yield data;
      }
    }
    
    print('[${DateTime.now()}] Total bytes read: $totalBytesRead');
  }

  @override
  Future<int> get size async {
    int total = 0;
    for (final chunk in chunks.values) {
      if (chunk.isComplete) {
        total += chunk.size;
      }
    }
    return total;
  }

  @override
  Future<void> clear() async {
    final dir = Directory(cacheDir);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _resetState();
  }

  @override
  bool get isComplete => _isComplete;
} 