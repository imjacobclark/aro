//! Shared string-normalization used to compare titles/artist names across
//! AcoustID, MusicBrainz, and this crate's own affinity store — three sources
//! that don't always agree on which Unicode glyph to use for a given
//! character (observed directly: blink-182's own AcoustID-submitted
//! recordings split between `blink-182` (U+002D hyphen-minus) and `blink‐182`
//! (U+2010 hyphen) for what is unambiguously the same artist, which fractures
//! affinity tracking and every other title/artist match in this crate if left
//! un-folded).

/// Folds visually-identical dash/hyphen variants to a single ASCII `-`,
/// trims, and lowercases. Used everywhere a title or artist name is compared
/// for equality in this crate (release/hint matching, release-group
/// classification, and affinity lookups) so a difference in keyboard-vs-
/// typographic punctuation never causes a false mismatch.
pub(crate) fn normalize_matching_key(value: impl AsRef<str>) -> String {
    value
        .as_ref()
        .trim()
        .chars()
        .map(|ch| match ch {
            '\u{2010}' | '\u{2011}' | '\u{2012}' | '\u{2013}' | '\u{2014}' | '\u{2212}' => '-',
            other => other,
        })
        .collect::<String>()
        .to_lowercase()
}

/// Similarity in `[0.0, 1.0]` between two titles that may differ only in packaging
/// (a remaster year, a "Live" tag, a parenthetical qualifier) rather than substance — e.g.
/// a rip's own title tag "December" against a MusicBrainz track title
/// "December (2015 Remaster)". `1.0` for exact match after [`normalize_matching_key`];
/// otherwise the Jaccard index (intersection over union) of the two titles' alphanumeric
/// token sets, after stripping one trailing bracketed qualifier
/// (`(Remastered 2009)`/`[Live]`) and one trailing `- (year) remaster...` dash suffix — the
/// two shapes actually observed between a rip's tags and MusicBrainz's track titles. `0.0`
/// if either title has no tokens left after stripping.
pub(crate) fn title_similarity(a: &str, b: &str) -> f64 {
    let normalized_a = normalize_matching_key(a);
    let normalized_b = normalize_matching_key(b);
    if normalized_a == normalized_b {
        return 1.0;
    }
    let tokens_a = title_tokens(&normalized_a);
    let tokens_b = title_tokens(&normalized_b);
    if tokens_a.is_empty() || tokens_b.is_empty() {
        return 0.0;
    }
    let intersection = tokens_a.intersection(&tokens_b).count();
    let union = tokens_a.union(&tokens_b).count();
    intersection as f64 / union as f64
}

fn title_tokens(normalized: &str) -> std::collections::HashSet<String> {
    let stripped = strip_remaster_suffix(strip_trailing_bracket(normalized.trim()));
    stripped
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|token| !token.is_empty())
        .map(str::to_owned)
        .collect()
}

/// Strips one trailing `(...)` or `[...]` qualifier, e.g. `"December (2015 Remaster)"` ->
/// `"December"` or `"December [Live]"` -> `"December"`.
fn strip_trailing_bracket(value: &str) -> &str {
    if value.ends_with(')')
        && let Some(open) = value.rfind('(')
    {
        return value[..open].trim_end();
    }
    if value.ends_with(']')
        && let Some(open) = value.rfind('[')
    {
        return value[..open].trim_end();
    }
    value
}

/// Strips a trailing `- (optional 4-digit year) remaster...` suffix, e.g.
/// `"december - 2015 remaster"` -> `"december"`. Deliberately narrow (requires the literal
/// word "remaster" after the dash) rather than stripping on any `" - "`, since a title can
/// legitimately contain a dash-separated subtitle that isn't a packaging qualifier.
fn strip_remaster_suffix(value: &str) -> &str {
    let Some(dash) = value.rfind(" - ") else {
        return value;
    };
    let mut suffix = value[dash + 3..].trim_start();
    let starts_with_year =
        suffix.len() >= 4 && suffix.as_bytes()[..4].iter().all(u8::is_ascii_digit);
    if starts_with_year {
        suffix = suffix[4..].trim_start();
    }
    if suffix.starts_with("remaster") {
        value[..dash].trim_end()
    } else {
        value
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_similarity_is_one_for_exact_normalized_equality() {
        assert_eq!(title_similarity("December", "december"), 1.0);
        assert_eq!(title_similarity("blink-182", "blink\u{2010}182"), 1.0);
    }

    #[test]
    fn title_similarity_ignores_remaster_and_live_qualifiers() {
        assert_eq!(title_similarity("December", "December (2015 Remaster)"), 1.0);
        assert_eq!(title_similarity("December", "December [Live]"), 1.0);
        assert_eq!(title_similarity("December", "December - 2015 Remaster"), 1.0);
        assert_eq!(title_similarity("December", "December - Remastered"), 1.0);
    }

    #[test]
    fn title_similarity_does_not_strip_a_legitimate_dash_subtitle() {
        // Not a packaging qualifier -- must not be stripped just because it follows " - ".
        let similarity = title_similarity(
            "Life's Not Out to Get You",
            "Life's Not Out to Get You - The Real Story",
        );
        assert!(
            similarity < 1.0,
            "expected a real subtitle to reduce similarity, got {similarity}"
        );
    }

    #[test]
    fn title_similarity_is_partial_for_overlapping_but_different_titles() {
        let similarity = title_similarity("Ticket to Ride", "Ticket to Ride (Stereo)");
        // Any trailing bracket strips as a qualifier -- generic by design, not restricted to
        // remaster/live -- leaving an exact match here.
        assert_eq!(similarity, 1.0);

        // No bracket/dash qualifier to strip, so this is a genuine partial token overlap:
        // {ticket,to,ride} vs {ticket,to,ride,extended} = 3/4.
        let similarity = title_similarity("Ticket to Ride", "Ticket To Ride Extended");
        assert!(
            similarity > 0.0 && similarity < 1.0,
            "expected partial overlap, got {similarity}"
        );
    }

    #[test]
    fn title_similarity_is_zero_for_unrelated_titles() {
        assert_eq!(title_similarity("December", "Ticket to Ride"), 0.0);
    }
}
