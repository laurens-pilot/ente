package io.ente.photos.platform.flutter

import io.ente.photos.platform.metadata.ImageLocationService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

internal class ImageLocationChannelAdapter : MethodChannel.MethodCallHandler {
    private lateinit var service: ImageLocationService
    private lateinit var channel: MethodChannel

    fun attach(binding: FlutterPlugin.FlutterPluginBinding) {
        service = ImageLocationService(binding.applicationContext)
        channel =
            MethodChannel(
                binding.binaryMessenger,
                "io.ente.photos.platform/image_location",
                StandardMethodCodec.INSTANCE,
                binding.binaryMessenger.makeBackgroundTaskQueue(),
            )
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "imageLocation.get") {
            result.notImplemented()
            return
        }
        val localID = call.argument<String>("localID")?.toLongOrNull()
        if (localID == null || localID < 0) {
            result.error("invalid_local_id", "Expected a MediaStore image ID", null)
            return
        }
        result.success(service.getLocation(localID))
    }

    fun detach() {
        channel.setMethodCallHandler(null)
    }
}
