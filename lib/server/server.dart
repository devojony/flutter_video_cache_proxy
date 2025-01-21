import 'dart:async';
import 'dart:io';

import 'cache_file.dart';

final pathSpec = Platform.pathSeparator;

class SimpleHttpServer {
  final InternetAddress _address;
  final int _port;
  final String _cacheDir;

  SimpleHttpServer(String address, int port, String cacheDir)
      : _address = InternetAddress(address),
        _port = port,
        _cacheDir = cacheDir {
    // 创建缓存目录
    Directory(_cacheDir).createSync(recursive: true);
  }

  Future<void> start() async {
    final server = await HttpServer.bind(_address, _port);
    print('服务器已启动，正在监听 http://${server.address.address}:${server.port}');
    print('缓存目录: $_cacheDir');

    await for (final request in server) {
      print('收到请求: range-> ${request.headers[HttpHeaders.rangeHeader]}');
      _handleRequest(request);
    }
  }

  void _handleRequest(HttpRequest request) async {
    // 只处理 GET 请求
    if (request.method != 'GET') {
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('Method Not Allowed');
      return;
    }

    // 检查是否包含 url 参数
    final urlParams = request.uri.queryParameters;
    if (!urlParams.containsKey('url')) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Bad Request: url parameter is required');
      return;
    }

    final url = urlParams['url']!;

    try {
      final cache = CacheFile(_cacheDir, url);
      Stream<List<int>>? stream;
      // 检查缓存是否存在且有效
      if (await cache.isValid) {
        print('使用缓存: ${cache.cachePath}');
        stream = _serveFromCache(cache);
      } else {
        stream = await _tryHandleRequest(request, url, cache);
      }
      stream = stream?.transform(StreamTransformer.fromHandlers(
        handleData: (data, sink) {
          print("stream chunk: ${data.length}");
          sink.add(data);
        },
      ));

      if (stream != null) {
        // 设置响应头
        request.response.statusCode = HttpStatus.partialContent;
        final headers = request.response.headers;
        headers.contentType = ContentType.parse(cache.meta["contentType"] ?? "video/*");
        headers.set(HttpHeaders.acceptRangesHeader, "bytes");

        // 设置Content-Range头
        final rangeHeader = request.headers[HttpHeaders.rangeHeader];
        final fileSize = cache.meta['contentLength'] ?? cache.getFileSize();
        print("final contentLength: $fileSize");
        if (rangeHeader != null && rangeHeader.isNotEmpty) {
          final range = rangeHeader.first.replaceAll("bytes=", "");
          headers.set(HttpHeaders.contentRangeHeader, "bytes $range/$fileSize");
        } else {
          headers.set(HttpHeaders.contentRangeHeader, "bytes 0-${fileSize - 1}/$fileSize");
        }

        // 设置Content-Length头
        headers.contentLength = fileSize;

        // 传输数据到客户端
        await stream.pipe(request.response);
      }
    } on FormatException catch (e, t) {
      print("$e\n$t");
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid URL format');
    } on SocketException catch (e, t) {
      print("$e\n$t");
      request.response
        ..statusCode = HttpStatus.badGateway
        ..write('Network error: ${e.message}');
    } on HttpException catch (e, t) {
      print("$e\n$t");
      request.response
        ..statusCode = HttpStatus.badGateway
        ..write('HTTP error: ${e.message}');
    } catch (e, t) {
      print("$e\n$t");
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Internal server error');
    } finally {
      await request.response.close();
      print("请求处理完毕");
    }
  }

  Stream<List<int>>? _serveFromCache(CacheFile cache) {
    try {
      final metaData = cache.meta;

      // 验证资源大小
      final fileSize = cache.getFileSize();
      if (metaData['contentLength'] != fileSize) {
        throw Exception('缓存文件大小不匹配: cacheSize: $fileSize contentLength: ${metaData['contentLength']}');
      }

      return cache.readChunkedCache();
    } catch (e, t) {
      print('$e\n$t');
      rethrow;
    }
  }

  Future<Stream<List<int>>?> _tryHandleRequest(
    HttpRequest request,
    String url,
    CacheFile cache,
  ) async {
    final httpClient = HttpClient();

    try {
      // 请求远程资源
      final uri = Uri.parse(url);
      final httpRequest = await httpClient.getUrl(uri);

      // 处理 Range 请求头
      final rangeHeader = request.headers[HttpHeaders.rangeHeader];
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        httpRequest.headers.set(HttpHeaders.rangeHeader, rangeHeader.first);
      }

      final httpResponse = await httpRequest.close();

      // 检查远程响应状态
      if (httpResponse.statusCode != HttpStatus.ok && httpResponse.statusCode != HttpStatus.partialContent) {
        throw HttpException('Failed to fetch resource: ${httpResponse.reasonPhrase}', uri: uri);
      }

      // 准备元数据
      final metaData = {
        'contentType': httpResponse.headers.contentType?.value ?? 'application/octet-stream',
        'url': url,
        'timestamp': DateTime.now().toIso8601String(),
        'contentLength': httpResponse.headers.contentLength,
      };

      // 处理部分内容响应
      if (httpResponse.statusCode == HttpStatus.partialContent) {
        final contentRange = httpResponse.headers[HttpHeaders.contentRangeHeader];
        if (contentRange != null && contentRange.isNotEmpty) {
          metaData['contentLength'] = int.parse(contentRange.first.split("/").last);
          print("资源响应返回的资源大小: ${metaData['contentLength']}");
        }
      }

      // 创建流控制器
      final controller = StreamController<List<int>>.broadcast();

      // 写入缓存
      cache.meta = metaData;
      unawaited(cache.writeChunkedCache(controller.stream, metaData));

      // 传输数据到客户端
      Future.delayed(const Duration(milliseconds: 100), () async {
        await httpResponse.pipe(controller.sink);
      });

      return controller.stream;
    } catch (e) {
      rethrow;
    } finally {
      httpClient.close();
    }
  }
}

void main() async {
  final server = SimpleHttpServer('127.0.0.1', 8080, 'd:/project/media_kit_demo/cache');
  await server.start();
}
