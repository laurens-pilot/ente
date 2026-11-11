use ente_core::crypto::{Error, Key, stream};
use std::io::Cursor;

const LIBSODIUM_EMPTY_MESSAGE: &[u8] = &[
    0xc8, 0x9b, 0x4a, 0x5b, 0x2c, 0xa8, 0xf2, 0x59, 0xe6, 0x6b, 0xe4, 0xa4, 0x8d, 0x8a, 0x84, 0xfc,
    0xb4, 0x34, 0xae, 0xed, 0x4f, 0xf8, 0x0f, 0x51, 0xee, 0xdb, 0x82, 0x26, 0x1b, 0x56, 0x05, 0x5d,
    0x44, 0x98, 0xb9, 0x67, 0xa0, 0x32, 0x5b, 0x8f, 0xe6,
];
const LIBSODIUM_EMPTY_FINAL: &[u8] = &[
    0xf0, 0x10, 0xbb, 0x9f, 0xf1, 0x0c, 0x67, 0x7b, 0x2d, 0x40, 0x86, 0x9b, 0x2f, 0x31, 0xc4, 0xa3,
    0xa7, 0x4b, 0xe5, 0x0a, 0x76, 0x59, 0xb5, 0xd9, 0x27, 0x15, 0x38, 0x41, 0x0b, 0x77, 0x1f, 0x33,
    0xa3, 0xdd, 0x33, 0xcb, 0x8c, 0xf8, 0xb6, 0xa2, 0x41,
];

fn test_key() -> Key {
    Key::from_bytes([0x42; Key::BYTES])
}

fn reader(data: &[u8]) -> Result<stream::StreamingDecryptor<Cursor<&[u8]>>, Error> {
    stream::StreamingDecryptor::new(&test_key(), Cursor::new(data))
}

#[test]
fn empty_message_is_not_eof_for_read_to_end() -> Result<(), Error> {
    assert!(matches!(
        reader(LIBSODIUM_EMPTY_MESSAGE)?.read_to_end(),
        Err(Error::StreamTruncated)
    ));
    Ok(())
}

#[test]
fn empty_message_is_not_eof_for_read() -> Result<(), Error> {
    for size in [1, 8192] {
        let result = reader(LIBSODIUM_EMPTY_MESSAGE)?.read(&mut vec![0; size]);
        assert!(matches!(result, Err(Error::StreamTruncated)), "{result:?}");
    }
    Ok(())
}

#[test]
fn empty_terminal_message_after_full_chunk_is_not_eof() -> Result<(), Error> {
    let mut encryptor = stream::Encryptor::new(&test_key());
    let prefix = vec![0x61; stream::ENCRYPTION_CHUNK_SIZE];
    let mut data = encryptor.header().as_bytes().to_vec();
    data.extend(encryptor.push(&prefix, false)?);
    data.extend(encryptor.push(&[], false)?);

    let mut decryptor = reader(&data)?;
    let mut buffer = [0; 8192];
    for chunk in prefix.chunks(buffer.len()) {
        let n = decryptor.read(&mut buffer)?;
        assert_eq!(&buffer[..n], chunk);
    }
    assert!(matches!(
        decryptor.read(&mut buffer),
        Err(Error::StreamTruncated)
    ));
    assert!(matches!(
        reader(&data)?.read_to_end(),
        Err(Error::StreamTruncated)
    ));
    Ok(())
}

#[test]
fn empty_final_is_eof() -> Result<(), Error> {
    let mut decryptor = reader(LIBSODIUM_EMPTY_FINAL)?;
    assert!(decryptor.read_to_end()?.is_empty());
    assert_eq!(decryptor.read(&mut [0; 1])?, 0);
    Ok(())
}

#[test]
fn empty_final_after_full_chunk_is_eof() -> Result<(), Error> {
    let mut encryptor = stream::Encryptor::new(&test_key());
    let plaintext = vec![0x61; stream::ENCRYPTION_CHUNK_SIZE];
    let mut data = encryptor.header().as_bytes().to_vec();
    data.extend(encryptor.push(&plaintext, false)?);
    data.extend(encryptor.push(&[], true)?);

    let mut decryptor = reader(&data)?;
    assert_eq!(decryptor.read_to_end()?, plaintext);
    assert_eq!(decryptor.read(&mut [0; 1])?, 0);
    Ok(())
}

#[test]
fn zero_length_buffers_preserve_final_plaintext() -> Result<(), Error> {
    let mut encryptor = stream::Encryptor::new(&test_key());
    let plaintext = b"short final chunk";
    let mut data = encryptor.header().as_bytes().to_vec();
    data.extend(encryptor.push(plaintext, true)?);

    let mut decryptor = reader(&data)?;
    assert_eq!(decryptor.read(&mut [])?, 0);
    let mut output = Vec::new();
    let mut buffer = [0; 3];
    loop {
        assert_eq!(decryptor.read(&mut [])?, 0);
        let n = decryptor.read(&mut buffer)?;
        if n == 0 {
            break;
        }
        output.extend_from_slice(&buffer[..n]);
    }
    assert_eq!(output, plaintext);
    Ok(())
}

#[test]
fn nonempty_final_and_multichunk_streams_roundtrip() -> Result<(), Error> {
    for size in [
        1,
        stream::ENCRYPTION_CHUNK_SIZE,
        stream::ENCRYPTION_CHUNK_SIZE + 31,
    ] {
        let plaintext = vec![0xa5; size];
        let mut encryptor = stream::StreamingEncryptor::new(&test_key(), Vec::new())?;
        encryptor.write(&plaintext)?;
        let data = encryptor.finish()?;

        let mut decryptor = reader(&data)?;
        assert_eq!(decryptor.read(&mut [])?, 0);
        assert_eq!(decryptor.read_to_end()?, plaintext);
        assert_eq!(decryptor.read(&mut [0; 1])?, 0);
    }
    Ok(())
}

#[test]
fn missing_final_remains_truncated() -> Result<(), Error> {
    for size in [0, 1, stream::ENCRYPTION_CHUNK_SIZE] {
        let mut encryptor = stream::Encryptor::new(&test_key());
        let mut data = encryptor.header().as_bytes().to_vec();
        if size > 0 {
            data.extend(encryptor.push(&vec![0x61; size], false)?);
        }
        assert!(matches!(
            reader(&data)?.read_to_end(),
            Err(Error::StreamTruncated)
        ));
    }
    Ok(())
}

#[test]
fn trailing_data_after_full_final_remains_rejected() -> Result<(), Error> {
    let mut encryptor = stream::Encryptor::new(&test_key());
    let mut data = encryptor.header().as_bytes().to_vec();
    data.extend(encryptor.push(&vec![0x61; stream::ENCRYPTION_CHUNK_SIZE], true)?);
    data.extend_from_slice(b"trailing data");

    assert!(matches!(
        reader(&data)?.read_to_end(),
        Err(Error::StreamTrailingData)
    ));
    Ok(())
}

#[test]
fn tampered_empty_message_is_authentication_failure() -> Result<(), Error> {
    let mut data = LIBSODIUM_EMPTY_MESSAGE.to_vec();
    let last_index = data.len() - 1;
    data[last_index] ^= 1;
    assert!(matches!(
        reader(&data)?.read_to_end(),
        Err(Error::StreamPullFailed)
    ));
    Ok(())
}
