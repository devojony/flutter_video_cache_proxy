import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'cache_manager.dart';

class VideoCacheServer {
  final int port;
  late HttpServer _server;
  late CacheManager _cacheManager;

  VideoCacheServer({this.port = 8080}) {
    _cacheManager = CacheManager();
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    log('Video cache server running on port $port');
    _handleConnections();
  }

  void _handleConnections() async {
    await for (final request in _server) {
      log("Range header: ${request.headers[HttpHeaders.rangeHeader]}");
      if (request.method == 'GET') {
        _handleRequest(request);
      } else {
        _sendMethodNotAllowed(request.response);
      }
    }
  }

  void _sendMethodNotAllowed(HttpResponse response) {
    response
      ..statusCode = HttpStatus.methodNotAllowed
      ..write('Only GET requests are supported')
      ..close();
  }

  void _sendBadRequest(HttpResponse response, String message) {
    response
      ..statusCode = HttpStatus.badRequest
      ..write(message)
      ..close();
  }

  void _sendServerError(HttpResponse response, String error) {
    response
      ..statusCode = HttpStatus.internalServerError
      ..write('Error processing video: $error')
      ..close();
  }

  String? _validateRequest(HttpRequest request) {
    final url = request.uri.queryParameters['url'];
    if (url == null || url.isEmpty) {
      _sendBadRequest(request.response, 'Missing required "url" parameter');
      return null;
    }
    return url;
  }

  Future<void> _handleVideoStream(
    HttpRequest request,
    HttpClientResponse videoResponse,
  ) async {
    final completer = Completer();
    StreamSubscription<List<int>>? subscription;

    void handleChunk(List<int> chunk) async {
      try {
        await _writeToClient(request.response, chunk);
        await _cacheManager.updateCacheInBackground(
          request.uri.queryParameters['url']!,
          videoResponse,
        );
      } catch (e) {
        completer.completeError(e);
      }
    }

    subscription = videoResponse.listen(
      handleChunk,
      onError: (e) => completer.completeError(e),
      onDone: () => completer.complete(),
      cancelOnError: true,
    );

    request.response.done.then((_) => subscription?.cancel()).whenComplete(() => subscription?.cancel());

    return completer.future;
  }

  Future<void> _writeToClient(HttpResponse response, List<int> chunk) async {
    try {
      response.add(chunk);
    } catch (e) {
      throw Exception('Client connection closed');
    }
  }

  void _setupResponseHeaders(
    HttpResponse response,
    HttpClientResponse videoResponse,
  ) {
    // Set appropriate status code based on range request
    if (videoResponse.headers.value(HttpHeaders.contentRangeHeader) != null) {
      response.statusCode = HttpStatus.partialContent;
    } else {
      response.statusCode = HttpStatus.ok;
    }

    response.headers.contentType = ContentType.binary;

    // Copy relevant headers from source response
    if (videoResponse.headers[HttpHeaders.contentLengthHeader] != null) {
      response.headers.contentLength = videoResponse.headers.contentLength;
    }

    final contentRange = videoResponse.headers.value(HttpHeaders.contentRangeHeader);
    if (contentRange != null) {
      response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
    }

    // Enable range requests for cached content
    response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  }

  Future<void> _updateCacheInBackground(String url) async {
    try {
      final client = HttpClient();
      final videoRequest = await client.getUrl(Uri.parse(url));
      final videoResponse = await videoRequest.close();

      if (videoResponse.statusCode != HttpStatus.ok) {
        return;
      }

      await _cacheManager.updateCacheInBackground(url, videoResponse);
    } catch (e) {
      log('Error updating cache: $e');
    }
  }

  void _handleRequest(HttpRequest request) async {
    final url = _validateRequest(request);
    if (url == null) return;

    // Check if we have cached content
    try {
      await _serveFromCache(request, url);
      // 在返回缓存数据的同时，后台更新缓存
      _updateCacheInBackground(url);
      return;
    } catch (e) {
      log('Error serving from cache: $e');
      // 如果缓存服务失败，继续从源获取
    }

    // 获取源数据并缓存
    final client = HttpClient();

    try {
      final videoRequest = await client.getUrl(Uri.parse(url));

      final rangeHeader = request.headers[HttpHeaders.rangeHeader];
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        videoRequest.headers.set(HttpHeaders.rangeHeader, rangeHeader.first);
      }

      final videoResponse = await videoRequest.close();

      if (videoResponse.statusCode != HttpStatus.ok && videoResponse.statusCode != HttpStatus.partialContent) {
        _sendServerError(request.response, 'Invalid response from source');
        return;
      }

      _setupResponseHeaders(request.response, videoResponse);
      await _handleVideoStream(request, videoResponse);
    } catch (e) {
      _sendServerError(request.response, e.toString());
    } finally {
      await request.response.close();
      client.close();
    }
  }

  Future<void> _serveFromCache(
    HttpRequest request,
    String url,
  ) async {
    try {
      // Use cache manager to handle serving
      await serveFromCache(
        request: request,
        url: url,
        onRangeRequest: (request, totalSize) => _handleRangeRequest(request, url, totalSize),
      );
    } catch (e) {
      _sendServerError(request.response, e.toString());
    } finally {
      await request.response.close();
    }
  }

  Future<void> _handleRangeRequest(
    HttpRequest request,
    String url,
    int totalSize,
  ) async {
    final rangeHeader = request.headers[HttpHeaders.rangeHeader]!.first;
    final range = _parseRangeHeader(rangeHeader, totalSize);

    if (range == null) {
      request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$totalSize');
      return;
    }

    final start = range.$1.toInt();
    final end = range.$2.toInt();
    final contentLength = end - start + 1;

    // Set response headers
    request.response.statusCode = HttpStatus.partialContent;
    request.response.headers.contentLength = contentLength;
    request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$totalSize');

    // Create a stream that handles range requests
    final cacheFile = _cacheManager.getCacheFile(url)!;
    final fileStream = cacheFile.read(start: start, end: end + 1);

    request.response.addStream(fileStream);
  }

  Future<void> serveFromCache({
    required HttpRequest request,
    required String url,
    required Future<void> Function(HttpRequest, int) onRangeRequest,
  }) async {
    try {
      // Calculate total size
      final cacheFile = _cacheManager.getCacheFile(url);
      if (cacheFile == null) {
        throw Exception('Cache file not found for url: $url');
      }

      // Handle range requests
      final rangeHeader = request.headers[HttpHeaders.rangeHeader];
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        await onRangeRequest(request, cacheFile.totalSize);
        return;
      }

      // Serve full content
      request.response.headers.contentType = ContentType.binary;
      request.response.headers.contentLength = cacheFile.totalSize;
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');

      await request.response.addStream(cacheFile.read());
    } catch (e) {
      throw Exception('Failed to serve from cache: $e');
    }
  }

  (int, int)? _parseRangeHeader(String rangeHeader, int totalSize) {
    final rangeMatch = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
    if (rangeMatch == null) return null;

    final start = int.parse(rangeMatch.group(1)!);
    var end = rangeMatch.group(2)?.isEmpty ?? true ? totalSize - 1 : int.parse(rangeMatch.group(2)!);

    // Validate range
    if (start >= totalSize || end >= totalSize || start > end) {
      return null;
    }

    return (start, end);
  }
}
