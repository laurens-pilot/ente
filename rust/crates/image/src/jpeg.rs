use std::{fs::File, io::Read};

use image::{DynamicImage, ImageBuffer, metadata::Orientation};
use zune_jpeg::{
    JpegDecoder, ScanlineReadStatus,
    errors::DecodeErrors,
    zune_core::{bytestream::ZCursor, colorspace::ColorSpace, options::DecoderOptions},
};

use crate::{
    BoundedDecodeOptions, BoundedDecodedImage, Dimensions, ImageError, ImageInput, ImageResult,
    bounded::{MAX_SOURCE_PIXELS, oriented_output, target_dimensions, too_large},
    color_management::IccConverter,
    resample::Downsampler,
};

pub(crate) const SIGNATURE: &[u8] = b"\xff\xd8\xff";
const END_OF_IMAGE: &[u8] = b"\xff\xd9";
const READ_ROWS: usize = 36;
const DECODER_BYTES: u64 = 1024 * 1024;
const DECODER_BYTES_PER_COLUMN: u64 = 512;

pub(crate) fn decode(
    input: ImageInput<'_>,
    options: BoundedDecodeOptions,
) -> ImageResult<BoundedDecodedImage> {
    match input {
        ImageInput::Bytes(bytes) if bytes.ends_with(END_OF_IMAGE) => {
            decode_bytes(bytes, 0, options)
        }
        ImageInput::Bytes(bytes) => {
            let mut terminated = buffer(bytes.len() as u64, options.max_memory_bytes)?;
            terminated.extend_from_slice(bytes);
            terminated.extend_from_slice(END_OF_IMAGE);
            decode_bytes(&terminated, terminated.len() as u64, options)
        }
        ImageInput::Path(path) => {
            let read_error =
                |error| ImageError::Decode(format!("failed to read image file '{path}': {error}"));
            let mut file = File::open(path).map_err(read_error)?;
            let length = file.metadata().map_err(read_error)?.len();
            let mut bytes = buffer(length, options.max_memory_bytes)?;
            file.read_to_end(&mut bytes).map_err(read_error)?;
            bytes.extend_from_slice(END_OF_IMAGE);
            decode_bytes(&bytes, bytes.len() as u64, options)
        }
    }
}

fn buffer(input_bytes: u64, max_memory_bytes: u64) -> ImageResult<Vec<u8>> {
    let length = input_bytes.saturating_add(END_OF_IMAGE.len() as u64);
    if length > max_memory_bytes {
        return Err(too_large());
    }
    let mut buffer = Vec::new();
    buffer
        .try_reserve_exact(usize::try_from(length).map_err(|_| too_large())?)
        .map_err(|_| too_large())?;
    Ok(buffer)
}

