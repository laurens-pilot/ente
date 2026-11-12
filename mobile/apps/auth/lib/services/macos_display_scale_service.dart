import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';

class MacOSDisplayScaleService {
  static const _channel = MethodChannel('io.ente.auth/display_scale');
  static final _logger = Logger('DisplayScale');
  static Map<String, dynamic>? _pendingGeometry;
  static bool _frameSamplePending = false;

  static Future<void> init() async {
    if (!Platform.isMacOS) return;

    _channel.setMethodCallHandler((call) async {
      if (call.method != 'geometry' || call.arguments is! Map) return;
      final geometry = Map<String, dynamic>.from(call.arguments as Map);
      _record(geometry, sample: 'received');
      _pendingGeometry = geometry;
      if (_frameSamplePending) return;
      _frameSamplePending = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _frameSamplePending = false;
        final pending = _pendingGeometry;
        _pendingGeometry = null;
        if (pending != null) _record(pending, sample: 'frame');
      });
    });

    try {
      await _channel.invokeMethod<void>('start');
    } catch (error, stack) {
      _logger.warning(
        'Could not start native display scale diagnostics',
        error,
        stack,
      );
    }
  }

  static void _record(Map<String, dynamic> geometry, {required String sample}) {
    _logger.info(
      jsonEncode({
        'sample': sample,
        'native': geometry,
        'flutterViews': WidgetsBinding.instance.platformDispatcher.views
            .map(
              (view) => {
                'viewId': view.viewId,
                'devicePixelRatio': view.devicePixelRatio,
                'physicalWidth': view.physicalSize.width,
                'physicalHeight': view.physicalSize.height,
              },
            )
            .toList(),
      }),
    );
  }
}
