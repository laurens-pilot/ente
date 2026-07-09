use std::{
    any::Any,
    ffi::OsStr,
    fs::File,
    io::{BufRead, BufReader, Cursor, Read, Seek},
    panic::{self, AssertUnwindSafe},
    path::Path,
    sync::Once,
};

use ente_heic::{
    DecodeGuardrails, exif_orientation_hint, exif_orientation_hint_from_path,
    image_integration::{
        apply_exif_orientation_dynamic, register_image_decoder_hooks_with_guardrails,
    },
    path_extension_is_heif,
};
use exif::{In, Reader as ExifReader, Tag as ExifTag};
use image::{
    DynamicImage, ImageDecoder, ImageFormat, ImageReader, Limits, hooks::decoding_hook_registered,
};
use jxl_oxide::integration::register_image_decoding_hook as register_jxl_decoding_hook;
use rawler::{decoders::RawDecodeParams, imgop::develop::RawDevelop, rawsource::RawSource};
use tiff::{
    ColorType as TiffColorType,
    decoder::{Decoder as TiffDecoder, DecodingResult as TiffDecodingResult},
    tags::Tag as TiffTag,
};

use crate::{
    color_management::apply_icc_profile_to_srgb,
    error::{ImageError, ImageResult},
    types::{DecodedImage, Dimensions},
};

static IMAGE_DECODER_HOOKS_INIT: Once = Once::new();

const RAW_MAX_INPUT_BYTES: u64 = 256 * 1024 * 1024;
/// RAW development goes through a planar f32 intermediate (~12 bytes per pixel)
/// on top of the u16 mosaic and Rgb16 output, so peak memory is roughly 18
/// bytes per pixel. 200M pixels keeps headroom above the largest current
/// sensors (Phase One IQ4 at ~151MP) while bounding worst-case allocations.
const RAW_MAX_PIXELS: u128 = 200_000_000;
const RAW_EXTENSIONS: &[&str] = &[
    "3fr", "ari", "arw", "cr2", "cr3", "crm", "crw", "dcr", "dcs", "dng", "erf", "fff", "iiq",
    "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "ori", "pef", "qtk", "raf", "raw", "rw2",
    "rwl", "srw", "x3f",
];
/// Magic-byte prefixes of RAW containers that must be routed to the RAW
/// pipeline first. TIFF magic is included because most RAW formats
/// (NEF/ARW/CR2/DNG/PEF/SRW/...) are TIFF containers whose first IFD is often
/// a decodable thumbnail, so the image crate would "succeed" and silently
/// return that thumbnail. The rawler probe rejects plain TIFF files quickly,
/// letting those fall through to the image crate. The list need not be
/// exhaustive: formats missed here are still caught by the RAW extension
/// routing or by the RAW fallback after an image crate failure.
const RAW_MAGIC_PREFIXES: &[&[u8]] = &[
    b"II*\0",    // TIFF little-endian (NEF/ARW/CR2/DNG/PEF/SRW/3FR/IIQ/...)
    b"MM\0*",    // TIFF big-endian
    b"II\x1a\0", // Canon CRW
    b"IIU\0",    // Panasonic RW2/RWL
    b"IIRO",     // Olympus ORF
    b"IIRS",     // Olympus ORF
    b"MMOR",     // Olympus ORF (big-endian)
    b"FUJIFILM", // Fujifilm RAF
    b"FOVb",     // Sigma X3F
    b"\0MRM",    // Minolta MRW
];

struct DecodedDynamicImage {
    image: DynamicImage,
    icc_profile: Option<Vec<u8>>,
}

impl DecodedDynamicImage {
    fn into_srgb(self) -> DynamicImage {
        apply_icc_profile_to_srgb(self.image, self.icc_profile.as_deref())
    }
}

pub fn decode_image_from_path(image_path: &str) -> ImageResult<DecodedImage> {
    let oriented = decode_dynamic_from_path(image_path)?.into_rgb8();

    Ok(DecodedImage {
        dimensions: Dimensions {
            width: oriented.width(),
            height: oriented.height(),
        },
        rgb: oriented.into_raw(),
    })
}

pub fn decode_image_from_bytes(image_bytes: &[u8]) -> ImageResult<DecodedImage> {
    let oriented = decode_dynamic_from_bytes(image_bytes)?.into_rgb8();

    Ok(DecodedImage {
        dimensions: Dimensions {
            width: oriented.width(),
            height: oriented.height(),
        },
        rgb: oriented.into_raw(),
    })
}

