use std::io::{Read, Seek};

use tiff::{decoder::Decoder, decoder::ifd::Value, tags::Tag};

use crate::{ImageError, ImageResult};

const YCBCR_COEFFICIENTS: Tag = Tag::Unknown(529);
const REFERENCE_BLACK_WHITE: Tag = Tag::Unknown(532);

pub(super) fn convert_ycbcr8_to_rgb<R: Read + Seek>(
    decoder: &mut Decoder<R>,
    width: u32,
    height: u32,
    mut data: Vec<u8>,
) -> ImageResult<Vec<u8>> {
    let planar = decoder
        .find_tag_unsigned::<u16>(Tag::PlanarConfiguration)
        .map_err(|error| ImageError::Decode(format!("failed to read TIFF planar layout: {error}")))?
        .unwrap_or(1);
    if planar != 1 {
        return Err(ImageError::Unsupported(format!(
            "unsupported TIFF YCbCr planar configuration: {planar}"
        )));
    }
    let [red_luma, green_luma, blue_luma] =
        read_rationals(decoder, YCBCR_COEFFICIENTS, [0.299, 0.587, 0.114])?;
    if green_luma <= 0.0 || (red_luma + green_luma + blue_luma - 1.0).abs() > 0.000001 {
        return Err(ImageError::Decode(
            "invalid TIFF YCbCr luma coefficients".to_string(),
        ));
    }
    let references = read_rationals(
        decoder,
        REFERENCE_BLACK_WHITE,
        [0.0, 255.0, 128.0, 255.0, 128.0, 255.0],
    )?;
    if references
        .as_chunks::<2>()
        .0
        .iter()
        .any(|pair| pair[1] > 255.0 || pair[1] <= pair[0])
    {
        return Err(ImageError::Decode(
            "invalid TIFF YCbCr reference levels".to_string(),
        ));
    }
    let y_scale = 255.0 / (references[1] - references[0]);
    let cb_scale = 127.0 / (references[3] - references[2]);
    let cr_scale = 127.0 / (references[5] - references[4]);
    let red_cr = 2.0 * (1.0 - red_luma);
    let blue_cb = 2.0 * (1.0 - blue_luma);
    let green_cb = blue_luma * blue_cb / green_luma;
    let green_cr = red_luma * red_cr / green_luma;
    if data.len() as u64 != u64::from(width) * u64::from(height) * 3 {
        return Err(ImageError::Decode(
            "TIFF YCbCr buffer length does not match dimensions".to_string(),
        ));
    }
    for pixel in data.as_chunks_mut::<3>().0 {
        let y = (f64::from(pixel[0]) - references[0]) * y_scale;
        let cb = (f64::from(pixel[1]) - references[2]) * cb_scale;
        let cr = (f64::from(pixel[2]) - references[4]) * cr_scale;
        *pixel = [
            (y + red_cr * cr).round().clamp(0.0, 255.0) as u8,
            (y - green_cb * cb - green_cr * cr)
                .round()
                .clamp(0.0, 255.0) as u8,
            (y + blue_cb * cb).round().clamp(0.0, 255.0) as u8,
        ];
    }
    Ok(data)
}