fn decode_bytes(
    bytes: &[u8],
    input_bytes: u64,
    options: BoundedDecodeOptions,
) -> ImageResult<BoundedDecodedImage> {
    let mut decoder = JpegDecoder::new_with_options(
        ZCursor::new(bytes),
        DecoderOptions::default()
            .set_strict_mode(false)
            .set_max_width(usize::from(u16::MAX))
            .set_max_height(usize::from(u16::MAX)),
    );
    decoder.decode_headers().map_err(jpeg_error)?;
    let info = decoder
        .info()
        .ok_or_else(|| ImageError::Decode("JPEG headers were not decoded".into()))?;
    if !info.sof.is_sequential_dct() {
        return Err(ImageError::Decode(format!(
            "unsupported JPEG for bounded decoding: {:?}",
            info.sof
        )));
    }
    if first_scan_components(bytes) != Some(info.components) {
        return Err(ImageError::Decode(
            "unsupported JPEG for bounded decoding: components are in separate scans".into(),
        ));
    }
    let source = Dimensions {
        width: u32::from(info.width),
        height: u32::from(info.height),
    };
    if u64::from(source.width) * u64::from(source.height) > MAX_SOURCE_PIXELS {
        return Err(too_large());
    }
    let color = match decoder
        .input_colorspace()
        .ok_or_else(|| ImageError::Decode("JPEG headers were not decoded".into()))?
    {
        color @ (ColorSpace::RGB | ColorSpace::RGBA | ColorSpace::Luma | ColorSpace::LumaA) => {
            color
        }
        _ => ColorSpace::RGB,
    };
    decoder.set_options(decoder.options().jpeg_set_out_colorspace(color));
    let target = target_dimensions(&source, options.max_side);
    if required_bytes(input_bytes, &source, &target) > options.max_memory_bytes {
        return Err(too_large());
    }
    let orientation = decoder
        .exif()
        .and_then(|exif| Orientation::from_exif_chunk(exif))
        .unwrap_or(Orientation::NoTransforms);
    let profile = decoder.icc_profile();
    let mut converter = IccConverter::new(profile.as_deref());
    let mut output = Downsampler::new(source.clone(), target.clone(), false)?;
    let row_bytes = source.width as usize * color.num_components();
    let mut buffer = vec![0; row_bytes * READ_ROWS];
    let mut session = decoder.scanline_output();
    let mut y = 0;
    loop {
        match session
            .read_scanlines(&mut buffer, row_bytes)
            .map_err(jpeg_error)?
        {
            ScanlineReadStatus::RowsProcessed { rows } => {
                let rgb = rows_rgb(
                    &buffer[..rows * row_bytes],
                    source.width,
                    rows as u32,
                    color,
                    &mut converter,
                )?;
                for row in rgb.chunks_exact(source.width as usize * 3) {
                    output.push_row(row, 0, y, 1);
                    y += 1;
                }
            }
            ScanlineReadStatus::Complete => break,
            _ => {
                return Err(ImageError::Decode(
                    "JPEG ended before all rows were decoded".into(),
                ));
            }
        }
    }
    if y != source.height {
        return Err(ImageError::Decode(
            "JPEG ended before all rows were decoded".into(),
        ));
    }
    session.finish().map_err(jpeg_error)?;
    oriented_output(output.finish(), source, target, orientation)
}

fn required_bytes(input_bytes: u64, source: &Dimensions, target: &Dimensions) -> u64 {
    let oriented_copy = u64::from(target.width) * u64::from(target.height) * 3;
    input_bytes
        .saturating_add(Downsampler::bytes(source, target, false))
        .saturating_add(oriented_copy)
        .saturating_add(DECODER_BYTES + u64::from(source.width) * DECODER_BYTES_PER_COLUMN)
}

fn first_scan_components(bytes: &[u8]) -> Option<u8> {
    let mut offset = 2;
    loop {
        if *bytes.get(offset)? != 0xff {
            offset += 1;
            continue;
        }
        offset += 1;
        while matches!(bytes.get(offset), Some(0x00 | 0xff)) {
            offset += 1;
        }
        let marker = *bytes.get(offset)?;
        offset += 1;
        match marker {
            0x01 | 0xd0..=0xd8 => {}
            0xda => return bytes.get(offset + 2).copied(),
            _ => {
                let length = bytes.get(offset..offset + 2)?;
                offset += usize::from(u16::from_be_bytes([length[0], length[1]]));
            }
        }
    }
}

fn rows_rgb(
    bytes: &[u8],
    width: u32,
    rows: u32,
    color: ColorSpace,
    converter: &mut IccConverter<'_>,
) -> ImageResult<Vec<u8>> {
    let invalid = || ImageError::Decode("invalid JPEG row layout".into());
    let data = bytes.to_vec();
    let image = match color {
        ColorSpace::Luma => {
            DynamicImage::ImageLuma8(ImageBuffer::from_raw(width, rows, data).ok_or_else(invalid)?)
        }
        ColorSpace::LumaA => {
            DynamicImage::ImageLumaA8(ImageBuffer::from_raw(width, rows, data).ok_or_else(invalid)?)
        }
        ColorSpace::RGB => {
            DynamicImage::ImageRgb8(ImageBuffer::from_raw(width, rows, data).ok_or_else(invalid)?)
        }
        ColorSpace::RGBA => {
            DynamicImage::ImageRgba8(ImageBuffer::from_raw(width, rows, data).ok_or_else(invalid)?)
        }
        _ => return Err(invalid()),
    };
    Ok(converter.apply(image).into_rgb8().into_raw())
}

