package io.ente.photos.platform.metadata

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import androidx.exifinterface.media.ExifInterface

internal class ImageLocationService(private val context: Context) {
    fun getLocation(localID: Long): Map<String, Double>? {
        return try {
            val assetUri =
                ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, localID)
            val uri =
                if (
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        context.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) ==
                            PackageManager.PERMISSION_GRANTED
                ) {
                    MediaStore.setRequireOriginal(assetUri)
                } else {
                    assetUri
                }
            val descriptor = context.contentResolver.openFileDescriptor(uri, "r") ?: return null
            ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
                ExifContainerValidator.validate(input, input.channel.size())
                input.channel.position(0)
                val location = ExifInterface(input).latLong ?: return null
                val latitude = location[0]
                val longitude = location[1]
                if (
                    !latitude.isFinite() ||
                        !longitude.isFinite() ||
                        latitude !in -90.0..90.0 ||
                        longitude !in -180.0..180.0
                ) {
                    return null
                }
                mapOf("latitude" to latitude, "longitude" to longitude)
            }
        } catch (_: OutOfMemoryError) {
            null
        } catch (_: Exception) {
            null
        }
    }
}