fn read_rationals<R: Read + Seek, const N: usize>(
    decoder: &mut Decoder<R>,
    tag: Tag,
    default: [f64; N],
) -> ImageResult<[f64; N]> {
    let invalid = || ImageError::Decode(format!("invalid TIFF YCbCr tag {tag:?}"));
    let Some(value) = decoder
        .find_tag(tag)
        .map_err(|error| ImageError::Decode(format!("failed to read TIFF tag {tag:?}: {error}")))?
    else {
        return Ok(default);
    };
    let Value::List(values) = value else {
        return Err(invalid());
    };
    if values.len() != N {
        return Err(invalid());
    }
    let mut result = [0.0; N];
    for (index, value) in values.into_iter().enumerate() {
        let Value::Rational(numerator, denominator) = value else {
            return Err(invalid());
        };
        if denominator == 0 {
            return Err(invalid());
        }
        result[index] = f64::from(numerator) / f64::from(denominator);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use std::io::Cursor;

    use image::{ImageEncoder, codecs::jpeg::JpegEncoder, codecs::png::PngEncoder};
    use moxcms::ColorProfile;
    use tiff::encoder::{DirectoryEncoder, Rational, TiffEncoder, TiffKindStandard, colortype};

    use super::*;
    use crate::decode::{decode_image_from_bytes, decode_image_from_path};

    fn ycbcr_fixture(
        pixels: &[u8],
        configure: impl FnOnce(&mut DirectoryEncoder<'_, &mut Cursor<Vec<u8>>, TiffKindStandard>),
    ) -> Vec<u8> {
        let mut encoded = Cursor::new(Vec::new());
        {
            let mut encoder = TiffEncoder::new(&mut encoded).unwrap();
            let mut image = encoder
                .new_image::<colortype::YCbCr8>((pixels.len() / 3) as u32, 1)
                .unwrap();
            configure(image.encoder());
            image.write_data(pixels).unwrap();
        }
        encoded.into_inner()
    }

    fn tiff_fixture(
        data: &[u8],
        configure: impl FnOnce(&mut DirectoryEncoder<'_, &mut Cursor<Vec<u8>>, TiffKindStandard>, u32),
    ) -> Vec<u8> {
        let mut encoded = Cursor::new(Vec::new());
        {
            let mut encoder = TiffEncoder::new(&mut encoded).unwrap();
            let mut tags = encoder.image_directory().unwrap();
            let offset = tags.write_data(data).unwrap() as u32;
            tags.write_tag(Tag::ImageLength, 2u32).unwrap();
            tags.write_tag(Tag::BitsPerSample, &[8u16, 8, 8][..])
                .unwrap();
            tags.write_tag(Tag::SamplesPerPixel, 3u16).unwrap();
            tags.write_tag(Tag::Compression, 1u16).unwrap();
            tags.write_tag(Tag::ChromaSubsampling, &[1u16, 1][..])
                .unwrap();
            tags.write_tag(Tag::RowsPerStrip, 2u32).unwrap();
            tags.write_tag(Tag::StripOffsets, offset).unwrap();
            tags.write_tag(Tag::StripByteCounts, data.len() as u32)
                .unwrap();
            configure(&mut tags, offset);
            tags.finish().unwrap();
        }
        encoded.into_inner()
    }

    #[test]
    fn unsupported_tiff_formats_have_a_stable_error_category() {
        let mut fixtures = Vec::new();
        for photometric in [None, Some(65535u16), Some(8)] {
            fixtures.push(tiff_fixture(&[128; 12], |tags, _| {
                tags.write_tag(Tag::ImageWidth, 2u32).unwrap();
                if let Some(value) = photometric {
                    tags.write_tag(Tag::PhotometricInterpretation, value)
                        .unwrap();
                }
            }));
        }
        fixtures.push(tiff_fixture(&[128; 16], |tags, _| {
            tags.write_tag(Tag::ImageWidth, 2u32).unwrap();
            tags.write_tag(Tag::PhotometricInterpretation, 6u16)
                .unwrap();
            tags.write_tag(Tag::BitsPerSample, &[8u16, 16, 8][..])
                .unwrap();
        }));
        fixtures.push(tiff_fixture(&[100, 100, 100, 100, 128, 128], |tags, _| {
            tags.write_tag(Tag::ImageWidth, 2u32).unwrap();
            tags.write_tag(Tag::PhotometricInterpretation, 6u16)
                .unwrap();
            tags.write_tag(Tag::ChromaSubsampling, &[2u16, 2][..])
                .unwrap();
        }));
        fixtures.push(tiff_fixture(&[128; 24], |tags, _| {
            tags.write_tag(Tag::ImageWidth, 2u32).unwrap();
            tags.write_tag(Tag::PhotometricInterpretation, 6u16)
                .unwrap();
            tags.write_tag(Tag::BitsPerSample, &[16u16, 16, 16][..])
                .unwrap();
        }));
        fixtures.push(tiff_fixture(&[128; 12], |tags, offset| {
            tags.write_tag(Tag::ImageWidth, 2u32).unwrap();
            tags.write_tag(Tag::PhotometricInterpretation, 6u16)
                .unwrap();
            tags.write_tag(Tag::PlanarConfiguration, 2u16).unwrap();
            tags.write_tag(Tag::StripOffsets, &[offset, offset + 4, offset + 8][..])
                .unwrap();
            tags.write_tag(Tag::StripByteCounts, &[4u32, 4, 4][..])
                .unwrap();
        }));
        for bytes in fixtures {
            let error = decode_image_from_bytes(&bytes).unwrap_err();
            assert!(matches!(error, ImageError::Unsupported(_)), "{error}");
            assert!(error.to_string().starts_with("unsupported image format: "));
        }
    }

    #[test]
    fn malformed_tiff_metadata_remains_retryable() {
        let mut fixtures = Vec::new();
        for bits in [&[0u16][..], &[0, 0, 0][..], &[8, 0, 8][..]] {
            fixtures.push(tiff_fixture(&[128; 12], |tags, _| {
                tags.write_tag(Tag::ImageWidth, 2u32).unwrap();
                tags.write_tag(
                    Tag::PhotometricInterpretation,
                    if bits.len() == 1 { 1u16 } else { 6 },
                )
                .unwrap();
                tags.write_tag(Tag::SamplesPerPixel, bits.len() as u16)
                    .unwrap();
                tags.write_tag(Tag::BitsPerSample, bits).unwrap();
            }));
        }
        fixtures.push(tiff_fixture(&[128; 12], |tags, _| {
            tags.write_tag(Tag::PhotometricInterpretation, 6u16)
                .unwrap();
        }));
        for bytes in fixtures {
            assert!(matches!(
                decode_image_from_bytes(&bytes),
                Err(ImageError::Decode(_))
            ));
        }
    }

    #[test]
    fn public_decoders_convert_ycbcr_tiff_colors() {
        let bytes = ycbcr_fixture(
            &[
                0, 128, 128, 255, 128, 128, 80, 128, 128, 76, 85, 255, 29, 255, 107,
            ],
            |_| {},
        );
        let expected = [0, 0, 0, 255, 255, 255, 80, 80, 80, 254, 0, 0, 0, 0, 254];
        let decoded = decode_image_from_bytes(&bytes).unwrap();
        assert_eq!(
            (decoded.dimensions.width, decoded.dimensions.height),
            (5, 1)
        );
        assert_eq!(decoded.rgb, expected);
        let file = tempfile::Builder::new().suffix(".dng").tempfile().unwrap();
        std::fs::write(file.path(), &bytes).unwrap();
        assert_eq!(
            decode_image_from_path(file.path().to_str().unwrap())
                .unwrap()
                .rgb,
            expected
        );
    }

    #[test]
    fn custom_coefficients_and_reference_levels_are_applied() {
        let coefficients = [
            Rational { n: 1, d: 4 },
            Rational { n: 1, d: 2 },
            Rational { n: 1, d: 4 },
        ];
        let references = [16, 235, 128, 240, 128, 240].map(|n| Rational { n, d: 1 });
        let bytes = ycbcr_fixture(&[100, 100, 150], |tags| {
            tags.write_tag(YCBCR_COEFFICIENTS, &coefficients[..])
                .unwrap();
            tags.write_tag(REFERENCE_BLACK_WHITE, &references[..])
                .unwrap();
        });
        assert_eq!(decode_image_from_bytes(&bytes).unwrap().rgb, [135, 103, 50]);
    }

    #[test]
    fn ycbcr_conversion_preserves_icc_and_orientation_processing() {
        let profile = ColorProfile::new_display_p3().encode().unwrap();
        let bytes = ycbcr_fixture(&[100, 140, 160, 90, 128, 128], |tags| {
            tags.write_tag(Tag::Orientation, 8u16).unwrap();
            tags.write_tag(Tag::IccProfile, profile.as_slice()).unwrap();
        });
        let decoded = decode_image_from_bytes(&bytes).unwrap();
        assert_eq!(
            (decoded.dimensions.width, decoded.dimensions.height),
            (1, 2)
        );
        let mut png = Vec::new();
        let mut encoder = PngEncoder::new(&mut png);
        encoder.set_icc_profile(profile).unwrap();
        encoder
            .write_image(
                &[90, 90, 90, 145, 73, 121],
                1,
                2,
                image::ExtendedColorType::Rgb8,
            )
            .unwrap();
        let reference = decode_image_from_bytes(&png).unwrap();
        assert_ne!(reference.rgb, [90, 90, 90, 145, 73, 121]);
        assert_eq!(decoded.rgb, reference.rgb);
    }

    #[test]
    fn jpeg_compressed_ycbcr_tiff_matches_jpeg_colors() {
        let pixels = [255, 0, 0, 0, 255, 0, 0, 0, 255, 80, 100, 120];
        let mut jpeg = Vec::new();
        JpegEncoder::new_with_quality(&mut jpeg, 95)
            .encode(&pixels, 2, 2, image::ExtendedColorType::Rgb8)
            .unwrap();
        let encoded = tiff_fixture(&jpeg, |tags, _| {
            tags.write_tag(Tag::ImageWidth, 2u32).unwrap();
            tags.write_tag(Tag::Compression, 7u16).unwrap();
            tags.write_tag(Tag::PhotometricInterpretation, 6u16)
                .unwrap();
        });
        let decoded = decode_image_from_bytes(&encoded).unwrap();
        let reference = decode_image_from_bytes(&jpeg).unwrap();
        assert_eq!(decoded.rgb.len(), reference.rgb.len());
        assert!(
            decoded
                .rgb
                .iter()
                .zip(reference.rgb)
                .all(|(left, right)| left.abs_diff(right) <= 2)
        );
    }

    #[test]
    fn invalid_ycbcr_metadata_is_rejected() {
        for values in [
            vec![Rational { n: 1, d: 0 }; 3],
            vec![Rational { n: 1, d: 1 }; 3],
            vec![Rational { n: 1, d: 4 }; 2],
        ] {
            let bytes = ycbcr_fixture(&[100, 128, 128], |tags| {
                tags.write_tag(YCBCR_COEFFICIENTS, values.as_slice())
                    .unwrap();
            });
            assert!(matches!(
                decode_image_from_bytes(&bytes),
                Err(ImageError::Decode(_))
            ));
        }
        let references = [0, 0, 128, 255, 128, 255].map(|n| Rational { n, d: 1 });
        let bytes = ycbcr_fixture(&[100, 128, 128], |tags| {
            tags.write_tag(REFERENCE_BLACK_WHITE, &references[..])
                .unwrap();
        });
        assert!(matches!(
            decode_image_from_bytes(&bytes),
            Err(ImageError::Decode(_))
        ));
    }

    #[test]
    fn ycbcr_buffers_must_match_the_dimensions_exactly() {
        let bytes = ycbcr_fixture(&[100, 128, 128], |_| {});
        for data in [vec![100, 128], vec![100, 128, 128, 0]] {
            let mut decoder = Decoder::new(Cursor::new(&bytes)).unwrap();
            assert!(convert_ycbcr8_to_rgb(&mut decoder, 1, 1, data).is_err());
        }
    }
}