fn jpeg_error(error: DecodeErrors) -> ImageError {
    ImageError::Decode(error.to_string())
}

#[cfg(test)]
mod tests {
    use image::{
        ExtendedColorType, GenericImageView, ImageEncoder, Rgb, codecs::jpeg::JpegEncoder,
    };

    use super::*;
    use crate::{
        bounded::tests::{fixtures_dir, options},
        decode::decode_image_from_bytes,
        decode_bounded,
        memory_budget::MemoryBudget,
        resample::tests::area_reference,
    };

    fn encode(
        pixels: &[u8],
        width: u32,
        height: u32,
        color: ExtendedColorType,
        icc_profile: Option<Vec<u8>>,
        exif: Option<Vec<u8>>,
    ) -> Vec<u8> {
        let mut bytes = Vec::new();
        let mut encoder = JpegEncoder::new_with_quality(&mut bytes, 90);
        if let Some(profile) = icc_profile {
            encoder.set_icc_profile(profile).unwrap();
        }
        if let Some(exif) = exif {
            encoder.set_exif_metadata(exif).unwrap();
        }
        encoder.write_image(pixels, width, height, color).unwrap();
        bytes
    }

    fn rgb(width: u32, height: u32) -> Vec<u8> {
        (0..width * height * 3)
            .map(|i| ((i * 37 + 11) % 256) as u8)
            .collect()
    }

    fn assert_matches_full_decoder(bytes: &[u8], max_side: u32, label: &str) {
        let full = decode_image_from_bytes(bytes).unwrap();
        let bounded = decode_bounded(ImageInput::Bytes(bytes), options(max_side)).unwrap();
        assert_eq!(bounded.original_dimensions, full.dimensions, "{label}");
        assert_eq!(
            bounded.image.dimensions,
            target_dimensions(&full.dimensions, max_side),
            "{label}"
        );
        if bounded.image.dimensions == full.dimensions {
            assert_eq!(bounded.image.rgb, full.rgb, "{label}");
            return;
        }
        let expected = area_reference(
            &full.rgb,
            full.dimensions.width,
            full.dimensions.height,
            &bounded.image.dimensions,
        );
        assert_eq!(bounded.image.rgb.len(), expected.len(), "{label}");
        for (actual, expected) in bounded.image.rgb.iter().zip(expected) {
            assert!(
                actual.abs_diff(expected) <= 1,
                "{label}, max {max_side}: {actual} != {expected}"
            );
        }
    }

    fn marker(bytes: &[u8], marker: u8) -> usize {
        bytes
            .windows(2)
            .position(|window| window == [0xff, marker])
            .unwrap()
    }

    fn with_dimensions(bytes: &[u8], width: u16, height: u16) -> Vec<u8> {
        let mut patched = bytes.to_vec();
        let sof = marker(&patched, 0xc0);
        patched[sof + 5..sof + 7].copy_from_slice(&height.to_be_bytes());
        patched[sof + 7..sof + 9].copy_from_slice(&width.to_be_bytes());
        patched
    }

