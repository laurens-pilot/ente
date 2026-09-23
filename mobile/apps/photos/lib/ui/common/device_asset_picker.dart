import "dart:async";
import "dart:collection";

import "package:flutter/foundation.dart";
import "package:flutter/material.dart";
import "package:wechat_assets_picker/wechat_assets_picker.dart";

Future<List<AssetEntity>?> pickDeviceAssets(
  BuildContext context, {
  required int maxAssets,
  required AssetPickerTextDelegate textDelegate,
}) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) {
    return AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        keepScrollOffset: true,
        maxAssets: maxAssets,
        textDelegate: textDelegate,
        gridCount: 6,
        pageSize: 120,
      ),
    );
  }

  final permission = await AssetPicker.permissionCheck();
  if (!context.mounted) return null;
  final provider = _QueuedAssetPickerProvider(maxAssets: maxAssets);
  final delegate = DefaultAssetPickerBuilderDelegate(
    provider: provider,
    initialPermission: permission,
    textDelegate: textDelegate,
    locale: Localizations.maybeLocaleOf(context),
    gridCount: 6,
  );
  final result = await AssetPicker.pickAssetsWithDelegate(
    context,
    delegate: delegate,
  );
  return result
      ?.map((asset) => asset is _QueuedAssetEntity ? asset.original : asset)
      .toList();
}

class _QueuedAssetPickerProvider extends DefaultAssetPickerProvider {
  _QueuedAssetPickerProvider({required super.maxAssets})
    : super(pageSize: 120, requestType: RequestType.common);

  static final _pending = Queue<_AvailabilityRequest>();
  static bool _running = false;

  @override
  void notifyListeners() {
    for (var i = 0; i < currentAssets.length; i++) {
      final asset = currentAssets[i];
      if (asset is! _QueuedAssetEntity) {
        currentAssets[i] = _QueuedAssetEntity(asset, this);
      }
    }
    super.notifyListeners();
  }

  Future<bool> _check(Future<bool> Function() check) {
    if (!mounted) return Future.value(false);
    final request = _AvailabilityRequest(this, check);
    _pending.add(request);
    unawaited(_drain());
    return request.result.future;
  }

  @override
  void dispose() {
    _pending.removeWhere((request) {
      if (request.owner != this) return false;
      request.result.complete(false);
      return true;
    });
    super.dispose();
  }

  static Future<void> _drain() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final request = _pending.removeFirst();
        try {
          request.result.complete(await request.check());
        } catch (error, stack) {
          request.result.completeError(error, stack);
        }
      }
    } finally {
      _running = false;
    }
  }
}

class _AvailabilityRequest {
  _AvailabilityRequest(this.owner, this.check);

  final _QueuedAssetPickerProvider owner;
  final Future<bool> Function() check;
  final result = Completer<bool>();
}

class _QueuedAssetEntity extends AssetEntity {
  _QueuedAssetEntity(this.original, this._provider)
    : super(
        id: original.id,
        typeInt: original.typeInt,
        width: original.width,
        height: original.height,
        duration: original.duration,
        orientation: original.orientation,
        isFavorite: original.isFavorite,
        isTrashed: original.isTrashed,
        title: original.title,
        createDateSecond: original.createDateSecond,
        modifiedDateSecond: original.modifiedDateSecond,
        relativePath: original.relativePath,
        latLng: original.latLng,
        mimeType: original.mimeType,
        subtype: original.subtype,
      );

  final AssetEntity original;
  final _QueuedAssetPickerProvider _provider;

  @override
  Future<bool> isLocallyAvailable({
    bool isOrigin = false,
    bool withSubtype = false,
    PMDarwinAVFileType? darwinFileType,
  }) {
    return _provider._check(
      () => original.isLocallyAvailable(
        isOrigin: isOrigin,
        withSubtype: withSubtype,
        darwinFileType: darwinFileType,
      ),
    );
  }
}
