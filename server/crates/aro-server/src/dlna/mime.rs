//! Audio container/extension → MIME type and DLNA fourth-field mapping. Renderers
//! decide whether they can play a `res` almost entirely from `protocolInfo`, so the
//! MIME type must be the real one — the sync API's `application/octet-stream` habit
//! would make most TVs skip every track.

/// MIME type for a track's original file extension (already lowercased in the
/// snapshot). Unknown extensions fall back to `application/octet-stream`, which
/// renderers treat as "attempt at your own risk".
pub fn mime_for_extension(extension: &str) -> &'static str {
    match extension {
        "flac" => "audio/flac",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" => "audio/mp4",
        "aac" => "audio/aac",
        "ogg" | "oga" => "audio/ogg",
        "opus" => "audio/opus",
        "wav" => "audio/wav",
        "aiff" | "aif" => "audio/aiff",
        "wma" => "audio/x-ms-wma",
        _ => "application/octet-stream",
    }
}

/// The DLNA fourth field of `protocolInfo`, also served verbatim as the
/// `contentFeatures.dlna.org` response header. `DLNA.ORG_PN` is only claimed for
/// mp3, where the profile is unambiguous; guessing profiles for other formats
/// (e.g. which AAC_ISO variant an .m4a is) without parsing the bitstream makes
/// strict renderers reject tracks they could have played. `OP=01` declares Range
/// seek support, which the media endpoint genuinely implements.
pub fn content_features(extension: &str) -> &'static str {
    const FLAGS: &str =
        "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000";
    match extension {
        "mp3" => {
            "DLNA.ORG_PN=MP3;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        }
        _ => FLAGS,
    }
}

/// `protocolInfo` for a `res` element.
pub fn protocol_info(extension: &str) -> String {
    format!(
        "http-get:*:{}:{}",
        mime_for_extension(extension),
        content_features(extension)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_common_audio_extensions() {
        assert_eq!(mime_for_extension("flac"), "audio/flac");
        assert_eq!(mime_for_extension("mp3"), "audio/mpeg");
        assert_eq!(mime_for_extension("m4a"), "audio/mp4");
        assert_eq!(mime_for_extension("opus"), "audio/opus");
        assert_eq!(mime_for_extension("weird"), "application/octet-stream");
    }

    #[test]
    fn only_mp3_claims_a_dlna_profile() {
        assert!(content_features("mp3").starts_with("DLNA.ORG_PN=MP3;"));
        assert!(!content_features("flac").contains("DLNA.ORG_PN"));
        assert!(content_features("flac").contains("DLNA.ORG_OP=01"));
    }

    #[test]
    fn protocol_info_is_http_get_shaped() {
        assert_eq!(
            protocol_info("mp3"),
            "http-get:*:audio/mpeg:DLNA.ORG_PN=MP3;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000"
        );
    }
}
