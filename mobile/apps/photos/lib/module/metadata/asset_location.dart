import 'dart:io';

import 'package:ente_photos_platform/ente_photos_platform.dart';
import 'package:photo_manager/photo_manager.dart';

Future<LatLng?> getAssetLocation(AssetEntity asset) async {
  if (!Platform.isAndroid ||
      asset.type != AssetType.image ||
      int.parse(await PhotoManager.systemVersion()) < 29) {
    return asset.latlngAsync();
  }
  final location = await ImageLocationClient.instance.getLocation(asset.id);
  if (location == null) {
    return LatLng.fromValues(
      latitude: asset.latitude,
      longitude: asset.longitude,
    );
  }
  return LatLng(latitude: location.latitude, longitude: location.longitude);
}
