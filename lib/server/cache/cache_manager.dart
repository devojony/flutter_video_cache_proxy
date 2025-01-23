import 'dart:io';
import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'chunk_cache.dart';

class CacheManager {
  final String baseCacheDir;
  final Map<String, ChunkCache> _caches = {};
  
  CacheManager(this.baseCacheDir) {
    Directory(baseCacheDir).createSync(recursive: true);
  }

  String _generateCacheKey(String url) {
    return md5.convert(utf8.encode(url)).toString();
  }

  ChunkCache getCache(String url) {
    final cacheKey = _generateCacheKey(url);
    if (!_caches.containsKey(cacheKey)) {
      final cacheDir = Directory('${baseCacheDir}/${cacheKey}');
      _caches[cacheKey] = ChunkCache(cacheDir.path);
    }
    return _caches[cacheKey]!;
  }

  Future<void> clearCache(String url) async {
    final cacheKey = _generateCacheKey(url);
    if (_caches.containsKey(cacheKey)) {
      await _caches[cacheKey]!.clear();
      _caches.remove(cacheKey);
    }
  }

  Future<void> clearAll() async {
    for (final cache in _caches.values) {
      await cache.clear();
    }
    _caches.clear();
  }

  Future<int> get totalSize async {
    int total = 0;
    for (final cache in _caches.values) {
      total += await cache.size;
    }
    return total;
  }
}