import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:logging/logging.dart';

class MetadataHandler {
  static final Logger _logger = Logger('MetadataHandler');
  final String cachePath;
  final String metadataPath;

  MetadataHandler(this.cachePath)
      : metadataPath = path.join(cachePath, 'metadata.json');

  Future<Map<String, dynamic>> readMetadata() async {
    _logger.fine('Reading metadata from $metadataPath');
    
    final file = File(metadataPath);
    if (!await file.exists()) {
      _logger.fine('Metadata file does not exist, returning empty metadata');
      return {};
    }
    
    try {
      final content = await file.readAsString();
      _logger.finer('Successfully read metadata file');
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e, stackTrace) {
      _logger.warning('Failed to read metadata', e, stackTrace);
      return {};
    }
  }

  Future<void> updateMetadata(Map<String, dynamic> metadata) async {
    _logger.fine('Updating metadata at $metadataPath');
    
    try {
      final file = File(metadataPath);
      _logger.finer('Creating metadata file if not exists');
      await file.create(recursive: true);
      
      final content = jsonEncode(metadata);
      _logger.finer('Writing metadata content (${content.length} bytes)');
      await file.writeAsString(content);
      
      _logger.fine('Successfully updated metadata at $metadataPath');
    } catch (e, stackTrace) {
      _logger.severe('Failed to update metadata', e, stackTrace);
      rethrow;
    }
  }

  Future<void> updateContentType(String contentType) async {
    final metadata = await readMetadata();
    metadata['content-type'] = contentType;
    await updateMetadata(metadata);
  }

  Future<void> updateContentLength(int contentLength) async {
    final metadata = await readMetadata();
    metadata['content-length'] = contentLength;
    await updateMetadata(metadata);
  }

  Future<String?> getContentType() async {
    final metadata = await readMetadata();
    return metadata['content-type'];
  }

  Future<int?> getContentLength() async {
    final metadata = await readMetadata();
    return metadata['content-length'];
  }
}