/// Decode an image from a path and apply EXIF orientation.
///
/// RAW candidates go to the RAW pipeline first (see [`RAW_MAGIC_PREFIXES`] for
/// why the image crate must not see them first). How RAW failures are handled
/// depends on the strength of the RAW signal:
///
/// - Extension and magic both say RAW: the file is committed to the RAW
///   pipeline and every failure — oversized input, unmatched camera model,
///   decode/develop error — is a hard error. Falling back would let the image
///   crate decode the embedded preview of a TIFF-based RAW and silently
///   return a thumbnail-sized image.
/// - Only one signal says RAW (a `.tif` export carrying TIFF magic, or a
///   misnamed file whose magic disagrees): the RAW attempt is opportunistic
///   and any RAW failure falls back to the image crate. This matters because
///   rawler's probe dispatches TIFF containers on the EXIF `Make` tag alone,
///   so a plain TIFF exported from a camera photo can pass the probe and only
///   fail later in `raw_image()` — such files must keep decoding as TIFFs.
///
/// The size guardrail runs before the RAW source is constructed because
/// constructing it materializes the entire input (`RawSource::new` mmaps with
/// populate, `RawSource::new_from_slice` copies, and a failed probe copies
/// the buffer again for the naked-RAW lookup).
fn decode_dynamic_from_path(image_path: &str) -> ImageResult<DynamicImage> {
    let extension_is_raw = path_extension_is_raw(Path::new(image_path));
    let magic_is_raw = file_magic_looks_like_raw(image_path);
    if !extension_is_raw && !magic_is_raw {
        let decoded = decode_with_image_crate(image_path)?;
        return Ok(orient_decoded_image(decoded, image_path));
    }

    let input_bytes = std::fs::metadata(image_path)
        .map(|metadata| metadata.len())
        .unwrap_or(0);

    if extension_is_raw && magic_is_raw {
        validate_raw_input_size(input_bytes, image_path)?;
        return match decode_raw_from_path(image_path)? {
            RawDecodeOutcome::Decoded(decoded) => Ok(decoded),
            RawDecodeOutcome::ProbeRejected(probe_error) => Err(ImageError::Decode(format!(
                "'{image_path}' looks like a camera RAW but no RAW decoder matched (camera model not supported by rawler?), refusing thumbnail fallback: {probe_error}"
            ))),
        };
    }

    let raw_failure = if input_bytes <= RAW_MAX_INPUT_BYTES {
        match decode_raw_from_path(image_path) {
            Ok(RawDecodeOutcome::Decoded(decoded)) => return Ok(decoded),
            Ok(RawDecodeOutcome::ProbeRejected(probe_error)) => probe_error,
            Err(ImageError::Decode(raw_error)) => raw_error,
            Err(other) => return Err(other),
        }
    } else {
        format!("RAW decode skipped: {input_bytes} bytes exceeds {RAW_MAX_INPUT_BYTES} bytes")
    };

    match decode_with_image_crate(image_path) {
        Ok(decoded) => Ok(orient_decoded_image(decoded, image_path)),
        Err(ImageError::Decode(fallback_error)) => Err(ImageError::Decode(format!(
            "{raw_failure}; image crate fallback also failed: {fallback_error}"
        ))),
        Err(other) => Err(other),
    }
}

/// Decode an image from bytes and apply EXIF orientation.
///
/// Mirrors [`decode_dynamic_from_path`], but bytes carry no file name, so
/// there is never a second RAW signal to corroborate the magic bytes: the RAW
/// attempt is always opportunistic and any RAW failure falls back to the
/// image crate (this branch carries every plain TIFF decoded from bytes).
/// Bytes that don't look like RAW still get a RAW fallback after an image
/// crate failure, to catch RAW containers whose magic is not in
/// [`RAW_MAGIC_PREFIXES`]. Oversized input skips the RAW attempt entirely so
/// that `RawSource::new_from_slice` never copies more than
/// [`RAW_MAX_INPUT_BYTES`].
fn decode_dynamic_from_bytes(image_bytes: &[u8]) -> ImageResult<DynamicImage> {
    let within_raw_size_limit = image_bytes.len() as u64 <= RAW_MAX_INPUT_BYTES;

    if bytes_look_like_raw(image_bytes) {
        let raw_failure = if within_raw_size_limit {
            match decode_raw_from_bytes(image_bytes) {
                Ok(RawDecodeOutcome::Decoded(decoded)) => return Ok(decoded),
                Ok(RawDecodeOutcome::ProbeRejected(probe_error)) => probe_error,
                Err(ImageError::Decode(raw_error)) => raw_error,
                Err(other) => return Err(other),
            }
        } else {
            format!(
                "RAW decode skipped: {} bytes exceeds {RAW_MAX_INPUT_BYTES} bytes",
                image_bytes.len()
            )
        };

        return match decode_bytes_with_image_crate(image_bytes) {
            Ok(decoded) => Ok(orient_decoded_image_from_bytes(decoded, image_bytes)),
            Err(ImageError::Decode(fallback_error)) => Err(ImageError::Decode(format!(
                "{raw_failure}; image crate fallback also failed: {fallback_error}"
            ))),
            Err(other) => Err(other),
        };
    }

    match decode_bytes_with_image_crate(image_bytes) {
        Ok(decoded) => Ok(orient_decoded_image_from_bytes(decoded, image_bytes)),
        Err(primary_error) => {
            if !within_raw_size_limit {
                return Err(primary_error);
            }
            let raw_failure = match decode_raw_from_bytes(image_bytes) {
                Ok(RawDecodeOutcome::Decoded(decoded)) => return Ok(decoded),
                Ok(RawDecodeOutcome::ProbeRejected(probe_error)) => probe_error,
                Err(ImageError::Decode(raw_error)) => raw_error,
                Err(other) => return Err(other),
            };
            Err(ImageError::Decode(format!(
                "failed to decode image with image crate: {primary_error}; RAW fallback also failed: {raw_failure}"
            )))
        }
    }
}

