use sha2::{Digest, Sha256};
use std::{
    fs::File,
    io::{self, Read},
    path::{Component, Path},
};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum BlobError {
    #[error("invalid SHA-256 hash")]
    InvalidHash,
    #[error("unsafe path")]
    UnsafePath,
    #[error("blob hash mismatch")]
    HashMismatch,
    #[error(transparent)]
    Io(#[from] io::Error),
}

pub fn validate_hash(hash: &str) -> Result<(), BlobError> {
    if hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        Ok(())
    } else {
        Err(BlobError::InvalidHash)
    }
}

pub fn validate_relative_path(path: &Path) -> Result<(), BlobError> {
    if path.is_absolute()
        || path.components().any(|c| {
            matches!(
                c,
                Component::ParentDir | Component::RootDir | Component::Prefix(_)
            )
        })
    {
        return Err(BlobError::UnsafePath);
    }
    Ok(())
}

pub fn verify_file(path: &Path, expected_hash: &str) -> Result<u64, BlobError> {
    let (actual_hash, size) = hash_file(path)?;
    validate_hash(expected_hash)?;
    if actual_hash.eq_ignore_ascii_case(expected_hash) {
        Ok(size)
    } else {
        Err(BlobError::HashMismatch)
    }
}

pub fn hash_file(path: &Path) -> Result<(String, u64), BlobError> {
    let mut file = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 128 * 1024];
    let mut size = 0_u64;
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
        size += read as u64;
    }
    Ok((hex::encode(digest.finalize()), size))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn rejects_traversal_and_verifies_without_cache() {
        assert!(validate_relative_path(Path::new("../secret")).is_err());
        let mut file = tempfile::NamedTempFile::new().unwrap();
        file.write_all(b"aro").unwrap();
        let hash = hex::encode(Sha256::digest(b"aro"));
        assert_eq!(verify_file(file.path(), &hash).unwrap(), 3);
        assert!(verify_file(file.path(), &"0".repeat(64)).is_err());
    }
}
