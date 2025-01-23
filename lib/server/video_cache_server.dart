import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'cache_manager.dart';
import 'chunk_cache.dart';

class VideoCacheServer {
  final int port;
  final CacheManager _cacheManager;
  HttpServer? _server;

  VideoCacheServer({
    this.port = 8080,
    required String basePath,
  }) : _cacheManager = CacheManager(basePath: basePath);

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('视频缓存服务器启动在 http://localhost:$port');

    await for (HttpRequest request in _server!) {
      if (request.method == 'GET') {
        _handleGetRequest(request);
      } else {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..write('只支持GET请求')
          ..close();
      }
    }
  }

  Future<void> stop() async {
    await _server?.close();
    await _cacheManager.close();
  }

  Future<void> _handleGetRequest(HttpRequest request) async {
    HttpResponse response = request.response;
    try {
      final url = request.uri.queryParameters['url'];
      if (url == null || url.isEmpty) {
        await _sendError(response, HttpStatus.badRequest, '缺少url参数');
        return;
      }

      print('处理视频请求: $url');

      final cache = _cacheManager.getCache(url);
      await cache.init();


      print('当前元数据: ${cache.metadata}');
      var contentLength = cache.metadata['contentLength'] as int?;
      
      if (contentLength == null) {
        print('获取视频信息...');
        final videoResponse = await http.head(Uri.parse(url));
        if (videoResponse.statusCode != HttpStatus.ok) {
          await _sendError(response, videoResponse.statusCode, '无法访问视频');
          return;
        }

        contentLength = int.tryParse(videoResponse.headers['content-length'] ?? '');
        if (contentLength == null) {
          await _sendError(response, HttpStatus.badRequest, '无法获取视频大小');
          return;
        }

        print('获取到视频信息: contentType=${videoResponse.headers['content-type']}, contentLength=$contentLength');
        await cache.updateMetadata(
          contentType: videoResponse.headers['content-type'],
          contentLength: contentLength,
          headers: videoResponse.headers,
        );
      }

            
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);

      if (rangeHeader != null) {
        print('处理范围请求: $rangeHeader');
        await _handleRangeRequest(request, url, cache, contentLength);
      } else {
        print('处理完整请求');
        await _handleFullRequest(request, url, cache, contentLength);
      }
    } catch (e, stack) {
      print('处理请求时出错: $e\n$stack');
      try {
        await _sendError(response, HttpStatus.internalServerError, '服务器错误: $e');
      } catch (_) {
        await response.close();
      }
    }
  }

  Future<void> _handleRangeRequest(
    HttpRequest request,
    String url,
    ChunkCache cache,
    int contentLength,
  ) async {
    final range = _parseRangeHeader(request.headers.value(HttpHeaders.rangeHeader)!);
    if (range == null) {
      await _sendError(request.response, HttpStatus.badRequest, '无效的Range头');
      return;
    }

    final start = range.start;
    final end = range.end;

    if (start >= contentLength || (end != null && end >= contentLength)) {
      await _sendError(request.response, HttpStatus.requestedRangeNotSatisfiable, '请求范围无效');
      return;
    }

    final response = request.response;
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(HttpHeaders.contentTypeHeader, 
        cache.metadata['contentType'] ?? 'video/mp4');
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    
    final rangeEnd = end ?? contentLength - 1;
    final length = rangeEnd - start + 1;
    
    response.headers.set(HttpHeaders.contentLengthHeader, length.toString());
    response.headers.set(
      HttpHeaders.contentRangeHeader, 
      'bytes $start-$rangeEnd/$contentLength'
    );

    try {
      final cacheFile = File('${cache.basePath}/${cache.cacheDir}/data/chunk_${start ~/ ChunkCache.chunkSize}');
      print('检查缓存文件: ${cacheFile.path}');
      
      if (await cacheFile.exists()) {
        print('从缓存读取数据');
        await response.addStream(cache.read(start, rangeEnd + 1));
      } else {
        print('从源获取数据并缓存');
        final client = http.Client();
        try {
          final request = http.Request('GET', Uri.parse(url))
            ..headers[HttpHeaders.rangeHeader] = 'bytes=$start-$rangeEnd';
          
          final streamedResponse = await client.send(request);
          if (streamedResponse.statusCode != HttpStatus.partialContent) {
            await _sendError(response, streamedResponse.statusCode, '获取视频数据失败');
            return;
          }

          // 创建两个控制器用于分流数据
          final cacheController = StreamController<List<int>>();
          final responseController = StreamController<List<int>>();

          // 处理输入流
          streamedResponse.stream.listen(
            (data) {
              cacheController.add(data);
              responseController.add(data);
            },
            onDone: () {
              cacheController.close();
              responseController.close();
            },
            onError: (error) {
              cacheController.addError(error);
              responseController.addError(error);
            },
          );

          // 同时写入缓存和响应
          await Future.wait([
            cache.write(cacheController.stream, start, rangeEnd + 1),
            response.addStream(responseController.stream),
          ]);
        } finally {
          client.close();
        }
      }
    } catch (e) {
      print('处理范围请求时出错: $e');
      try {
        await _sendError(response, HttpStatus.internalServerError, '处理视频数据时出错');
      } catch (_) {
        await response.close();
      }
      return;
    }

    await response.close();
    await _cacheManager.cleanupIfNeeded();
  }

  Future<void> _handleFullRequest(
    HttpRequest request,
    String url,
    ChunkCache cache,
    int contentLength,
  ) async {
    final response = request.response;
    
    response.headers.set(HttpHeaders.contentTypeHeader, 
        cache.metadata['contentType'] ?? 'video/mp4');
    response.headers.set(HttpHeaders.contentLengthHeader, contentLength.toString());
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

    try {
      final cacheSize = await cache.size;
      print('缓存大小: $cacheSize, 视频大小: $contentLength');
      
      if (cacheSize >= contentLength) {
        print('从缓存读取完整视频');
        await response.addStream(cache.read(0, contentLength));
      } else {
        print('从源获取完整视频并缓存');
        final client = http.Client();
        try {
          final streamedResponse = await client.send(http.Request('GET', Uri.parse(url)));
          if (streamedResponse.statusCode != HttpStatus.ok) {
            await _sendError(response, streamedResponse.statusCode, '获取视频数据失败');
            return;
          }

          // 创建两个控制器用于分流数据
          final cacheController = StreamController<List<int>>();
          final responseController = StreamController<List<int>>();

          // 处理输入流
          streamedResponse.stream.listen(
            (data) {
              cacheController.add(data);
              responseController.add(data);
            },
            onDone: () {
              cacheController.close();
              responseController.close();
            },
            onError: (error) {
              cacheController.addError(error);
              responseController.addError(error);
            },
          );

          // 同时写入缓存和响应
          await Future.wait([
            cache.write(cacheController.stream, 0, contentLength),
            response.addStream(responseController.stream),
          ]);
        } finally {
          client.close();
        }
      }
    } catch (e) {
      print('处理完整请求时出错: $e');
      try {
        await _sendError(response, HttpStatus.internalServerError, '处理视频数据时出错');
      } catch (_) {
        await response.close();
      }
      return;
    }

    await response.close();
    await _cacheManager.cleanupIfNeeded();
  }

  Future<void> _sendError(HttpResponse response, int statusCode, String message) async {
    print('发送错误响应: $statusCode - $message');
    try {
      response.statusCode = statusCode;
      response.write(message);
    } catch (_) {
      // 忽略已经发送头的错误
    }
    await response.close();
  }

  _Range? _parseRangeHeader(String rangeHeader) {
    final match = RegExp(r'bytes=(\d+)-(\d+)?').firstMatch(rangeHeader);
    if (match == null) return null;

    final start = int.parse(match.group(1)!);
    final end = match.group(2) != null ? int.parse(match.group(2)!) : null;
    
    return _Range(start, end);
  }
}

class _Range {
  final int start;
  final int? end;
  
  _Range(this.start, this.end);
}