fn decode_with_image_crate(image_path: &str) -> ImageResult<DynamicImage> {
    init_image_decoders();

    let reader = ImageReader::open(image_path)
        .map_err(|e| ImageError::Decode(format!("failed to open image file '{image_path}': {e}")))?
        .with_guessed_format()
        .map_err(|e| ImageError::Decode(format!("failed to guess image format: {e}")))?;
    let guessed_format = reader.format();

    match decode_reader_with_image_crate(reader) {
        Ok(decoded) => Ok(decoded.into_srgb()),
        Err(primary_error) if should_attempt_tiff_fallback(guessed_format) => {
            eprintln!(
                "[ml][decode] image crate TIFF decode failed for '{}': {}. Retrying with tiff crate fallback",
                image_path, primary_error
            );

            match decode_with_tiff_crate(image_path) {
                Ok(decoded) => Ok(decoded.into_srgb()),
                Err(ImageError::Decode(fallback_error)) => Err(ImageError::Decode(format!(
                    "failed to decode TIFF with image crate: {primary_error}; fallback with tiff crate also failed: {fallback_error}"
                ))),
                Err(other) => Err(other),
            }
        }
        Err(other) => Err(other.into()),
    }
}

fn decode_bytes_with_image_crate(image_bytes: &[u8]) -> ImageResult<DynamicImage> {
    init_image_decoders();

    let reader = ImageReader::new(Cursor::new(image_bytes))
        .with_guessed_format()
        .map_err(|e| ImageError::Decode(format!("failed to guess image format: {e}")))?;
    let guessed_format = reader.format();

    match decode_reader_with_image_crate(reader) {
        Ok(decoded) => Ok(decoded.into_srgb()),
        Err(primary_error) if should_attempt_tiff_fallback(guessed_format) => {
            match decode_tiff_from_bytes(image_bytes) {
                Ok(decoded) => Ok(decoded.into_srgb()),
                Err(ImageError::Decode(fallback_error)) => Err(ImageError::Decode(format!(
                    "failed to decode TIFF with image crate: {primary_error}; fallback with tiff crate also failed: {fallback_error}"
                ))),
                Err(other) => Err(other),
            }
        }
        Err(other) => Err(other.into()),
    }
}

fn decode_reader_with_image_crate<R>(
    reader: ImageReader<R>,
) -> image::ImageResult<DecodedDynamicImage>
where
    R: BufRead + Seek,
{
    let mut decoder = reader.into_decoder()?;
    let icc_profile = match decoder.icc_profile() {
        Ok(icc_profile) => icc_profile,
        Err(err) => {
            eprintln!("[ml][decode] failed to read embedded ICC profile: {err}");
            None
        }
    };

    let mut limits = Limits::default();
    limits.reserve(decoder.total_bytes())?;
    decoder.set_limits(limits)?;

    Ok(DecodedDynamicImage {
        image: DynamicImage::from_decoder(decoder)?,
        icc_profile,
    })
}

fn should_attempt_tiff_fallback(format: Option<ImageFormat>) -> bool {
    matches!(format, Some(ImageFormat::Tiff))
}

/// Outcome of routing an input through the RAW pipeline.
///
/// `ProbeRejected` is separated from hard errors so that callers can apply
/// their fallback policy (see [`decode_dynamic_from_path`]): in the committed
/// domain (extension and magic both say RAW) a rejection is a hard error,
/// while opportunistic callers treat rejections and decode failures alike and
/// fall back to the image crate. Size guardrails are enforced by the callers
/// before the `RawSource` is constructed, because construction materializes
/// the entire input.
enum RawDecodeOutcome {
    /// Successfully decoded, developed, and oriented.
    Decoded(DynamicImage),
    /// rawler does not recognize the input as a supported camera RAW.
    ProbeRejected(String),
}

fn decode_raw_from_path(image_path: &str) -> ImageResult<RawDecodeOutcome> {
    catch_raw_decode_panic(image_path, || {
        let source = RawSource::new(Path::new(image_path)).map_err(|e| {
            ImageError::Decode(format!("failed to open RAW image file '{image_path}': {e}"))
        })?;
        decode_raw_source_to_dynamic_image(&source, image_path)
    })
}

fn decode_raw_from_bytes(image_bytes: &[u8]) -> ImageResult<RawDecodeOutcome> {
    catch_raw_decode_panic("<bytes>", || {
        let source = RawSource::new_from_slice(image_bytes);
        decode_raw_source_to_dynamic_image(&source, "<bytes>")
    })
}

