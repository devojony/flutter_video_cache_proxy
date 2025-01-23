import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'cache_manager.dart';
import 'chunk_cache.dart';
import 'metadata_handler.dart';

class VideoCacheServer {
  static const String _logPrefix = '[VideoCacheServer]';
  final int port;
  final CacheManager cacheManager;
  HttpServer? _server;

  VideoCacheServer({
    this.port = 8080,
    String cacheRoot = 'video_cache',
  }) : cacheManager = CacheManager(cacheRoot: cacheRoot);

  Future<void> start() async {
    print('$_logPrefix Initializing video cache server on port $port');
    try {
      await cacheManager.initialize();
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      print('$_logPrefix Video cache server successfully started on port $port');
      print('$_logPrefix Cache root directory: ${cacheManager.cacheRoot}');

      // Add request handling loop
      await for (final request in _server!) {
        _handleRequest(request);
      }

    } catch (e, stackTrace) {
      print('$_logPrefix [ERROR] Failed to start video cache server: $e');
      print(stackTrace);
      rethrow;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    print('$_logPrefix Received request: ${request.method} ${request.uri}');
    
    if (request.method != 'GET') {
      print('$_logPrefix [WARNING] Method not allowed: ${request.method}');
      request.response
        ..statusCode = HttpStatus.methodNotAllowed
        ..write('Method Not Allowed')
        ..close();
      return;
    }

    final url = request.uri.queryParameters['url'];
    if (url == null || url.isEmpty) {
      print('$_logPrefix [WARNING] Missing video URL');
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing video URL')
        ..close();
      return;
    }

    final cachePath = cacheManager.getCachePath(url);
    final chunkCache = ChunkCache(cachePath);
    final metadataHandler = MetadataHandler(cachePath);

    try {
      await chunkCache.initialize();
      
      // Check if we have complete metadata
      final contentType = await metadataHandler.getContentType();
      final contentLength = await metadataHandler.getContentLength();
      
      if (contentType == null || contentLength == null) {
        // First time caching this video
        print('$_logPrefix Caching new video: $url');
        await _cacheAndStreamVideo(url, request, chunkCache, metadataHandler);
      } else {
        // Serve from cache
        print('$_logPrefix Serving cached video: $url');
        await _serveFromCache(request, chunkCache, metadataHandler);
      }
    } catch (e, stackTrace) {
      print('$_logPrefix [ERROR] Error handling video request: $e');
      print(stackTrace);
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Internal Server Error')
        ..close();
    }
  }

  Future<void> _cacheAndStreamVideo(
    String url,
    HttpRequest request,
    ChunkCache chunkCache,
    MetadataHandler metadataHandler,
  ) async {
    final client = http.Client();
    final response = await client.get(Uri.parse(url), headers: {
      'Range': 'bytes=0-',
    });

    if (response.statusCode != HttpStatus.ok &&
        response.statusCode != HttpStatus.partialContent) {
      print('$_logPrefix [ERROR] Failed to fetch video: ${response.statusCode}');
      request.response
        ..statusCode = response.statusCode
        ..write('Failed to fetch video')
        ..close();
      return;
    }

    // Update metadata
    await metadataHandler.updateContentType(
      response.headers['content-type'] ?? 'video/mp4',
    );
    await metadataHandler.updateContentLength(
      int.parse(response.headers['content-length'] ?? '0'),
    );

    // Cache and stream the video
    final data = response.bodyBytes;
    var bytesReceived = data.length;
    
    // Write data in chunks
    for (var i = 0; i < data.length; i += ChunkCache.chunkSize) {
      final end = min(i + ChunkCache.chunkSize, data.length);
      final chunk = data.sublist(i, end);
      await chunkCache.writeChunk(chunk, i);
    }
    
    // Stream data to client
    request.response.add(data);
    await request.response.close();
    client.close();
  }

  Future<void> _serveFromCache(
    HttpRequest request,
    ChunkCache chunkCache,
    MetadataHandler metadataHandler,
  ) async {
    final rangeHeader = request.headers[HttpHeaders.rangeHeader];
    final contentLength = await metadataHandler.getContentLength() ?? 0;
    final contentType = await metadataHandler.getContentType() ?? 'video/mp4';

    int startByte = 0;
    int endByte = contentLength - 1;
    
    if (rangeHeader != null && rangeHeader.isNotEmpty) {
      final range = _parseRangeHeader(rangeHeader.first, contentLength);
      startByte = range.start;
      endByte = range.end;
    }

    request.response
      ..statusCode = rangeHeader != null ? HttpStatus.partialContent : HttpStatus.ok
      ..headers.contentType = ContentType.parse(contentType)
      ..headers.contentLength = endByte - startByte + 1
      ..headers.add('Accept-Ranges', 'bytes')
      ..headers.add('Content-Range', 'bytes $startByte-$endByte/$contentLength');

    try {
      final data = await chunkCache.readRange(startByte, endByte);
      request.response.add(data);
      await request.response.close();
    } catch (e) {
      print('$_logPrefix [ERROR] Error serving from cache: $e');
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Cache Error')
        ..close();
    }
  }

  ({int start, int end}) _parseRangeHeader(String rangeHeader, int contentLength) {
    final range = rangeHeader.replaceAll('bytes=', '');
    final parts = range.split('-');
    
    final start = int.parse(parts[0]);
    final end = parts[1].isNotEmpty ? int.parse(parts[1]) : contentLength - 1;
    
    return (start: start, end: min(end, contentLength - 1));
  }

  Future<void> stop() async {
    await _server?.close();
    await cacheManager.cleanup();
    print('$_logPrefix Video cache server stopped');
  }
}