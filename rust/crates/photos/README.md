# Photos tests

The default suite uses synthetic fixtures. Real-device motion-photo tests are
explicitly ignored because their external fixtures are not bundled here.

From the Rust workspace, run the external suite with:

```sh
ENTE_TEST_FIXTURES_DIR=/path/to/test-fixtures cargo test -p ente-photos --test motion_photos_assets_test -- --ignored
```

The directory must contain `media/motion-photos/v1/files/` with `motionphoto.jpg`,
`motionphoto.heic`, `pixel_6_small_video.jpg`, `pixel_8.jpg`, `normalphoto.jpg`,
`dual_mp4_video_last.jpg`, and `dual_mp4_video_first.jpg`. Without the environment
variable, the suite looks for `test-fixtures` beside the repository. Each test
checks that the complete fixture set is present and fails if anything is missing.
