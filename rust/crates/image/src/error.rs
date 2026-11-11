use image::error::{ImageFormatHint, LimitErrorKind, UnsupportedErrorKind};
use thiserror::Error;

pub type ImageResult<T> = Result<T, ImageError>;

#[derive(Debug, Error)]
pub enum ImageError {
    #[error("unsupported image format: {0}")]
    Unsupported(String),
    #[error("decode error: {0}")]
    Decode(String),
    #[error("image too large")]
    TooLarge(#[source] image::ImageError),
    #[error("postprocess error: {0}")]
    Postprocess(String),
}

impl From<image::ImageError> for ImageError {
    fn from(value: image::ImageError) -> Self {
        match value {
            image::ImageError::Limits(error)
                if matches!(
                    error.kind(),
                    LimitErrorKind::DimensionError | LimitErrorKind::InsufficientMemory
                ) =>
            {
                Self::TooLarge(image::ImageError::Limits(error))
            }
            image::ImageError::Unsupported(error)
                if matches!(error.kind(), UnsupportedErrorKind::Format(hint)
                    if hint != ImageFormatHint::Unknown) =>
            {
                Self::Unsupported(error.to_string())
            }
            other => Self::Decode(other.to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use image::error::UnsupportedError;

    use super::*;

    #[test]
    fn known_unsupported_formats_have_a_stable_error_category() {
        for hint in [
            ImageFormatHint::Exact(image::ImageFormat::Avif),
            ImageFormatHint::PathExtension("psd".into()),
        ] {
            let error = ImageError::from(image::ImageError::Unsupported(
                UnsupportedError::from_format_and_kind(
                    hint.clone(),
                    UnsupportedErrorKind::Format(hint),
                ),
            ));
            assert!(matches!(error, ImageError::Unsupported(_)));
            assert!(error.to_string().starts_with("unsupported image format: "));
        }
    }

    #[test]
    fn unclassified_and_io_errors_remain_decode_errors() {
        for error in [
            image::ImageError::Unsupported(UnsupportedError::from_format_and_kind(
                ImageFormatHint::Unknown,
                UnsupportedErrorKind::Format(ImageFormatHint::Unknown),
            )),
            image::ImageError::IoError(std::io::Error::other("temporary read failure")),
        ] {
            assert!(matches!(ImageError::from(error), ImageError::Decode(_)));
        }
    }
}