/// Decode and develop a RAW image. The returned image is already oriented:
/// EXIF orientation must come from the RAW metadata because the kamadak-exif
/// pass in [`orient_decoded_image`] cannot read most RAW containers
/// (CR3/RAF/RW2/ORF have non-TIFF magic or store EXIF in proprietary boxes).
fn decode_raw_source_to_dynamic_image(
    source: &RawSource,
    source_name: &str,
) -> ImageResult<RawDecodeOutcome> {
    let decode_params = RawDecodeParams::default();
    let decoder = match rawler::get_decoder(source) {
        Ok(decoder) => decoder,
        Err(probe_error) => {
            return Ok(RawDecodeOutcome::ProbeRejected(format!(
                "input not recognized as a supported camera RAW: {probe_error}"
            )));
        }
    };

    let raw_image = decoder
        .raw_image(source, &decode_params, false)
        .map_err(|e| ImageError::Decode(format!("failed to decode RAW image: {e}")))?;
    validate_raw_dimensions(raw_image.width, raw_image.height, source_name)?;

    let developed = RawDevelop::default()
        .develop_intermediate(&raw_image)
        .map_err(|e| ImageError::Decode(format!("failed to develop RAW image: {e}")))?;
    let image = developed.to_dynamic_image().ok_or_else(|| {
        ImageError::Decode(format!(
            "failed to materialize developed RAW image for '{source_name}'"
        ))
    })?;
    validate_raw_dimensions(image.width() as usize, image.height() as usize, source_name)?;

    // Orientation is best effort: a metadata read failure should not discard
    // an otherwise successfully developed image.
    let orientation = match decoder.raw_metadata(source, &decode_params) {
        Ok(metadata) => metadata
            .exif
            .orientation
            .and_then(|value| u8::try_from(value).ok())
            .filter(|value| (1..=8).contains(value)),
        Err(err) => {
            eprintln!(
                "[ml][decode] failed to read RAW metadata for '{source_name}': {err}; skipping orientation"
            );
            None
        }
    };

    Ok(RawDecodeOutcome::Decoded(match orientation {
        Some(orientation) => apply_exif_orientation_dynamic(image, orientation),
        None => image,
    }))
}

fn catch_raw_decode_panic<T, F>(source_name: &str, decode: F) -> ImageResult<T>
where
    F: FnOnce() -> ImageResult<T>,
{
    match panic::catch_unwind(AssertUnwindSafe(decode)) {
        Ok(result) => result,
        Err(payload) => Err(ImageError::Decode(format!(
            "RAW decoder panicked while decoding '{source_name}': {}",
            panic_payload_message(payload)
        ))),
    }
}

fn validate_raw_input_size(input_bytes: u64, source_name: &str) -> ImageResult<()> {
    if input_bytes > RAW_MAX_INPUT_BYTES {
        return Err(ImageError::Decode(format!(
            "RAW image '{source_name}' is too large to decode safely: {input_bytes} bytes exceeds {RAW_MAX_INPUT_BYTES} bytes"
        )));
    }
    Ok(())
}

fn validate_raw_dimensions(width: usize, height: usize, source_name: &str) -> ImageResult<()> {
    if width == 0 || height == 0 {
        return Err(ImageError::Decode(format!(
            "RAW image '{source_name}' decoded to invalid dimensions {width}x{height}"
        )));
    }

    let pixels = (width as u128) * (height as u128);
    if pixels > RAW_MAX_PIXELS {
        return Err(ImageError::Decode(format!(
            "RAW image '{source_name}' is too large to decode safely: {width}x{height} exceeds {RAW_MAX_PIXELS} pixels"
        )));
    }

    Ok(())
}

fn panic_payload_message(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        return (*message).to_string();
    }
    if let Some(message) = payload.downcast_ref::<String>() {
        return message.clone();
    }
    "unknown panic payload".to_string()
}

fn decode_with_tiff_crate(image_path: &str) -> ImageResult<DecodedDynamicImage> {
    let file = File::open(image_path)
        .map_err(|e| ImageError::Decode(format!("failed to open TIFF file '{image_path}': {e}")))?;
    let mut decoder = TiffDecoder::new(BufReader::new(file))
        .map_err(|e| ImageError::Decode(format!("failed to initialize TIFF decoder: {e}")))?;
    let (width, height) = decoder
        .dimensions()
        .map_err(|e| ImageError::Decode(format!("failed to read TIFF dimensions: {e}")))?;
    let color_type = decoder
        .colortype()
        .map_err(|e| ImageError::Decode(format!("failed to read TIFF color type: {e}")))?;
    let icc_profile = decoder.get_tag_u8_vec(TiffTag::IccProfile).ok();
    let decoded = decoder
        .read_image()
        .map_err(|e| ImageError::Decode(format!("failed to decode TIFF image data: {e}")))?;

    Ok(DecodedDynamicImage {
        image: dynamic_image_from_tiff(image_path, width, height, color_type, decoded)?,
        icc_profile,
    })
}

fn decode_tiff_from_bytes(image_bytes: &[u8]) -> ImageResult<DecodedDynamicImage> {
    let mut decoder = TiffDecoder::new(Cursor::new(image_bytes))
        .map_err(|e| ImageError::Decode(format!("failed to initialize TIFF decoder: {e}")))?;
    let (width, height) = decoder
        .dimensions()
        .map_err(|e| ImageError::Decode(format!("failed to read TIFF dimensions: {e}")))?;
    let color_type = decoder
        .colortype()
        .map_err(|e| ImageError::Decode(format!("failed to read TIFF color type: {e}")))?;
    let icc_profile = decoder.get_tag_u8_vec(TiffTag::IccProfile).ok();
    let decoded = decoder
        .read_image()
        .map_err(|e| ImageError::Decode(format!("failed to decode TIFF image data: {e}")))?;

    Ok(DecodedDynamicImage {
        image: dynamic_image_from_tiff("<bytes>", width, height, color_type, decoded)?,
        icc_profile,
    })
}

