import 'dart:async';
import 'dart:io';

import 'chunk_cache.dart';

class CacheManager {
  static final CacheManager _instance = CacheManager._internal();
  factory CacheManager({required String basePath}) {
    _instance._basePath = basePath;
    return _instance;
  }

  final Map<String, ChunkCache> _caches = {};
  // 缓存配置常量
  static const int maxCacheSize = 1024 * 1024 * 1024; // 1GB

  late final String _basePath;

  CacheManager._internal();

  // 获取缓存实例
  ChunkCache getCache(String url) {
    if (!_caches.containsKey(url)) {
      _caches[url] = ChunkCache(url, basePath: _basePath);
    }
    return _caches[url]!;
  }

  // 获取所有缓存总大小
  Future<int> getTotalSize() async {
    int total = 0;
    for (var cache in _caches.values) {
      total += await cache.size;
    }
    return total;
  }

  // 清理最旧的缓存直到总大小小于限制
  Future<void> cleanupIfNeeded() async {
    final totalSize = await getTotalSize();
    if (totalSize <= maxCacheSize) return;

    // 获取所有缓存目录的访问时间
    final cacheDir = Directory(_basePath);
    if (!await cacheDir.exists()) return;

    var dirs =
        await cacheDir.list().where((entity) => entity is Directory).map((entity) => entity as Directory).toList();

    // 获取所有目录的访问时间信息
    final dirStats = await Future.wait(dirs.map((dir) async {
      final stat = await dir.stat();
      return MapEntry(dir, stat.accessed);
    }));

    // 按访问时间排序
    dirStats.sort((a, b) => a.value.compareTo(b.value));
    final sortedDirs = dirStats.map((e) => e.key).toList();

    // 从最旧的开始删除，直到总大小小于限制
    for (var dir in sortedDirs) {
      if (await getTotalSize() <= maxCacheSize) break;

      final dirName = dir.path.split('/').last;
      final cache = _caches[dirName];
      if (cache != null) {
        await cache.clear();
        _caches.remove(dirName);
      }
      await dir.delete(recursive: true);
    }
  }

  // 清理指定URL的缓存
  Future<void> clearCache(String url) async {
    final cache = _caches[url];
    if (cache != null) {
      await cache.clear();
      _caches.remove(url);
    }
  }

  // 清理所有缓存
  Future<void> clearAll() async {
    for (var cache in _caches.values) {
      await cache.clear();
    }
    _caches.clear();

    final cacheDir = Directory(_basePath);
    if (await cacheDir.exists()) {
      await cacheDir.delete(recursive: true);
    }
  }

  // 关闭所有缓存
  Future<void> close() async {
    for (var cache in _caches.values) {
      await cache.close();
    }
    _caches.clear();
  }
}
