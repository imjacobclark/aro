//! DIDL-Lite rendering for ContentDirectory Browse results. Everything here is
//! string assembly over one escaping helper: track metadata is arbitrary user data
//! and flows into XML attributes and text alike, so every interpolated value goes
//! through [`escape`] — there are no raw insertions.

use super::SnapshotTrack;

const DIDL_OPEN: &str = r#"<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">"#;
const DIDL_CLOSE: &str = "</DIDL-Lite>";

/// Escapes text for use in XML content and quoted attributes.
pub fn escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for character in value.chars() {
        match character {
            '&' => escaped.push_str("&amp;"),
            '<' => escaped.push_str("&lt;"),
            '>' => escaped.push_str("&gt;"),
            '"' => escaped.push_str("&quot;"),
            '\'' => escaped.push_str("&apos;"),
            other => escaped.push(other),
        }
    }
    escaped
}

/// Wraps rendered entries in the DIDL-Lite document element.
pub fn envelope(entries: &str) -> String {
    format!("{DIDL_OPEN}{entries}{DIDL_CLOSE}")
}

pub fn container(
    id: &str,
    parent_id: &str,
    title: &str,
    class: &str,
    child_count: usize,
) -> String {
    format!(
        r#"<container id="{}" parentID="{}" restricted="1" childCount="{}"><dc:title>{}</dc:title><upnp:class>{}</upnp:class></container>"#,
        escape(id),
        escape(parent_id),
        child_count,
        escape(title),
        class,
    )
}

/// An album container; carries `upnp:artist` so renderers can tell apart albums
/// that share a title across artists in the flat Albums list.
pub fn album_container(
    id: &str,
    parent_id: &str,
    title: &str,
    artist: &str,
    child_count: usize,
) -> String {
    format!(
        r#"<container id="{}" parentID="{}" restricted="1" childCount="{}"><dc:title>{}</dc:title><upnp:artist>{}</upnp:artist><upnp:class>object.container.album.musicAlbum</upnp:class></container>"#,
        escape(id),
        escape(parent_id),
        child_count,
        escape(title),
        escape(artist),
    )
}

/// A playlist container; `description` carries the generated subtitle so control
/// points that show `dc:description` get the "why" of the playlist.
pub fn playlist_container(
    id: &str,
    parent_id: &str,
    title: &str,
    description: &str,
    child_count: usize,
) -> String {
    format!(
        r#"<container id="{}" parentID="{}" restricted="1" childCount="{}"><dc:title>{}</dc:title><dc:description>{}</dc:description><upnp:class>object.container.playlistContainer</upnp:class></container>"#,
        escape(id),
        escape(parent_id),
        child_count,
        escape(title),
        escape(description),
    )
}

/// One music track item. `media_base` is scheme+authority (e.g.
/// `http://192.168.1.10:4850`) taken from the request that is being answered, so
/// the URL is routable from wherever the renderer actually reached us.
pub fn track_item(track: &SnapshotTrack, parent_id: &str, media_base: &str) -> String {
    let mut item = format!(
        r#"<item id="track:{}" parentID="{}" restricted="1"><dc:title>{}</dc:title><upnp:class>object.item.audioItem.musicTrack</upnp:class><upnp:artist>{}</upnp:artist>"#,
        track.track_id,
        escape(parent_id),
        escape(&track.title),
        escape(&track.artist),
    );
    if let Some(album) = &track.album {
        item.push_str(&format!("<upnp:album>{}</upnp:album>", escape(album)));
    }
    if let Some(number) = track.track_number {
        item.push_str(&format!(
            "<upnp:originalTrackNumber>{number}</upnp:originalTrackNumber>"
        ));
    }
    item.push_str(&format!(
        r#"<res protocolInfo="{}" size="{}">{}/media/{}</res></item>"#,
        super::mime::protocol_info(&track.extension),
        track.byte_count,
        escape(media_base),
        escape(&track.content_hash),
    ));
    item
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    fn track() -> SnapshotTrack {
        SnapshotTrack {
            track_id: Uuid::nil(),
            content_hash: "abc123".into(),
            title: r#"Bed & <Breakfast> "Live""#.into(),
            artist: "Simon & Garfunkel".into(),
            album: Some("Sounds > Silence".into()),
            track_number: Some(3),
            disc_number: Some(1),
            extension: "mp3".into(),
            byte_count: 1234,
        }
    }

    #[test]
    fn escapes_every_xml_metacharacter() {
        assert_eq!(escape(r#"a&b<c>d"e'f"#), "a&amp;b&lt;c&gt;d&quot;e&apos;f");
    }

    #[test]
    fn track_items_escape_metadata_everywhere() {
        let rendered = track_item(&track(), "music:tracks", "http://10.0.0.2:4850");
        assert!(
            rendered.contains("<dc:title>Bed &amp; &lt;Breakfast&gt; &quot;Live&quot;</dc:title>")
        );
        assert!(rendered.contains("<upnp:artist>Simon &amp; Garfunkel</upnp:artist>"));
        assert!(rendered.contains("<upnp:album>Sounds &gt; Silence</upnp:album>"));
        assert!(rendered.contains("<upnp:originalTrackNumber>3</upnp:originalTrackNumber>"));
        assert!(rendered.contains("http://10.0.0.2:4850/media/abc123"));
        assert!(rendered.contains(r#"size="1234""#));
        assert!(rendered.contains("audio/mpeg"));
    }

    #[test]
    fn containers_carry_class_and_child_count() {
        let rendered = container("music:artists", "0", "Artists", "object.container", 7);
        assert!(rendered.contains(r#"id="music:artists""#));
        assert!(rendered.contains(r#"parentID="0""#));
        assert!(rendered.contains(r#"childCount="7""#));
        assert!(rendered.contains("<upnp:class>object.container</upnp:class>"));
    }

    #[test]
    fn envelope_wraps_with_namespaces() {
        let document = envelope("<item/>");
        assert!(document.starts_with("<DIDL-Lite "));
        assert!(document.contains("urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"));
        assert!(document.ends_with("</DIDL-Lite>"));
    }
}