    #[test]
    fn streamed_rows_match_the_full_decoder_for_rgb_and_grayscale() {
        for (width, height) in [(1, 19), (19, 1), (2, 3), (13, 17), (31, 23), (40, 70)] {
            let pixels = rgb(width, height);
            let gray = pixels.iter().step_by(3).copied().collect::<Vec<_>>();
            for (color, data) in [
                (ExtendedColorType::Rgb8, &pixels),
                (ExtendedColorType::L8, &gray),
            ] {
                let bytes = encode(data, width, height, color, None, None);
                for max_side in [1, 2, 7, 13, 40, 6000] {
                    assert_matches_full_decoder(
                        &bytes,
                        max_side,
                        &format!("{width}x{height} {color:?}"),
                    );
                }
            }
        }
    }

    #[test]
    fn icc_profiles_match_the_full_decoder() {
        let pixels = rgb(21, 13);
        let gray = pixels.iter().step_by(3).copied().collect::<Vec<_>>();
        for (color, data, profile) in [
            (
                ExtendedColorType::Rgb8,
                &pixels,
                moxcms::ColorProfile::new_display_p3(),
            ),
            (
                ExtendedColorType::L8,
                &gray,
                moxcms::ColorProfile::new_gray_with_gamma(1.8),
            ),
        ] {
            let bytes = encode(data, 21, 13, color, Some(profile.encode().unwrap()), None);
            assert_ne!(
                decode_image_from_bytes(&bytes).unwrap().rgb,
                decode_image_from_bytes(&encode(data, 21, 13, color, None, None))
                    .unwrap()
                    .rgb
            );
            for max_side in [5, 6000] {
                assert_matches_full_decoder(&bytes, max_side, &format!("{color:?}"));
            }
        }
    }

    #[test]
    fn applies_all_exif_orientations_after_downsampling() {
        let pixels = rgb(16, 8);
        for orientation in 1..=8 {
            let mut exif = b"II\x2a\0\x08\0\0\0\x01\0\x12\x01\x03\0\x01\0\0\0".to_vec();
            exif.extend_from_slice(&[orientation, 0, 0, 0, 0, 0, 0, 0]);
            let bytes = encode(&pixels, 16, 8, ExtendedColorType::Rgb8, None, Some(exif));
            for max_side in [4, 6000] {
                assert_matches_full_decoder(
                    &bytes,
                    max_side,
                    &format!("orientation {orientation}"),
                );
            }
        }
    }