fn dynamic_image_from_tiff(
    image_path: &str,
    width: u32,
    height: u32,
    color_type: TiffColorType,
    decoded: TiffDecodingResult,
) -> ImageResult<DynamicImage> {
    match (color_type, decoded) {
        (TiffColorType::Gray(8), TiffDecodingResult::U8(data)) => {
            let image = image::GrayImage::from_raw(width, height, data)
                .ok_or_else(|| tiff_buffer_mismatch_error(image_path, width, height, "Gray(8)"))?;
            Ok(DynamicImage::ImageLuma8(image))
        }
        (TiffColorType::GrayA(8), TiffDecodingResult::U8(data)) => {
            let image = image::GrayAlphaImage::from_raw(width, height, data)
                .ok_or_else(|| tiff_buffer_mismatch_error(image_path, width, height, "GrayA(8)"))?;
            Ok(DynamicImage::ImageLumaA8(image))
        }
        (TiffColorType::RGB(8), TiffDecodingResult::U8(data)) => {
            let image = image::RgbImage::from_raw(width, height, data)
                .ok_or_else(|| tiff_buffer_mismatch_error(image_path, width, height, "RGB(8)"))?;
            Ok(DynamicImage::ImageRgb8(image))
        }
        (TiffColorType::RGBA(8), TiffDecodingResult::U8(data)) => {
            let image = image::RgbaImage::from_raw(width, height, data)
                .ok_or_else(|| tiff_buffer_mismatch_error(image_path, width, height, "RGBA(8)"))?;
            Ok(DynamicImage::ImageRgba8(image))
        }
        (TiffColorType::Gray(16), TiffDecodingResult::U16(data)) => {
            let image = image::ImageBuffer::from_raw(width, height, data)
                .ok_or_else(|| tiff_buffer_mismatch_error(image_path, width, height, "Gray(16)"))?;
            Ok(DynamicImage::ImageLuma16(image))
        }
        (TiffColorType::GrayA(16), TiffDecodingResult::U16(data)) => {
            let image = image::ImageBuffer::from_raw(width, height, data).ok_or_else(|| {
                tiff_buffer_mismatch_error(image_path, width, height, "GrayA(16)")
            })?;
            Ok(DynamicImage::ImageLumaA16(image))
        }
        (TiffColorType::RGB(16), TiffDecodingResult::U16(data)) => {
            let image = image::ImageBuffer::from_raw(width, height, data)
                .ok_or_else(|| tiff_buffer_mismatch_error(image_path, width, height, "RGB(16)"))?;
            Ok(DynamicImage::ImageRgb16(image))
        }
        (TiffColorType::RGBA(16), TiffDecodingResult::U16(data)) => {
            let image = image::ImageBuffer::from_raw(width, height, data)
                .ok_or_else(|| tiff_buffer_mismatch_error(image_path, width, height, "RGBA(16)"))?;
            Ok(DynamicImage::ImageRgba16(image))
        }
        (observed_color_type, observed_result_type) => Err(ImageError::Decode(format!(
            "unsupported TIFF pixel format for '{image_path}': color_type={observed_color_type:?}, sample_type={}",
            tiff_result_type_name(&observed_result_type)
        ))),
    }
}

fn tiff_buffer_mismatch_error(
    image_path: &str,
    width: u32,
    height: u32,
    color_type: &str,
) -> ImageError {
    ImageError::Decode(format!(
        "decoded TIFF buffer length does not match dimensions for '{image_path}': {width}x{height}, color_type={color_type}"
    ))
}

fn tiff_result_type_name(result: &TiffDecodingResult) -> &'static str {
    match result {
        TiffDecodingResult::U8(_) => "u8",
        TiffDecodingResult::U16(_) => "u16",
        _ => "unsupported",
    }
}

