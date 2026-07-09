use std::{
    any::Any,
    ffi::OsStr,
    fs::File,
    io::{BufRead, BufReader, Cursor, Seek},
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
const RAW_MAX_PIXELS: u128 = 256_000_000;
const RAW_EXTENSIONS: &[&str] = &[
    "3fr", "ari", "arw", "cr2", "cr3", "crm", "crw", "dcr", "dcs", "dng", "erf", "fff", "iiq",
    "kdc", "mef", "mos", "mrw", "nef", "nrw", "orf", "ori", "pef", "qtk", "raf", "raw", "rw2",
    "rwl", "srw", "x3f",
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
    let decoded_dynamic = decode_dynamic_from_path(image_path)?;
    let oriented = orient_decoded_image(decoded_dynamic, image_path).into_rgb8();

    Ok(DecodedImage {
        dimensions: Dimensions {
            width: oriented.width(),
            height: oriented.height(),
        },
        rgb: oriented.into_raw(),
    })
}

pub fn decode_image_from_bytes(image_bytes: &[u8]) -> ImageResult<DecodedImage> {
    let decoded_dynamic = decode_dynamic_from_bytes(image_bytes)?;
    let oriented = orient_decoded_image_from_bytes(decoded_dynamic, image_bytes).into_rgb8();

    Ok(DecodedImage {
        dimensions: Dimensions {
            width: oriented.width(),
            height: oriented.height(),
        },
        rgb: oriented.into_raw(),
    })
}

fn decode_dynamic_from_path(image_path: &str) -> ImageResult<DynamicImage> {
    if path_extension_is_raw(Path::new(image_path)) {
        return decode_raw_from_path(image_path);
    }

    decode_with_image_crate(image_path)
}

fn decode_dynamic_from_bytes(image_bytes: &[u8]) -> ImageResult<DynamicImage> {
    match decode_bytes_with_image_crate(image_bytes) {
        Ok(decoded) => Ok(decoded),
        Err(primary_error) => match decode_raw_from_bytes(image_bytes) {
            Ok(decoded) => Ok(decoded),
            Err(ImageError::Decode(raw_error)) => Err(ImageError::Decode(format!(
                "failed to decode image with image crate: {primary_error}; RAW fallback also failed: {raw_error}"
            ))),
            Err(other) => Err(other),
        },
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

fn decode_raw_from_path(image_path: &str) -> ImageResult<DynamicImage> {
    catch_raw_decode_panic(image_path, || {
        validate_raw_input_size_from_path(image_path)?;
        let source = RawSource::new(Path::new(image_path)).map_err(|e| {
            ImageError::Decode(format!("failed to open RAW image file '{image_path}': {e}"))
        })?;
        decode_raw_source_to_dynamic_image(&source, image_path)
    })
}

fn decode_raw_from_bytes(image_bytes: &[u8]) -> ImageResult<DynamicImage> {
    catch_raw_decode_panic("<bytes>", || {
        validate_raw_input_size(image_bytes.len() as u64, "<bytes>")?;
        let source = RawSource::new_from_slice(image_bytes);
        decode_raw_source_to_dynamic_image(&source, "<bytes>")
    })
}

fn decode_raw_source_to_dynamic_image(
    source: &RawSource,
    source_name: &str,
) -> ImageResult<DynamicImage> {
    let raw_image = rawler::decode(source, &RawDecodeParams::default())
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

    Ok(image)
}

fn catch_raw_decode_panic<F>(source_name: &str, decode: F) -> ImageResult<DynamicImage>
where
    F: FnOnce() -> ImageResult<DynamicImage>,
{
    match panic::catch_unwind(AssertUnwindSafe(decode)) {
        Ok(result) => result,
        Err(payload) => Err(ImageError::Decode(format!(
            "RAW decoder panicked while decoding '{source_name}': {}",
            panic_payload_message(payload)
        ))),
    }
}

fn validate_raw_input_size_from_path(image_path: &str) -> ImageResult<()> {
    let metadata = std::fs::metadata(image_path).map_err(|e| {
        ImageError::Decode(format!(
            "failed to read RAW image metadata for '{image_path}': {e}"
        ))
    })?;
    validate_raw_input_size(metadata.len(), image_path)
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

#[cfg(test)]
mod tests {
    use std::{ffi::OsStr, panic, path::Path};

    use image::hooks::decoding_hook_registered;
    use image::{ColorType, ImageEncoder, ImageFormat, codecs::png::PngEncoder};
    use moxcms::ColorProfile;

    use super::{
        bytes_look_like_heif, catch_raw_decode_panic, decode_image_from_bytes, init_image_decoders,
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
    fn raw_decode_panics_are_returned_as_decode_errors() {
        let previous_hook = panic::take_hook();
        panic::set_hook(Box::new(|_| {}));
        let result = catch_raw_decode_panic("panic.raw", || panic!("synthetic panic"));
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
