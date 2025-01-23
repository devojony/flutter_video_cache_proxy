import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'cache.dart';
import 'package:path/path.dart' as path;

class ChunkCache implements Cache {
  static const int chunkSize = 5 * 1024 * 1024; // 5MB 分块大小
  final String url;
  final String cacheDir;
  final String basePath;
  final Map<String, dynamic> metadata;
  Directory? _cacheDirectory;
  bool _initialized = false;

  ChunkCache(this.url, {required this.basePath}) : 
    cacheDir = md5.convert(utf8.encode(url)).toString(),
    metadata = {};

  Future<void> init() async {
    if (_initialized) return;
    
    try {
      final baseDir = Directory(basePath);
      if (!await baseDir.exists()) {
        await baseDir.create(recursive: true);
      }

      final cacheDirPath = path.join(basePath, cacheDir);
      final cacheDirDirectory = Directory(cacheDirPath);
      if (!await cacheDirDirectory.exists()) {
        await cacheDirDirectory.create();
      }

      _cacheDirectory = Directory(path.join(cacheDirPath, 'data'));
      if (!await _cacheDirectory!.exists()) {
        await _cacheDirectory!.create();
      }

      final metadataFile = File(path.join(cacheDirPath, 'metadata.json'));
      print('初始化缓存: ${metadataFile.path}');
      
      if (await metadataFile.exists()) {
        final content = await metadataFile.readAsString();
        print('读取元数据内容: $content');
        final Map<String, dynamic> loadedMetadata = jsonDecode(content);
        metadata.clear();
        metadata.addAll(loadedMetadata);
        print('加载后的元数据: $metadata');
      } else {
        print('元数据文件不存在');
      }

      _initialized = true;
    } catch (e, stack) {
      print('初始化缓存时出错: $e\n$stack');
      rethrow;
    }
  }

  Future<void> saveMetadata() async {
    await init();
    final metadataFile = File(path.join(basePath, cacheDir, 'metadata.json'));
    final content = jsonEncode(metadata);
    await metadataFile.writeAsString(content);
    print('保存元数据: $content');
  }

  String _getChunkPath(int index) {
    return path.join(_cacheDirectory!.path, 'chunk_$index');
  }

  @override
  Future<void> write(Stream<List<int>> stream, int start, int end) async {
    await init();
    
    final startChunk = start ~/ chunkSize;
    final endChunk = (end - 1) ~/ chunkSize;
    print('写入数据: start=$start, end=$end, startChunk=$startChunk, endChunk=$endChunk');

    // 创建所有需要的chunk文件
    final chunkFiles = <int, RandomAccessFile>{};
    try {
      for (var i = startChunk; i <= endChunk; i++) {
        final chunkFile = File(_getChunkPath(i));
        if (!await chunkFile.exists()) {
          await chunkFile.create();
        }
        chunkFiles[i] = await chunkFile.open(mode: FileMode.write);
      }

      int currentPosition = start;
      int totalWritten = 0;
      
      await for (final data in stream) {
        int dataOffset = 0;
        int remaining = data.length;
        
        while (remaining > 0 && currentPosition < end) {
          final chunkIndex = currentPosition ~/ chunkSize;
          final chunkStart = chunkIndex * chunkSize;
          final chunkOffset = currentPosition - chunkStart;
          
          final bytesToWrite = min(
            min(chunkSize - chunkOffset, remaining),
            end - currentPosition
          );
          
          final chunk = data.sublist(dataOffset, dataOffset + bytesToWrite);
          final raf = chunkFiles[chunkIndex]!;
          
          await raf.setPosition(chunkOffset);
          await raf.writeFrom(chunk);
          print('写入chunk_$chunkIndex: offset=$chunkOffset, length=${chunk.length}');
          
          dataOffset += bytesToWrite;
          currentPosition += bytesToWrite;
          remaining -= bytesToWrite;
          totalWritten += bytesToWrite;
        }
      }
      
      print('写入完成: 总共写入 $totalWritten 字节');
      
      if (totalWritten != end - start) {
        throw Exception('写入数据不完整: 预期写入 ${end - start} 字节，实际写入 $totalWritten 字节');
      }
    } finally {
      // 关闭所有文件
      for (var raf in chunkFiles.values) {
        await raf.close();
      }
    }
  }

  @override
  Stream<List<int>> read(int start, int end) async* {
    await init();
    
    final startChunk = start ~/ chunkSize;
    final endChunk = (end - 1) ~/ chunkSize;
    print('读取数据: start=$start, end=$end, startChunk=$startChunk, endChunk=$endChunk');

    int currentPosition = start;
    int totalRead = 0;
    
    for (int i = startChunk; i <= endChunk; i++) {
      final chunkFile = File(_getChunkPath(i));
      if (!await chunkFile.exists()) {
        throw Exception('Chunk $i not found');
      }
      
      final chunkStart = i * chunkSize;
      final chunkOffset = currentPosition - chunkStart;
      final length = min(
        chunkSize - chunkOffset,
        end - currentPosition
      );
      
      final raf = await chunkFile.open();
      try {
        await raf.setPosition(chunkOffset);
        final data = await raf.read(length);
        if (data.isEmpty) {
          throw Exception('读取到空数据: chunk=$i, offset=$chunkOffset, length=$length');
        }
        yield data;
        currentPosition += data.length;
        totalRead += data.length;
        print('读取chunk_$i: offset=$chunkOffset, length=${data.length}');
      } finally {
        await raf.close();
      }
    }
    
    print('读取完成: 总共读取 $totalRead 字节');
    
    if (totalRead != end - start) {
      throw Exception('读取数据不完整: 预期读取 ${end - start} 字节，实际读取 $totalRead 字节');
    }
  }

  @override
  Future<int> get size async {
    await init();
    int totalSize = 0;
    
    await for (final entity in _cacheDirectory!.list()) {
      if (entity is File) {
        totalSize += await entity.length();
      }
    }
    
    return totalSize;
  }

  @override
  Future<void> clear() async {
    await init();
    await _cacheDirectory?.delete(recursive: true);
    await _cacheDirectory?.create();
    metadata.clear();
    await saveMetadata();
  }

  @override
  @override
  Future<bool> healthCheck() async {
    try {
      // 检查缓存目录是否存在
      if (!await _cacheDirectory!.exists()) {
        return false;
      }

      // 测试目录可写性
      final testFile = File(path.join(_cacheDirectory!.path, '__healthcheck__'));
      await testFile.writeAsBytes([0x00]);
      await testFile.delete();

      // 测试元数据文件可读性
      final metadataFile = File(path.join(basePath, cacheDir, 'metadata.json'));
      if (await metadataFile.exists()) {
        await metadataFile.readAsString();
      }

      return true;
    } catch (e) {
      print('健康检查失败: $e');
      return false;
    }
  }

  @override
  Future<void> close() async {
    await saveMetadata();
  }

  Future<void> updateMetadata({
    String? contentType,
    int? contentLength,
    Map<String, String>? headers,
  }) async {
    await init();
    if (contentType != null) metadata['contentType'] = contentType;
    if (contentLength != null) metadata['contentLength'] = contentLength;
    if (headers != null) metadata['headers'] = headers;
    await saveMetadata();
    print('更新后的元数据: $metadata');
  }
}