// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'cache_manager.dart';
import 'range_parser.dart';

/// 视频缓存服务器
///
/// 负责处理视频请求，支持范围请求和缓存功能
class CacheServer {
  late final CacheManager cacheManager;
  final int port;
  HttpServer? _server;

  /// 创建缓存服务器实例
  ///
  /// [port] 服务器监听端口，默认8080
  CacheServer({required String cacheDir, this.port = 8080}) {
    cacheManager = CacheManager(cacheRoot: cacheDir);
  }

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('Cache server running on port $port');

    await for (final request in _server!) {
      try {
        if (request.method == 'GET' && request.uri.path == '/video') {
          await _handleVideoRequest(request);
        } else {
          await _sendResponse(
            request,
            statusCode: HttpStatus.notFound,
            message: 'Not Found',
          );
        }
      } catch (e, t) {
        print("无法处理的错误: $e\n$t");
      }
    }
  }

  /// 发送 HTTP 响应
  Future<void> _sendResponse(
    HttpRequest request, {
    required int statusCode,
    String? message,
    ContentType? contentType,
    Map<String, String>? headers,
  }) async {
    final response = request.response;
    response.statusCode = statusCode;
    if (contentType != null) {
      response.headers.contentType = contentType;
    }
    headers?.forEach((key, value) {
      if (key == "statusCode") return;
      response.headers.set(key, value);
    });
    if (message != null) {
      response.write(message);
    }
    await response.close();
  }

  /// 发送流式响应
  Future<void> _sendStreamResponse(
    HttpRequest request,
    Stream<List<int>> stream, {
    required int statusCode,
    required ContentType contentType,
    Map<String, String>? headers,
  }) async {
    final response = request.response;
    response.statusCode = statusCode;
    response.headers.contentType = contentType;
    headers?.forEach((key, value) {
      response.headers.set(key, value);
    });
    await response.addStream(stream);
    await response.close();
  }

  Future<void> _handleVideoRequest(HttpRequest request) async {
    final url = request.uri.queryParameters['url'];
    if (url == null) {
      await _sendResponse(
        request,
        statusCode: HttpStatus.badRequest,
        message: 'Missing url parameter',
      );
      return;
    }

    final rangeHeader = request.headers[HttpHeaders.rangeHeader];
    if (await cacheManager.isCached(url)) {
      final totalSize = await cacheManager.getCachedVideoSize(url);

      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        final range = Range.parse(rangeHeader.first, totalSize);
        if (range == null) {
          await _sendResponse(
            request,
            statusCode: HttpStatus.requestedRangeNotSatisfiable,
            headers: {HttpHeaders.contentRangeHeader: 'bytes */$totalSize'},
          );
          return;
        }

        // Try to get cached data first
        final cachedStream = cacheManager.getCachedVideo(url, start: range.start, end: range.end);
        if (cachedStream != null) {
          // Check if we have the full range cached
          final cachedRangeSize = await cacheManager.getCachedRangeSize(url, range.start, range.end);
          if (cachedRangeSize == range.end - range.start) {
            // Full range is cached
            await _sendStreamResponse(
              request,
              cachedStream,
              statusCode: HttpStatus.partialContent,
              contentType: ContentType('video', 'mp4'),
              headers: {HttpHeaders.contentRangeHeader: 'bytes ${range.start}-${range.end - 1}/$totalSize'},
            );
            return;
          } else if (cachedRangeSize > 0) {
            // Only partial range is cached
            // Create a stream controller to combine cached and network data
            final controller = StreamController<Uint8List>();
            
            // First send cached data
            await for (final data in cachedStream) {
              controller.add(Uint8List.fromList(data));
            }
            
            // Then fetch remaining data from network
            final client = HttpClient();
            final clientRequest = await client.getUrl(Uri.parse(url));
            clientRequest.headers.add(HttpHeaders.rangeHeader, 'bytes=${range.start + cachedRangeSize}-${range.end - 1}');
            
            final clientResponse = await clientRequest.close();
            if (clientResponse.statusCode == HttpStatus.partialContent) {
              await for (final data in clientResponse) {
                controller.add(Uint8List.fromList(data));
              }
            }
            
            await _sendStreamResponse(
              request,
              controller.stream,
              statusCode: HttpStatus.partialContent,
              contentType: ContentType('video', 'mp4'),
              headers: {
                HttpHeaders.contentRangeHeader: 'bytes ${range.start}-${range.end - 1}/$totalSize',
                HttpHeaders.contentLengthHeader: (range.end - range.start).toString()
              },
            );
            return;
          }
        }
      }

      // No range header or invalid range - return full content
      final stream = cacheManager.getCachedVideo(url);
      if (stream != null) {
        await _sendStreamResponse(
          request,
          stream,
          statusCode: HttpStatus.ok,
          contentType: ContentType('video', 'mp4'),
          headers: {HttpHeaders.contentLengthHeader: totalSize.toString()},
        );
        return;
      }
    }

    try {
      final client = HttpClient();
      final clientRequest = await client.getUrl(Uri.parse(url));

      // Handle Range header if present
      if (rangeHeader != null && rangeHeader.isNotEmpty) {
        clientRequest.headers.add(HttpHeaders.rangeHeader, rangeHeader.first);
      }

      final clientResponse = await clientRequest.close();

      if (clientResponse.statusCode != HttpStatus.ok && clientResponse.statusCode != HttpStatus.partialContent) {
        await _sendResponse(
          request,
          statusCode: clientResponse.statusCode,
          message: 'Failed to fetch video from source',
        );
        return;
      }

      // Get content length from response headers
      final contentLength = clientResponse.headers.value(HttpHeaders.contentLengthHeader);
      final expectedSize = contentLength != null ? int.parse(contentLength) : null;

      // Cache the video while streaming
      final controller = StreamController<Uint8List>();
      var bytesWritten = 0;

      // Get start position from range header
      final start =
          rangeHeader != null && rangeHeader.isNotEmpty ? Range.parse(rangeHeader.first, expectedSize ?? 0)?.start : 0;

      // Cache the video after verifying size
      cacheManager.cacheVideo(url, controller.stream, start: start ?? 0);

      await _sendStreamResponse(
        request,
        clientResponse.transform(StreamTransformer.fromHandlers(handleData: (data, sink) {
          bytesWritten += data.length;
          final uint8Data = Uint8List.fromList(data);
          sink.add(uint8Data);
          controller.add(uint8Data);
        }, handleDone: (sink) {
          sink.close();
          controller.close();

          // Verify size if expectedSize is provided
          if (expectedSize != null && bytesWritten != expectedSize) {
            throw HttpException('Content size mismatch. $bytesWritten bytes written but expected $expectedSize.',
                uri: Uri.parse(url));
          }
        }, handleError: (error, stackTrace, sink) {
          sink.addError(error, stackTrace);
          controller.addError(error, stackTrace);
        })),
        statusCode: clientResponse.statusCode,
        contentType: clientResponse.headers.contentType ?? ContentType('video', '*'),
        headers: {'Accept-Ranges': 'bytes', if (contentLength != null) HttpHeaders.contentLengthHeader: contentLength},
      );
    } catch (e) {
      await _sendResponse(
        request,
        statusCode: HttpStatus.internalServerError,
        message: 'Internal Server Error: ${e.toString()}',
      );
    }
  }

  Future<void> stop() async {
    await _server?.close();
    print('Cache server stopped');
  }
}
