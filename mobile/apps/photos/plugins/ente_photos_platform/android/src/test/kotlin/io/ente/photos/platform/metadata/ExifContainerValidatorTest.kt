package io.ente.photos.platform.metadata

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataOutputStream
import java.io.IOException
import org.junit.Assert.assertThrows
import org.junit.Test

class ExifContainerValidatorTest {
    private val xmpKeyword = "XML:com.adobe.xmp".toByteArray(Charsets.US_ASCII) + ByteArray(5)

    @Test
    fun rejectsReportedAllocationInTruncatedPng() {
        val bytes = png("eXIf", 1229605720)
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun rejectsReportedAllocationInTruncatedWebp() {
        val bytes = webp(1229605720)
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun rejectsExifOutsideAnEmptyWebpContainer() {
        val bytes = webp(1229605720, 4)
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun acceptsPngWithoutEndChunk() {
        validate(png("eXIf", 8, ByteArray(8)).dropLast(12).toByteArray())
    }

    @Test
    fun acceptsPngWithIncompleteFinalHeader() {
        validate(png("eXIf", 8, ByteArray(8)).dropLast(5).toByteArray())
    }

    @Test
    fun acceptsPngWithTruncatedImagePayload() {
        validate(png("IDAT", 8, ByteArray(8)).dropLast(18).toByteArray())
    }

    @Test
    fun acceptsPngWithTruncatedImageCrc() {
        validate(png("IDAT", 8, ByteArray(8)).dropLast(13).toByteArray())
    }

    @Test
    fun rejectsTruncatedPngWithOverflowingImageOffset() {
        val bytes = png("IDAT", Int.MAX_VALUE)
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun acceptsExifWhenWebpDeclaresMoreBytesThanTheFileContains() {
        validate(webp(8, 1020, ByteArray(8)))
    }

    @Test
    fun acceptsExifWhenWebpDeclaresAnEmptyContainer() {
        validate(webp(8, 4, ByteArray(8)))
    }

    @Test
    fun acceptsWebpExifWithoutUnusedFinalPadding() {
        validate(webp(7, 20, ByteArray(7)))
    }

    @Test
    fun rejectsWebpImageWithoutRequiredPadding() {
        val bytes = webp(1, 14, ByteArray(1), "VP8X")
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun rejectsWebpWithOverflowingImageOffset() {
        val bytes = webp(Int.MAX_VALUE, -1, type = "VP8X")
        assertThrows(IOException::class.java) { validate(bytes, Long.MAX_VALUE) }
    }

    @Test
    fun rejectsUnsignedPngLength() {
        val bytes = png("eXIf", -1)
        assertThrows(IOException::class.java) { validate(bytes, Long.MAX_VALUE) }
    }

    @Test
    fun rejectsUnsignedWebpLengthWithoutOverflow() {
        val bytes = webp(-1)
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun boundsExifAllocationEvenWhenTheFileIsLargeEnough() {
        val bytes = png("eXIf", 16 * 1024 * 1024 + 1)
        assertThrows(IOException::class.java) { validate(bytes, 32L * 1024 * 1024) }
    }

    @Test
    fun boundsPngXmpAllocation() {
        val payload = xmpKeyword + ByteArray(16 * 1024 * 1024 + 1)
        val bytes = png("iTXt", payload.size, payload)
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun acceptsXmpAtAllocationBudget() {
        val payload = xmpKeyword + ByteArray(16 * 1024 * 1024)
        validate(png("iTXt", payload.size, payload))
    }

    @Test
    fun acceptsLargeOrdinaryText() {
        val payload = "Description".toByteArray() + ByteArray(5) + ByteArray(16 * 1024 * 1024)
        validate(png("iTXt", payload.size, payload))
    }

    @Test
    fun acceptsTruncatedOrdinaryText() {
        val keyword = "Description".toByteArray() + ByteArray(11)
        validate(png("iTXt", 1046, keyword))
    }

    @Test
    fun acceptsTruncatedXmpWithinAllocationBudget() {
        validate(png("iTXt", 1046, xmpKeyword))
    }

    @Test
    fun acceptsIncompleteXmpKeyword() {
        validate(png("iTXt", 1046, xmpKeyword.copyOf(10)).dropLast(16).toByteArray())
    }

    @Test
    fun acceptsNonzeroEndChunk() {
        validate(pngChunks(pngChunk("eXIf", 8, ByteArray(8)), pngChunk("IEND", 1, ByteArray(1))))
    }

    @Test
    fun acceptsUnusedEndChunkLengthWithoutOverflow() {
        validate(pngChunks(pngChunk("eXIf", 8, ByteArray(8)), pngChunk("IEND", Int.MAX_VALUE)))
    }

    @Test
    fun stopsCheckingWhenExifAndXmpAreComplete() {
        validate(
            pngChunks(
                pngChunk("eXIf", 8, ByteArray(8)),
                pngChunk("iTXt", xmpKeyword.size, xmpKeyword),
                pngChunk("IDAT", Int.MAX_VALUE),
            )
        )
    }

    @Test
    fun stillBoundsXmpAfterExif() {
        val bytes =
            pngChunks(pngChunk("eXIf", 8, ByteArray(8)), pngChunk("iTXt", 1229605720, xmpKeyword))
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun skipsDuplicateExifWithoutAllocating() {
        validate(pngChunks(pngChunk("eXIf", 8, ByteArray(8)), pngChunk("eXIf", 1229605720)))
    }

    @Test
    fun stillBoundsXmpAfterOrdinaryTextAndExif() {
        val keyword = "Description".toByteArray() + ByteArray(11)
        val bytes =
            pngChunks(
                pngChunk("iTXt", keyword.size, keyword),
                pngChunk("eXIf", 8, ByteArray(8)),
                pngChunk("iTXt", 1229605720, xmpKeyword),
            )
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun boundsWebpExifAllocationEvenWhenTheContainerIsLargeEnough() {
        val bytes = webp(16 * 1024 * 1024 + 1, 32 * 1024 * 1024)
        assertThrows(IOException::class.java) { validate(bytes, 32L * 1024 * 1024 + 8) }
    }

    @Test
    fun acceptsBoundedPngMetadata() {
        validate(png("eXIf", 8, ByteArray(8)))
    }

    @Test
    fun acceptsBoundedWebpMetadataWithPadding() {
        validate(webp(7, 20, ByteArray(8)))
    }

    @Test
    fun doesNotApplyPngOrWebpBoundsToJpeg() {
        validate(byteArrayOf(-1, -40, -1) + ByteArray(9))
    }

    @Test
    fun rejectsChunkWithMissingCrc() {
        val bytes = png("eXIf", 8, ByteArray(8)).dropLast(16).toByteArray()
        assertThrows(IOException::class.java) { validate(bytes) }
    }

    @Test
    fun makesProgressWhenSkipReturnsZero() {
        val bytes = png("IDAT", 16 * 1024, ByteArray(16 * 1024))
        val stream =
            object : ByteArrayInputStream(bytes) {
                override fun skip(count: Long): Long = 0
            }
        ExifContainerValidator.validate(stream, bytes.size.toLong())
    }

    private fun validate(bytes: ByteArray, fileSize: Long = bytes.size.toLong()) {
        ExifContainerValidator.validate(ByteArrayInputStream(bytes), fileSize)
    }

    private fun png(type: String, length: Int, payload: ByteArray = ByteArray(0)): ByteArray =
        pngChunks(pngChunk(type, length, payload))

    private fun pngChunks(vararg chunks: ByteArray): ByteArray {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { output ->
            output.write(byteArrayOf(-119, 80, 78, 71, 13, 10, 26, 10))
            output.writeInt(13)
            output.writeBytes("IHDR")
            output.write(ByteArray(17))
            chunks.forEach { output.write(it) }
            output.writeInt(0)
            output.writeBytes("IEND")
            output.writeInt(0)
        }
        return bytes.toByteArray()
    }

    private fun pngChunk(type: String, length: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { output ->
            output.writeInt(length)
            output.writeBytes(type)
            output.write(payload)
            output.writeInt(0)
        }
        return bytes.toByteArray()
    }

    private fun webp(
        length: Int,
        containerLength: Int = 12,
        payload: ByteArray = ByteArray(0),
        type: String = "EXIF",
    ): ByteArray {
        val bytes = ByteArrayOutputStream()
        DataOutputStream(bytes).use { output ->
            output.writeBytes("RIFF")
            output.writeInt(Integer.reverseBytes(containerLength))
            output.writeBytes("WEBP" + type)
            output.writeInt(Integer.reverseBytes(length))
            output.write(payload)
        }
        return bytes.toByteArray()
    }
}
