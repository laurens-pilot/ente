import 'dart:io';

import 'package:flutter/services.dart';

class ImageLocationClient {
  static final instance = ImageLocationClient();
  static const _channel = MethodChannel(
    'io.ente.photos.platform/image_location',
  );

  Future<({double latitude, double longitude})?> getLocation(
    String localID,
  ) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(
        'Image location lookup is only supported on Android',
      );
    }
    final result = await _channel.invokeMapMethod<String, num>(
      'imageLocation.get',
      {'localID': localID},
    );
    if (result == null) return null;
    return (
      latitude: result['latitude']!.toDouble(),
      longitude: result['longitude']!.toDouble(),
    );
  }
}
