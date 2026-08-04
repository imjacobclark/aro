//! Discovery of the artwork a listener could reasonably choose for a track, as opposed to
//! the single cover identification happened to settle on.
//!
//! Identification stores exactly one image per track: the front cover of the one release it
//! matched (`queue::cache_artwork`). That is the right default and the wrong menu. The
//! Cover Art Archive is populated per *release*, so the nine separate pressings MusicBrainz
//! carries for one album can hold nine different scans, and the pressing we matched is
//! frequently not the one anybody uploaded art for. A picker that only offers the matched
//! release's cover therefore hides most of what actually exists.
//!
//! Two directions are searched, which is what "recursive and adjacent" amounts to in
//! practice:
//!
//! - **This album, every pressing.** Walk the release-group to its releases and read each
//!   one's full archive manifest, not the `/front` redirect — a release can have several
//!   images, and the archive's chosen "front" isn't always the packaging the listener
//!   recognises.
//! - **The artist's other albums.** One cover each, from the release-group manifest. This
//!   is what makes a self-titled record or a mis-filed compilation recoverable by hand.
//!
//! Only thumbnails are fetched here. A grid of full-size originals would be tens of
//! megabytes for one artist, on a hub that may well be a Raspberry Pi; the full-resolution
//! image is fetched once, later, for whichever candidate is actually chosen (see
//! [`resolve_full_image`]).
//!
//! Everything is bounded and cached: MusicBrainz allows roughly one request a second, so an
//! uncapped walk of a prolific artist would take minutes and be antisocial besides.

use crate::musicbrainz::{self, MusicBrainzClient};
use aro_sync_store::HubStore;
use serde::{Deserialize, Serialize};

/// Pressings of the current album to read manifests for. Enough to cover the real
/// fragmentation seen in the wild (nine "Greatest Hits" pressings for The Shadows) without
/// letting a heavily-reissued record dominate the request budget.
const MAX_PRESSINGS: usize = 12;

/// Other release-groups by the artist to offer one cover each for. A prolific artist has
/// hundreds; a picker is not a discography browser, and every one costs a request.
const MAX_OTHER_RELEASE_GROUPS: usize = 25;

/// Images taken from any single release's manifest. Archives sometimes hold a dozen scans
/// of one package (front, back, every inlay and disc face); the first few carry almost all
/// the value for choosing a cover.
const MAX_IMAGES_PER_RELEASE: usize = 4;

/// Where a candidate came from, so the picker can group them rather than presenting one
/// undifferentiated wall of images.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ArtworkOrigin {
    /// A pressing of the album this track is currently filed under.
    ThisAlbum,
    /// A different album by the same artist.
    ArtistCatalogue,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArtworkCandidate {
    /// Hub blob path for the thumbnail, already cached — the client renders this and never
    /// talks to the Cover Art Archive itself.
    pub thumbnail: String,
    /// The archive's full-resolution URL, resolved only if this candidate is chosen.
    pub full_image_url: String,
    pub origin: ArtworkOrigin,
    /// Album title this image belongs to, for labelling in the picker.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub album: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub release_group_id: Option<String>,
    pub is_front: bool,
}

