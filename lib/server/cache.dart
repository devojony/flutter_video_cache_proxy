import 'dart:async';

/// 缓存系统核心接口
/// [T] 缓存数据类型（默认为字节数据）
abstract class Cache<T extends List<int>> {
  /// 写入数据到缓存
  ///
  /// @param stream 输入数据流
  /// @param start 写入起始位置（字节偏移量）
  /// @param end 写入结束位置（字节偏移量，包含）
  /// @throws CacheWriteException 当写入失败时抛出
  Future<void> write(Stream<T> stream, int start, int end);

  /// 从缓存读取数据
  ///
  /// @param start 读取起始位置（字节偏移量）
  /// @param end 读取结束位置（字节偏移量，包含）
  /// @return 包含请求数据的流
  /// @throws CacheReadException 当读取失败时抛出
  Stream<T> read(int start, int end);

  /// 获取当前缓存总大小（字节）
  ///
  /// @return 缓存字节大小
  /// @throws CacheOperationException 当获取大小失败时抛出
  Future<int> get size;

  /// 清理全部缓存数据
  ///
  /// @throws CacheClearException 当清理失败时抛出
  Future<void> clear();

  /// 安全关闭缓存
  ///
  /// @throws CacheCloseException 当关闭失败时抛出
  Future<void> close();

  /// 缓存健康状态检查
  ///
  /// @return 返回缓存可用性状态
  Future<bool> healthCheck();
}