fn init_image_decoders() {
    IMAGE_DECODER_HOOKS_INIT.call_once(|| {
        let registration = register_image_decoder_hooks_with_guardrails(DecodeGuardrails {
            max_input_bytes: Some(128 * 1024 * 1024),
            max_pixels: Some(256_000_000),
            max_temp_spool_bytes: Some(256 * 1024 * 1024),
            temp_spool_directory: None,
        });

        let heic_hook_active = decoding_hook_registered(OsStr::new("heic"));
        let heif_hook_active = decoding_hook_registered(OsStr::new("heif"));
        let avif_hook_active = decoding_hook_registered(OsStr::new("avif"));
        let jxl_registered_now = register_jxl_decoding_hook();
        let jxl_hook_active = decoding_hook_registered(OsStr::new("jxl"));
        let has_heif_family_support = heic_hook_active || heif_hook_active;

        if !has_heif_family_support {
            eprintln!(
                "[ml][decode] failed to activate HEIF/HEIC decoder hooks; registration_result=(heic:{}, heif:{}, avif:{}), active_hooks=(heic:{}, heif:{}, avif:{})",
                registration.heic_decoder_hook_registered,
                registration.heif_decoder_hook_registered,
                registration.avif_decoder_hook_registered,
                heic_hook_active,
                heif_hook_active,
                avif_hook_active,
            );
        } else if !registration.all_decoder_hooks_registered() {
            eprintln!(
                "[ml][decode] ente_heic decoder hooks only partially registered (usually because another initializer registered first); registration_result=(heic:{}, heif:{}, avif:{}), active_hooks=(heic:{}, heif:{}, avif:{})",
                registration.heic_decoder_hook_registered,
                registration.heif_decoder_hook_registered,
                registration.avif_decoder_hook_registered,
                heic_hook_active,
                heif_hook_active,
                avif_hook_active,
            );
        }

        debug_assert!(
            heic_hook_active || heif_hook_active || avif_hook_active,
            "no ente_heic image decoder hooks are active"
        );

        if !jxl_hook_active {
            eprintln!(
                "[ml][decode] failed to activate JPEG XL decoder hook; registered_now={jxl_registered_now}, active_hook={jxl_hook_active}"
            );
        }

        debug_assert!(jxl_hook_active, "JPEG XL image decoder hook is not active");
    });
}

fn orient_decoded_image(image: DynamicImage, image_path: &str) -> DynamicImage {
    let path = Path::new(image_path);
    if path_extension_is_heif(path) {
        return apply_heif_exif_orientation_hint(image, path);
    }

    apply_standard_exif_orientation(image, image_path)
}

fn orient_decoded_image_from_bytes(image: DynamicImage, image_bytes: &[u8]) -> DynamicImage {
    if bytes_look_like_heif(image_bytes) {
        return apply_heif_exif_orientation_hint_from_bytes(image, image_bytes);
    }

    apply_standard_exif_orientation_from_bytes(image, image_bytes)
}

fn apply_heif_exif_orientation_hint(image: DynamicImage, image_path: &Path) -> DynamicImage {
    let hint = match exif_orientation_hint_from_path(image_path) {
        Ok(hint) => hint,
        Err(err) => {
            eprintln!(
                "[ml][decode] failed to inspect HEIF EXIF orientation for '{}': {}",
                image_path.display(),
                err
            );
            return image;
        }
    };

    if let Some(orientation) = hint.orientation_to_apply() {
        return apply_exif_orientation_dynamic(image, orientation);
    }

    image
}

fn apply_heif_exif_orientation_hint_from_bytes(
    image: DynamicImage,
    image_bytes: &[u8],
) -> DynamicImage {
    let hint = exif_orientation_hint(image_bytes);

    if let Some(orientation) = hint.orientation_to_apply() {
        return apply_exif_orientation_dynamic(image, orientation);
    }

    image
}

fn apply_standard_exif_orientation(image: DynamicImage, image_path: &str) -> DynamicImage {
    match read_exif_orientation_from_path(image_path) {
        Some(orientation) => apply_exif_orientation_dynamic(image, orientation),
        None => image,
    }
}

fn apply_standard_exif_orientation_from_bytes(
    image: DynamicImage,
    image_bytes: &[u8],
) -> DynamicImage {
    match read_exif_orientation_from_bytes(image_bytes) {
        Some(orientation) => apply_exif_orientation_dynamic(image, orientation),
        None => image,
    }
}

fn read_exif_orientation_from_path(image_path: &str) -> Option<u8> {
    let file = File::open(image_path).ok()?;
    let mut reader = BufReader::new(file);
    let exif = ExifReader::new().read_from_container(&mut reader).ok()?;

    exif.get_field(ExifTag::Orientation, In::PRIMARY)
        .and_then(|field| field.value.get_uint(0))
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (1..=8).contains(value))
}

fn read_exif_orientation_from_bytes(image_bytes: &[u8]) -> Option<u8> {
    let mut reader = BufReader::new(Cursor::new(image_bytes));
    let exif = ExifReader::new().read_from_container(&mut reader).ok()?;

    exif.get_field(ExifTag::Orientation, In::PRIMARY)
        .and_then(|field| field.value.get_uint(0))
        .and_then(|value| u8::try_from(value).ok())
        .filter(|value| (1..=8).contains(value))
}

fn bytes_look_like_heif(image_bytes: &[u8]) -> bool {
    if image_bytes.len() < 12 || &image_bytes[4..8] != b"ftyp" {
        return false;
    }

    matches!(
        &image_bytes[8..12],
        b"heic"
            | b"heix"
            | b"hevc"
            | b"hevx"
            | b"heim"
            | b"heis"
            | b"hevm"
            | b"hevs"
            | b"mif1"
            | b"msf1"
    )
}

fn path_extension_is_raw(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| {
            RAW_EXTENSIONS
                .iter()
                .any(|raw_extension| extension.eq_ignore_ascii_case(raw_extension))
        })
}

