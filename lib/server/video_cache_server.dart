import 'dart:io';
import 'dart:async';
import 'cache/cache_manager.dart';
import 'cache/cache.dart';

class VideoCacheServer {
  static const defaultPort = 8080;
  
  final InternetAddress address;
  final int port;
  final CacheManager cacheManager;
  HttpServer? _server;

  VideoCacheServer({
    InternetAddress? address,
    this.port = defaultPort,
    required String cacheDir,
  }) : address = address ?? InternetAddress.loopbackIPv4,
       cacheManager = CacheManager(cacheDir);

  Future<void> start() async {
    _server = await HttpServer.bind(address, port);
    print('Server running on ${address.address}:$port');

    await for (final request in _server!) {
      print('[${DateTime.now()}] Received ${request.method} request from ${request.connectionInfo?.remoteAddress.address}');
      if (request.method == 'GET') {
        _handleGetRequest(request);
      } else {
        request.response
          ..statusCode = HttpStatus.methodNotAllowed
          ..close();
      }
    }
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }

  Future<void> _handleGetRequest(HttpRequest request) async {
    final url = request.uri.queryParameters['url'];
    if (url == null) {
      print('[${DateTime.now()}] Error: Missing url parameter');
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing url parameter')
        ..close();
      return;
    }

    try {
      print('[${DateTime.now()}] Processing video: $url');
      final cache = cacheManager.getCache(url);
      final headers = request.headers;
      final rangeHeader = headers[HttpHeaders.rangeHeader]?.first;

      if (rangeHeader != null) {
        print('[${DateTime.now()}] Range request: $rangeHeader');
        await _handleRangeRequest(request, url, cache, rangeHeader);
      } else {
        print('[${DateTime.now()}] Full request');
        await _handleFullRequest(request, url, cache);
      }
    } catch (e, stack) {
      print('[${DateTime.now()}] Error processing request: $e\n$stack');
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Error: $e')
        ..close();
    }
  }

  Future<void> _handleFullRequest(
    HttpRequest request,
    String url,
    Cache cache,
  ) async {
    // 检查是否已缓存
    if (cache.isComplete) {
      print('[${DateTime.now()}] Serving complete file from cache');
      request.response.headers
        ..contentType = ContentType.parse('video/mp4')
        ..contentLength = await cache.size
        ..add('Accept-Ranges', 'bytes');
      
      await cache.read(0, null).pipe(request.response);
      return;
    }

    final client = HttpClient();
    try {
      final clientRequest = await client.getUrl(Uri.parse(url));
      final response = await clientRequest.close();

      request.response.headers
        ..contentType = ContentType.parse(response.headers.contentType?.toString() ?? 'video/mp4')
        ..contentLength = response.contentLength
        ..add('Accept-Ranges', 'bytes');

      // 转发响应流并同时缓存
      final responseStream = response.asBroadcastStream();
      unawaited(cache.write(responseStream, 0, response.contentLength));
      
      await responseStream.pipe(request.response);
    } finally {
      client.close();
    }
  }

  Future<void> _handleRangeRequest(
    HttpRequest request,
    String url,
    Cache cache,
    String rangeHeader,
  ) async {
    final match = RegExp(r'bytes=(\d+)-(\d+)?').firstMatch(rangeHeader);
    if (match == null) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Invalid range header')
        ..close();
      return;
    }

    final start = int.parse(match.group(1)!);
    final end = match.group(2) != null ? int.parse(match.group(2)!) : null;

    // 检查是否已缓存该范围
    if (await _isRangeCached(cache, start, end)) {
      print('[${DateTime.now()}] Serving range from cache: $start-$end');
      await _serveFromCache(request, cache, start, end);
      return;
    }

    final client = HttpClient();
    try {
      final clientRequest = await client.getUrl(Uri.parse(url));
      clientRequest.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end ?? ''}');
      final response = await clientRequest.close();

      if (response.statusCode == HttpStatus.partialContent) {
        request.response.headers
          ..contentType = ContentType.parse(response.headers.contentType?.toString() ?? 'video/mp4')
          ..contentLength = response.contentLength
          ..add('Accept-Ranges', 'bytes')
          ..add('Content-Range', response.headers.value(HttpHeaders.contentRangeHeader)!);
        request.response.statusCode = HttpStatus.partialContent;

        // 转发响应流并同时缓存
        final responseStream = response.asBroadcastStream();
        unawaited(cache.write(responseStream, start, end));
        
        await responseStream.pipe(request.response);
      } else {
        request.response
          ..statusCode = response.statusCode
          ..close();
      }
    } finally {
      client.close();
    }
  }

  Future<bool> _isRangeCached(Cache cache, int start, int? end) async {
    if (!cache.isComplete) {
      final stream = cache.read(start, end);
      bool hasData = false;
      await for (final _ in stream) {
        hasData = true;
        break;
      }
      return hasData;
    }
    return true;
  }

  Future<void> _serveFromCache(
    HttpRequest request,
    Cache cache,
    int start,
    int? end,
  ) async {
    final size = await cache.size;
    end ??= size - 1;

    request.response.headers
      ..contentType = ContentType.parse('video/mp4')
      ..contentLength = end - start + 1
      ..add('Accept-Ranges', 'bytes')
      ..add('Content-Range', 'bytes $start-$end/$size');
    request.response.statusCode = HttpStatus.partialContent;

    await cache.read(start, end).pipe(request.response);
  }
} 