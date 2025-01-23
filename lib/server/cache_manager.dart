import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as path;
import 'package:logging/logging.dart';
import 'package:crypto/crypto.dart';

class CacheManager {
  static final Logger _logger = Logger('CacheManager');
  final String cacheRoot;
  final int maxCacheSize; // in bytes
  final Duration cacheDuration;

  CacheManager({
    required this.cacheRoot,
    this.maxCacheSize = 1024 * 1024 * 1024, // 1GB
    this.cacheDuration = const Duration(days: 7),
  });

  Future<void> initialize() async {
    _logger.fine('Initializing cache manager with root: $cacheRoot');
    final dir = Directory(cacheRoot);
    
    if (!await dir.exists()) {
      _logger.info('Cache directory does not exist, creating: $cacheRoot');
      await dir.create(recursive: true);
      _logger.info('Successfully created cache directory at $cacheRoot');
    } else {
      _logger.fine('Cache directory already exists: $cacheRoot');
    }
    
    _logger.info('Cache manager initialized successfully');
  }

  Future<void> cleanup() async {
    final now = DateTime.now();
    final dir = Directory(cacheRoot);
    
    if (await dir.exists()) {
      await for (final entity in dir.list()) {
        if (entity is File) {
          final stat = await entity.stat();
          if (now.difference(stat.modified) > cacheDuration) {
            await entity.delete();
            _logger.fine('Deleted expired cache file: ${entity.path}');
          }
        }
      }
    }
  }

  Future<int> getCacheSize() async {
    int totalSize = 0;
    final dir = Directory(cacheRoot);
    
    if (await dir.exists()) {
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File) {
          final stat = await entity.stat();
          totalSize += stat.size;
        }
      }
    }
    
    return totalSize;
  }

  String getCachePath(String url) {
    final hash = _generateHash(url);
    return path.join(cacheRoot, hash, 'data');
  }

  String _generateHash(String input) {
    final bytes = utf8.encode(input);
    final digest = md5.convert(bytes);
    return digest.toString();
  }
}