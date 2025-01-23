import 'dart:io';
import 'video_cache_server.dart';

void main() async {
  final server = VideoCacheServer(
    cacheDir: 'cache',
    port: 8080,
  );

  await server.start();
  
  print('Video cache server is running!');
  print('Example usage:');
  print('http://localhost:8080/?url=YOUR_VIDEO_URL');
  
  // 等待用户输入以停止服务器
  print('\nPress Enter to stop the server...');
  await stdin.first;
  
  await server.stop();
  print('Server stopped.');
}