fn bytes_look_like_raw(image_bytes: &[u8]) -> bool {
    if image_bytes.len() >= 12 && &image_bytes[4..8] == b"ftyp" {
        // Canon CR3 is an ISO-BMFF container with the "crx " brand.
        return &image_bytes[8..12] == b"crx ";
    }

    RAW_MAGIC_PREFIXES
        .iter()
        .any(|prefix| image_bytes.starts_with(prefix))
}

fn file_magic_looks_like_raw(image_path: &str) -> bool {
    let Ok(file) = File::open(image_path) else {
        return false;
    };

    let mut magic = Vec::with_capacity(16);
    if file.take(16).read_to_end(&mut magic).is_err() {
        return false;
    }

    bytes_look_like_raw(&magic)
}

#[cfg(test)]
mod tests {
    use std::{ffi::OsStr, io::Cursor, panic, path::Path};

    use image::hooks::decoding_hook_registered;
    use image::{
        ColorType, ImageEncoder, ImageFormat,
        codecs::{png::PngEncoder, tiff::TiffEncoder},
    };
    use moxcms::ColorProfile;

    use super::{
        ImageResult, bytes_look_like_heif, bytes_look_like_raw, catch_raw_decode_panic,
        decode_image_from_bytes, decode_image_from_path, init_image_decoders,
        path_extension_is_raw, should_attempt_tiff_fallback,
    };

    #[test]
    fn attempts_tiff_fallback_for_tiff_format() {
        assert!(should_attempt_tiff_fallback(Some(ImageFormat::Tiff)));
    }

    #[test]
    fn skips_tiff_fallback_for_non_tiff_formats() {
        assert!(!should_attempt_tiff_fallback(None));
        assert!(!should_attempt_tiff_fallback(Some(ImageFormat::Jpeg)));
        assert!(!should_attempt_tiff_fallback(Some(ImageFormat::Png)));
        assert!(!should_attempt_tiff_fallback(Some(ImageFormat::Avif)));
    }

    #[test]
    fn detects_heif_brand_in_bytes() {
        let bytes = b"\0\0\0\x18ftypheic\0\0\0\0";

        assert!(bytes_look_like_heif(bytes));
    }

    #[test]
    fn skips_non_heif_bytes() {
        assert!(!bytes_look_like_heif(b"not an image"));
    }

    #[test]
    fn detects_raw_file_extensions_case_insensitively() {
        assert!(path_extension_is_raw(Path::new("photo.CR3")));
        assert!(path_extension_is_raw(Path::new("photo.dng")));
        assert!(path_extension_is_raw(Path::new("photo.3FR")));
        assert!(!path_extension_is_raw(Path::new("photo.jpg")));
        assert!(!path_extension_is_raw(Path::new("photo")));
    }

    #[test]
    fn detects_raw_magic_bytes() {
        assert!(bytes_look_like_raw(b"II*\0rest")); // TIFF LE (NEF/ARW/CR2/DNG)
        assert!(bytes_look_like_raw(b"MM\0*rest")); // TIFF BE
        assert!(bytes_look_like_raw(b"IIU\0rest")); // Panasonic RW2
        assert!(bytes_look_like_raw(b"IIRO rest")); // Olympus ORF
        assert!(bytes_look_like_raw(b"FUJIFILMCCD-RAW")); // Fujifilm RAF
        assert!(bytes_look_like_raw(b"\0\0\0\x18ftypcrx \0\0\0\0")); // Canon CR3

        assert!(!bytes_look_like_raw(b"\0\0\0\x18ftypheic\0\0\0\0")); // HEIC
        assert!(!bytes_look_like_raw(b"\x89PNG\r\n\x1a\n"));
        assert!(!bytes_look_like_raw(b"\xff\xd8\xff\xe0")); // JPEG
        assert!(!bytes_look_like_raw(b""));
    }

    #[test]
    fn plain_tiff_bytes_fall_through_to_image_crate() {
        // TIFF magic routes to the RAW pipeline first; a plain TIFF must be
        // rejected by the rawler probe and still decode via the image crate.
        let mut encoded = Vec::new();
        TiffEncoder::new(Cursor::new(&mut encoded))
            .write_image(&[10u8, 20, 30], 1, 1, ColorType::Rgb8.into())
            .unwrap();
        assert!(bytes_look_like_raw(&encoded));

        let decoded = decode_image_from_bytes(&encoded).unwrap();

        assert_eq!(decoded.dimensions.width, 1);
        assert_eq!(decoded.dimensions.height, 1);
        assert_eq!(decoded.rgb, vec![10, 20, 30]);
    }