/// Assembles the candidate set for one track. Failures are absorbed rather than propagated:
/// artwork is decorative, and a picker that shows five covers because the sixth request
/// timed out is far better than one that shows an error.
#[allow(clippy::too_many_arguments)]
pub async fn discover_candidates(
    musicbrainz: &MusicBrainzClient,
    http: &reqwest::Client,
    user_agent: &str,
    store: &HubStore,
    release_id: Option<&str>,
    release_group_id: Option<&str>,
    album: Option<&str>,
) -> Vec<ArtworkCandidate> {
    let mut candidates = Vec::new();
    let mut seen_urls = std::collections::HashSet::new();

    // The artist MBID isn't stored with identification results, so it comes from the
    // matched release — which is also where the current album's release-group comes from
    // when identification didn't record one.
    let mut artist_mbid = None;
    let mut current_group = release_group_id.map(str::to_owned);
    if let Some(release_id) = release_id
        && let Ok(release) = musicbrainz.release(release_id).await
    {
        artist_mbid = release
            .artist_credit
            .iter()
            .find_map(|credit| credit.artist.as_ref().map(|artist| artist.id.clone()));
        if current_group.is_none() {
            current_group = release
                .release_group
                .as_ref()
                .and_then(|group| group.id.clone());
        }
    }

    if let Some(group_id) = current_group.as_deref() {
        let releases = musicbrainz
            .releases_in_group(group_id, MAX_PRESSINGS)
            .await
            .unwrap_or_default();
        for release in releases.into_iter().take(MAX_PRESSINGS) {
            let images =
                musicbrainz::fetch_cover_art_manifest(http, user_agent, &release.id).await;
            for image in images.into_iter().take(MAX_IMAGES_PER_RELEASE) {
                push_candidate(
                    &mut candidates,
                    &mut seen_urls,
                    store,
                    http,
                    user_agent,
                    &image,
                    ArtworkOrigin::ThisAlbum,
                    release
                        .title
                        .clone()
                        .or_else(|| album.map(str::to_owned)),
                    Some(release.id.clone()),
                    Some(group_id.to_owned()),
                )
                .await;
            }
        }
    }

    if let Some(artist_mbid) = artist_mbid.as_deref() {
        let groups = musicbrainz
            .release_groups_for_artist(artist_mbid, MAX_OTHER_RELEASE_GROUPS)
            .await
            .unwrap_or_default();
        for group in groups.into_iter().take(MAX_OTHER_RELEASE_GROUPS) {
            let Some(group_id) = group.id.clone() else {
                continue;
            };
            if current_group.as_deref() == Some(group_id.as_str()) {
                continue;
            }
            let images =
                musicbrainz::fetch_release_group_cover_art_manifest(http, user_agent, &group_id)
                    .await;
            // One cover per other album: the point is breadth across the catalogue, not
            // depth on any single record.
            let Some(image) = images
                .iter()
                .find(|image| image.front)
                .or_else(|| images.first())
            else {
                continue;
            };
            push_candidate(
                &mut candidates,
                &mut seen_urls,
                store,
                http,
                user_agent,
                image,
                ArtworkOrigin::ArtistCatalogue,
                group.title.clone(),
                None,
                Some(group_id),
            )
            .await;
        }
    }

    candidates
}

#[allow(clippy::too_many_arguments)]
async fn push_candidate(
    candidates: &mut Vec<ArtworkCandidate>,
    seen_urls: &mut std::collections::HashSet<String>,
    store: &HubStore,
    http: &reqwest::Client,
    user_agent: &str,
    image: &musicbrainz::CoverArtImage,
    origin: ArtworkOrigin,
    album: Option<String>,
    release_id: Option<String>,
    release_group_id: Option<String>,
) {
    let Some(full_image_url) = image.image.clone() else {
        return;
    };
    // The same scan is frequently attached to several pressings of one album; showing it
    // repeatedly wastes the grid.
    if !seen_urls.insert(full_image_url.clone()) {
        return;
    }
    let Some(thumbnail_url) = image.thumbnail_url() else {
        return;
    };
    let Some(bytes) = musicbrainz::fetch_cover_art_image(http, user_agent, thumbnail_url).await
    else {
        return;
    };
    let Some(thumbnail) = import_blob(store, &bytes) else {
        return;
    };
    candidates.push(ArtworkCandidate {
        thumbnail,
        full_image_url,
        origin,
        album,
        release_id,
        release_group_id,
        is_front: image.front,
    });
}

/// Fetches the full-resolution original for a chosen candidate and caches it as a blob.
/// Separate from discovery precisely so the expensive bytes are only ever paid for once a
/// listener has actually settled on an image.
pub async fn resolve_full_image(
    http: &reqwest::Client,
    user_agent: &str,
    store: &HubStore,
    image_url: &str,
) -> Option<String> {
    let bytes = musicbrainz::fetch_cover_art_image(http, user_agent, image_url).await?;
    import_blob(store, &bytes)
}

fn import_blob(store: &HubStore, bytes: &[u8]) -> Option<String> {
    let temp = tempfile::NamedTempFile::new().ok()?;
    std::fs::write(temp.path(), bytes).ok()?;
    let (hash, _size) = store.import_managed(temp.path()).ok()?;
    Some(format!("/v1/blobs/{hash}"))
}
