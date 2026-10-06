use ente_photos::{
    extract_motion_video_file_from_path, extract_motion_video_from_path, extract_xmp_from_path,
    get_motion_video_index_from_path,
};
use std::path::{Path, PathBuf};

fn fixture_dir() -> PathBuf {
    let root = std::env::var_os("ENTE_TEST_FIXTURES_DIR").map_or_else(
        || Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../test-fixtures"),
        PathBuf::from,
    );
    let directory = root.join("media/motion-photos/v1/files");
    for name in [
        "motionphoto.jpg",
        "motionphoto.heic",
        "pixel_6_small_video.jpg",
        "pixel_8.jpg",
        "normalphoto.jpg",
        "dual_mp4_video_last.jpg",
        "dual_mp4_video_first.jpg",
    ] {
        let path = directory.join(name);
        assert!(
            path.is_file(),
            "missing required motion-photo fixture: {}",
            path.display()
        );
    }
    directory
}

#[test]
#[ignore = "requires external motion-photo fixtures; see crates/photos/README.md"]
fn validates_known_motion_photo_indices() {
    let directory = fixture_dir();
    let motion_jpg = directory.join("motionphoto.jpg");
    let motion_heic = directory.join("motionphoto.heic");
    let pixel6 = directory.join("pixel_6_small_video.jpg");
    let pixel8 = directory.join("pixel_8.jpg");
    let normal = directory.join("normalphoto.jpg");

    let motion_jpg_index = get_motion_video_index_from_path(&motion_jpg)
        .expect("read motionphoto.jpg")
        .expect("motionphoto.jpg should have index");
    assert_eq!(motion_jpg_index.start, 3_366_251);
    assert_eq!(motion_jpg_index.end, 8_013_982);

    let motion_heic_index = get_motion_video_index_from_path(&motion_heic)
        .expect("read motionphoto.heic")
        .expect("motionphoto.heic should have index");
    assert_eq!(motion_heic_index.start, 1_455_411);
    assert_eq!(motion_heic_index.end, 3_649_069);

    let pixel6_index = get_motion_video_index_from_path(&pixel6)
        .expect("read pixel_6_small_video.jpg")
        .expect("pixel_6_small_video.jpg should have index");
    assert!(pixel6_index.start > 0);

    assert_eq!(
        get_motion_video_index_from_path(&pixel8).expect("read pixel_8.jpg"),
        None
    );
    assert_eq!(
        get_motion_video_index_from_path(&normal).expect("read normalphoto.jpg"),
        None
    );

    let motion_jpg_video = extract_motion_video_from_path(&motion_jpg, None)
        .expect("extract motionphoto.jpg video")
        .expect("video present");
    assert!(motion_jpg_video.len() > 1_000_000);

    let motion_heic_video = extract_motion_video_from_path(&motion_heic, None)
        .expect("extract motionphoto.heic video")
        .expect("video present");
    assert!(motion_heic_video.len() > 1_000_000);

    let dual_mp4 = directory.join("dual_mp4_video_last.jpg");
    let dual_index = get_motion_video_index_from_path(&dual_mp4)
        .expect("read dual_mp4_video_last.jpg")
        .expect("dual_mp4_video_last.jpg should have index");
    assert_eq!(dual_index.start, 3_590_234);
    assert_eq!(dual_index.end, 7_638_778);

    let dual_video = extract_motion_video_from_path(&dual_mp4, None)
        .expect("extract dual_mp4_video_last.jpg video")
        .expect("video present");
    assert!(dual_video.len() > 1_000_000);

    let dual_mp4_first = directory.join("dual_mp4_video_first.jpg");
    let dual_first_index = get_motion_video_index_from_path(&dual_mp4_first)
        .expect("read dual_mp4_video_first.jpg")
        .expect("dual_mp4_video_first.jpg should have index");
    assert_eq!(dual_first_index.start, 2_708_585);
    assert_eq!(dual_first_index.end, 7_890_703);

    let dual_first_video = extract_motion_video_from_path(&dual_mp4_first, None)
        .expect("extract dual_mp4_video_first.jpg video")
        .expect("video present");
    assert!(dual_first_video.len() > 1_000_000);
}

#[test]
#[ignore = "requires external motion-photo fixtures; see crates/photos/README.md"]
fn file_extraction_matches_video_bytes() {
    let directory = fixture_dir();
    let output_directory = tempfile::tempdir().expect("output directory");
    for name in [
        "motionphoto.jpg",
        "motionphoto.heic",
        "pixel_6_small_video.jpg",
        "dual_mp4_video_last.jpg",
        "dual_mp4_video_first.jpg",
    ] {
        let path = directory.join(name);
        let source = std::fs::read(&path).expect("read fixture");
        let index = get_motion_video_index_from_path(&path)
            .expect("find video")
            .expect("video present");
        let expected = &source[index.start..index.end];

        for supplied_index in [None, Some(index)] {
            let video = extract_motion_video_from_path(&path, supplied_index.clone())
                .expect("extract bytes")
                .expect("video present");
            let output = extract_motion_video_file_from_path(
                &path,
                output_directory.path(),
                "clip.mp4",
                supplied_index,
            )
            .expect("extract file")
            .expect("video file present");

            assert_eq!(video, expected, "{name}");
            assert_eq!(std::fs::read(output).unwrap(), expected, "{name}");
        }
    }
}

#[test]
#[ignore = "requires external motion-photo fixtures; see crates/photos/README.md"]
fn reads_xmp_attributes() {
    let directory = fixture_dir();
    for (name, length, mime) in [
        ("motionphoto.heic", "80", "video/mp4"),
        ("pixel_6_small_video.jpg", "1789460", "video/mp4"),
        ("dual_mp4_video_first.jpg", "6123713", "video/mp4"),
        ("dual_mp4_video_last.jpg", "4048544", "video/mp4"),
        ("pixel_8.jpg", "9554", "image/jpeg"),
    ] {
        let path = directory.join(name);
        let data = extract_xmp_from_path(path).expect("extract fixture XMP");
        assert_eq!(data.get("Item:Length").unwrap(), length, "{name}");
        assert_eq!(data.get("Item:Mime").unwrap(), mime, "{name}");
    }
}