    #[test]
    fn misnamed_raw_extension_falls_back_to_image_crate() {
        let mut png = Vec::new();
        PngEncoder::new(&mut png)
            .write_image(&[9u8, 8, 7], 1, 1, ColorType::Rgb8.into())
            .unwrap();
        let path = std::env::temp_dir().join(format!(
            "ente_image_misnamed_{}_{:?}.dng",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::write(&path, &png).unwrap();

        let decoded = decode_image_from_path(path.to_str().unwrap());
        std::fs::remove_file(&path).ok();

        let decoded = decoded.expect("misnamed PNG with RAW extension should fall back");
        assert_eq!(decoded.dimensions.width, 1);
        assert_eq!(decoded.dimensions.height, 1);
        assert_eq!(decoded.rgb, vec![9, 8, 7]);
    }

    #[test]
    fn camera_exif_tiff_bytes_still_decode_as_tiff() {
        // A plain TIFF exported from a camera photo keeps the camera's EXIF
        // Make/Model tags. rawler's probe dispatches TIFF containers on the
        // Make tag alone, so it may accept this file as a Sony ARW and only
        // fail once actual RAW data is requested. The RAW attempt from bytes
        // is opportunistic, so the file must still decode via the image crate.
        let tiff_bytes = encode_rgb8_tiff_with_camera_exif(&[40, 50, 60], "SONY", "ILCE-7M3");
        assert!(bytes_look_like_raw(&tiff_bytes));

        let decoded = decode_image_from_bytes(&tiff_bytes).unwrap();

        assert_eq!(decoded.dimensions.width, 1);
        assert_eq!(decoded.dimensions.height, 1);
        assert_eq!(decoded.rgb, vec![40, 50, 60]);
    }

    fn encode_rgb8_tiff_with_camera_exif(pixel: &[u8; 3], make: &str, model: &str) -> Vec<u8> {
        use tiff::{
            encoder::{TiffEncoder as TiffCrateEncoder, colortype::RGB8},
            tags::Tag,
        };

        let mut encoded = Cursor::new(Vec::new());
        let mut tiff_encoder = TiffCrateEncoder::new(&mut encoded).unwrap();
        let mut image = tiff_encoder.new_image::<RGB8>(1, 1).unwrap();
        image.encoder().write_tag(Tag::Make, make).unwrap();
        image.encoder().write_tag(Tag::Model, model).unwrap();
        image.write_data(pixel).unwrap();
        encoded.into_inner()
    }

    #[test]
    fn unrecognized_raw_with_raw_extension_and_magic_errors_instead_of_thumbnail() {
        // A plain TIFF named .nef stands in for a RAW from a camera model
        // missing in rawler's database: extension and magic both say RAW, the
        // probe rejects it. This must be a hard error, not an image crate
        // fallback that could decode an embedded preview.
        let mut tiff = Vec::new();
        TiffEncoder::new(Cursor::new(&mut tiff))
            .write_image(&[10u8, 20, 30], 1, 1, ColorType::Rgb8.into())
            .unwrap();
        let path = std::env::temp_dir().join(format!(
            "ente_image_unknown_camera_{}_{:?}.nef",
            std::process::id(),
            std::thread::current().id()
        ));
        std::fs::write(&path, &tiff).unwrap();

        let result = decode_image_from_path(path.to_str().unwrap());
        std::fs::remove_file(&path).ok();

        let error = result.expect_err("unrecognized RAW-claiming file should not decode");
        assert!(error.to_string().contains("refusing thumbnail fallback"));
    }

    #[test]
    fn raw_decode_panics_are_returned_as_decode_errors() {
        let previous_hook = panic::take_hook();
        panic::set_hook(Box::new(|_| {}));
        let result: ImageResult<()> =
            catch_raw_decode_panic("panic.raw", || panic!("synthetic panic"));
        panic::set_hook(previous_hook);

        let error = result.expect_err("panic should be converted to an error");
        assert!(error.to_string().contains("RAW decoder panicked"));
        assert!(error.to_string().contains("synthetic panic"));
    }

    #[test]
    fn registers_jxl_decoder_hook() {
        init_image_decoders();

        assert!(decoding_hook_registered(OsStr::new("jxl")));
    }

    #[test]
    fn decode_applies_embedded_png_display_p3_profile() {
        let display_p3_icc = ColorProfile::new_display_p3().encode().unwrap();
        let png = encode_rgb8_png_with_icc(&[128, 0, 0], display_p3_icc);

        let decoded = decode_image_from_bytes(&png).unwrap();

        assert_eq!(decoded.dimensions.width, 1);
        assert_eq!(decoded.dimensions.height, 1);
        assert!(
            decoded.rgb[0] > 128,
            "expected red channel to move into sRGB"
        );
        assert_eq!(decoded.rgb[1], 0);
        assert_eq!(decoded.rgb[2], 0);
    }

    #[test]
    fn decode_leaves_embedded_png_srgb_profile_unchanged() {
        let srgb_icc = ColorProfile::new_srgb().encode().unwrap();
        let png = encode_rgb8_png_with_icc(&[128, 64, 32], srgb_icc);

        let decoded = decode_image_from_bytes(&png).unwrap();

        assert_eq!(decoded.rgb, vec![128, 64, 32]);
    }

    fn encode_rgb8_png_with_icc(pixel: &[u8; 3], icc_profile: Vec<u8>) -> Vec<u8> {
        let mut encoded = Vec::new();
        let mut encoder = PngEncoder::new(&mut encoded);
        encoder.set_icc_profile(icc_profile).unwrap();
        encoder
            .write_image(pixel, 1, 1, ColorType::Rgb8.into())
            .unwrap();
        encoded
    }
}