    #[test]
    fn path_reads_match_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("image.png");
        let bytes = encode(&rgb(33, 18), 33, 18, ExtendedColorType::Rgb8, None, None);
        std::fs::write(&path, &bytes).unwrap();
        let from_path =
            decode_bounded(ImageInput::Path(path.to_str().unwrap()), options(10)).unwrap();
        let from_bytes = decode_bounded(ImageInput::Bytes(&bytes), options(10)).unwrap();
        assert_eq!(from_path.image.rgb, from_bytes.image.rgb);
        assert_eq!(from_path.image.dimensions, from_bytes.image.dimensions);
    }

    #[test]
    fn progressive_and_separate_scan_jpegs_are_rejected() {
        let bytes = encode(&rgb(24, 24), 24, 24, ExtendedColorType::Rgb8, None, None);
        let mut progressive = bytes.clone();
        progressive[marker(&bytes, 0xc0) + 1] = 0xc2;
        let sos = marker(&bytes, 0xda);
        let components = usize::from(bytes[sos + 4]);
        let mut separate = bytes[..sos + 2].to_vec();
        separate.extend_from_slice(&[0, 8, 1]);
        separate.extend_from_slice(&bytes[sos + 5..sos + 7]);
        separate.extend_from_slice(&bytes[sos + 5 + 2 * components..]);
        for patched in [progressive, separate] {
            assert!(matches!(
                decode_bounded(ImageInput::Bytes(&patched), options(8)),
                Err(ImageError::Decode(message)) if message.contains("unsupported JPEG")
            ));
        }
    }

    #[test]
    fn first_scan_components_skips_segments_fill_and_stray_bytes() {
        let bytes = encode(&rgb(8, 8), 8, 8, ExtendedColorType::Rgb8, None, None);
        assert_eq!(first_scan_components(&bytes), Some(3));
        let gray = encode(&[90; 64], 8, 8, ExtendedColorType::L8, None, None);
        assert_eq!(first_scan_components(&gray), Some(1));
        assert_eq!(
            first_scan_components(b"\xff\xd8\xff\xe0\0\x04ab\x12\x34\xff\xda\0\x08\x02"),
            Some(2)
        );
        assert_eq!(
            first_scan_components(b"\xff\xd8\xff\xff\xe1\0\x05\xff\xda\x7f\xff\0\xda\0\x08\x01"),
            Some(1)
        );
        assert_eq!(
            first_scan_components(b"\xff\xd8\xff\xe0\0\x10\xff\xda"),
            None
        );
        assert_eq!(first_scan_components(b"\xff\xd8\xff\xda\0\x08"), None);
    }

    #[test]
    fn missing_end_markers_decode_like_the_full_decoder() {
        let bytes = encode(&rgb(40, 70), 40, 70, ExtendedColorType::Rgb8, None, None);
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("image.jpg");
        for length in [bytes.len() - 2, bytes.len() - 1] {
            let truncated = &bytes[..length];
            std::fs::write(&path, truncated).unwrap();
            let full = decode_image_from_bytes(truncated).unwrap();
            for input in [
                ImageInput::Bytes(truncated),
                ImageInput::Path(path.to_str().unwrap()),
            ] {
                assert_eq!(
                    decode_bounded(input, options(6000)).unwrap().image.rgb,
                    full.rgb,
                    "length {length}"
                );
            }
        }
    }

    #[test]
    fn truncated_scans_decode_like_the_full_decoder_given_an_end_marker() {
        let bytes = encode(&rgb(40, 70), 40, 70, ExtendedColorType::Rgb8, None, None);
        for length in [marker(&bytes, 0xda) + 20, bytes.len() / 2, bytes.len() - 20] {
            let truncated = &bytes[..length];
            let terminated = [truncated, END_OF_IMAGE].concat();
            assert_eq!(
                decode_bounded(ImageInput::Bytes(truncated), options(6000))
                    .unwrap()
                    .image
                    .rgb,
                decode_image_from_bytes(&terminated).unwrap().rgb,
                "length {length}"
            );
        }
    }

    #[test]
    fn truncated_headers_and_invalid_jpegs_fail() {
        let bytes = encode(&rgb(40, 70), 40, 70, ExtendedColorType::Rgb8, None, None);
        for length in [3, 20, marker(&bytes, 0xda)] {
            assert!(
                matches!(
                    decode_bounded(ImageInput::Bytes(&bytes[..length]), options(8)),
                    Err(ImageError::Decode(_))
                ),
                "length {length}"
            );
        }
        assert!(matches!(
            decode_bounded(ImageInput::Bytes(b"\xff\xd8\xff\xe0garbage"), options(8)),
            Err(ImageError::Decode(_))
        ));
    }

    #[test]
    fn oversized_sources_and_budgets_are_too_large() {
        let bytes = encode(&rgb(16, 16), 16, 16, ExtendedColorType::Rgb8, None, None);
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("image.jpg");
        let oversized = with_dimensions(&bytes, 16_001, 16_000);
        std::fs::write(&path, &oversized).unwrap();
        for input in [
            ImageInput::Bytes(&oversized),
            ImageInput::Path(path.to_str().unwrap()),
        ] {
            assert!(matches!(
                decode_bounded(input, options(6000)),
                Err(ImageError::TooLarge(_))
            ));
        }
        let large = with_dimensions(&bytes, 16_000, 16_000);
        let small_budget = BoundedDecodeOptions {
            max_memory_bytes: 64 * 1024 * 1024,
            ..BoundedDecodeOptions::default()
        };
        assert!(matches!(
            decode_bounded(ImageInput::Bytes(&large), small_budget),
            Err(ImageError::TooLarge(_))
        ));
        std::fs::write(&path, &bytes).unwrap();
        assert!(matches!(
            decode_bounded(
                ImageInput::Path(path.to_str().unwrap()),
                BoundedDecodeOptions {
                    max_memory_bytes: bytes.len() as u64 - 1,
                    ..BoundedDecodeOptions::default()
                }
            ),
            Err(ImageError::TooLarge(_))
        ));
    }

    #[test]
    fn memory_estimate_covers_the_decode() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("image.jpg");
        let profile = moxcms::ColorProfile::new_display_p3().encode().unwrap();
        for (width, height, max_side) in [(1, 1, 1), (640, 480, 6000), (1200, 900, 300)] {
            let bytes = encode(
                &rgb(width, height),
                width,
                height,
                ExtendedColorType::Rgb8,
                Some(profile.clone()),
                None,
            );
            std::fs::write(&path, &bytes).unwrap();
            let source = Dimensions { width, height };
            let target = target_dimensions(&source, max_side);
            let budget =
                MemoryBudget::new(required_bytes(bytes.len() as u64, &source, &target) as usize);
            let decoded = budget
                .enter(|| {
                    decode_bounded(ImageInput::Path(path.to_str().unwrap()), options(max_side))
                })
                .unwrap();
            assert_eq!(decoded.image.dimensions, target);
            assert!(!budget.is_exceeded(), "{width}x{height}");
        }
    }

    #[test]
    fn jpeg_fixtures_match_the_full_decoder_when_present() {
        let Some(directory) = fixtures_dir().filter(|path| path.exists()) else {
            eprintln!("Skipping: external JPEG fixtures not present");
            return;
        };
        for name in [
            "ml/indexing/v1/files/people.jpeg",
            "ml/indexing/v1/files/man.jpeg",
            "ml/indexing/v1/files/singapore.jpg",
            "ml/indexing/v1/files/1343_rotate_90_cw.jpg",
            "ml/indexing/v1/files/IMG_pano.jpg",
            "media/motion-photos/v1/files/motionphoto.jpg",
            "media/motion-photos/v1/files/pixel_8.jpg",
        ] {
            let bytes = std::fs::read(directory.join(name)).unwrap();
            for max_side in [6000, 97] {
                assert_matches_full_decoder(&bytes, max_side, name);
            }
        }
        let progressive =
            std::fs::read(directory.join("ml/indexing/v1/files/starwatchers.jpg")).unwrap();
        assert!(matches!(
            decode_bounded(ImageInput::Bytes(&progressive), options(6000)),
            Err(ImageError::Decode(_))
        ));
    }

    struct Pattern {
        width: u32,
        height: u32,
    }

    impl GenericImageView for Pattern {
        type Pixel = Rgb<u8>;

        fn dimensions(&self) -> (u32, u32) {
            (self.width, self.height)
        }

        fn get_pixel(&self, x: u32, y: u32) -> Rgb<u8> {
            Rgb([
                (x % 251) as u8,
                (y % 241) as u8,
                ((x / 7 + y / 5) % 239) as u8,
            ])
        }
    }

    #[test]
    #[ignore = "200 MP streaming memory regression; run in release mode"]
    fn streams_200_megapixels() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("large.jpg");
        let mut bytes = Vec::new();
        JpegEncoder::new_with_quality(&mut bytes, 90)
            .encode_image(&Pattern {
                width: 16_320,
                height: 12_240,
            })
            .unwrap();
        std::fs::write(&path, &bytes).unwrap();
        let limit = bytes.len() + 100 * 1024 * 1024;
        drop(bytes);
        let budget = MemoryBudget::new(limit);
        let output = budget
            .enter(|| decode_bounded(ImageInput::Path(path.to_str().unwrap()), options(6000)))
            .unwrap();
        assert!(!budget.is_exceeded());
        assert_eq!(
            output.image.dimensions,
            Dimensions {
                width: 6000,
                height: 4500
            }
        );
    }
}
