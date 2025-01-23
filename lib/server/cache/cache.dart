
abstract class Cache {
  /// 写入数据
  Future<void> write(Stream<List<int>> stream, int start, int? end);
  
  /// 读取数据
  Stream<List<int>> read(int start, int? end);
  
  /// 获取缓存大小
  Future<int> get size;
  
  /// 清理缓存
  Future<void> clear();
  
  /// 是否已完全缓存
  bool get isComplete;
} 