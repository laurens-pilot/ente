package io.ente.photos.platform.metadata

import java.io.BufferedInputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.IOException
import java.io.InputStream

internal object ExifContainerValidator {
    private const val MAX_METADATA_BYTES = 16L * 1024 * 1024
    private const val PNG_EXIF = 0x65584966
    private const val PNG_ITXT = 0x69545874
    private const val PNG_END = 0x49454e44
    private const val WEBP_EXIF = 0x45584946
    private val pngSignature = byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10)
    private val pngXmpKeyword = "XML:com.adobe.xmp".toByteArray(Charsets.US_ASCII) + ByteArray(5)

    fun validate(stream: InputStream, fileSize: Long) {
        val input = DataInputStream(BufferedInputStream(stream))
        input.mark(12)
        val header = ByteArray(12)
        input.readFully(header)
        input.reset()
        when {
            header.copyOfRange(0, 8).contentEquals(pngSignature) -> validatePng(input, fileSize)
            String(header, 0, 4, Charsets.US_ASCII) == "RIFF" &&
                String(header, 8, 4, Charsets.US_ASCII) == "WEBP" -> validateWebp(input, fileSize)
        }
    }

    private fun validatePng(input: DataInputStream, fileSize: Long) {
        input.skipFully(8)
        var position = 8L
        var foundExif = false
        var foundXmp = false
        while (fileSize - position >= 8) {
            val length = input.readInt().toLong() and 0xffffffffL
            val type = input.readInt()
            if (type == PNG_END) return
            val nextPosition = position + length + 12
            if (nextPosition > Int.MAX_VALUE) {
                throw IOException("PNG chunk exceeds parser offset range")
            }
            val isExif = type == PNG_EXIF && !foundExif
            var isXmp = false
            var consumed = 0L
            if (type == PNG_ITXT && !foundXmp && length >= pngXmpKeyword.size) {
                if (fileSize - position - 8 < pngXmpKeyword.size) return
                val keyword = ByteArray(pngXmpKeyword.size)
                input.readFully(keyword)
                consumed = keyword.size.toLong()
                isXmp = keyword.contentEquals(pngXmpKeyword)
            }
            val allocationSize = if (isExif) length else if (isXmp) length - consumed else 0
            if (allocationSize > MAX_METADATA_BYTES) {
                throw IOException("PNG metadata exceeds allocation budget")
            }
            if (nextPosition > fileSize) {
                if (isExif) {
                    throw IOException("PNG metadata exceeds file bounds")
                }
                return
            }
            input.skipFully(length + 4 - consumed)
            position = nextPosition
            foundExif = foundExif || isExif
            foundXmp = foundXmp || isXmp
            if (foundExif && foundXmp) return
        }
    }

    private fun validateWebp(input: DataInputStream, fileSize: Long) {
        input.readInt()
        val containerSize = input.readUnsignedLittleEndianInt() + 8
        input.readInt()
        var position = 12L
        while (fileSize - position >= 8) {
            if (position + 8 > Int.MAX_VALUE) {
                throw IOException("WebP chunk exceeds parser offset range")
            }
            val type = input.readInt()
            val length = input.readUnsignedLittleEndianInt()
            if (type == WEBP_EXIF) {
                if (length > MAX_METADATA_BYTES) {
                    throw IOException("WebP metadata exceeds allocation budget")
                }
                if (length > fileSize - position - 8) {
                    throw IOException("WebP metadata exceeds file bounds")
                }
                return
            }
            val paddedLength = length + (length and 1L)
            val nextPosition = position + paddedLength + 8
            if (nextPosition > Int.MAX_VALUE) {
                throw IOException("WebP chunk exceeds parser offset range")
            }
            if (nextPosition > fileSize) {
                throw IOException("WebP chunk exceeds file bounds")
            }
            if (nextPosition >= containerSize) return
            input.skipFully(paddedLength)
            position = nextPosition
        }
    }

    private fun DataInputStream.readUnsignedLittleEndianInt(): Long =
        Integer.reverseBytes(readInt()).toLong() and 0xffffffffL

    private fun DataInputStream.skipFully(length: Long) {
        var remaining = length
        while (remaining > 0) {
            val skipped = skip(remaining)
            if (skipped > 0) {
                remaining -= skipped
            } else {
                if (read() == -1) throw EOFException("Incomplete image chunk")
                remaining--
            }
        }
    }
}
