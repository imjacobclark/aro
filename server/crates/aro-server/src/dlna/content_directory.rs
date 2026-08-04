//! ContentDirectory:1 SOAP control endpoint — Browse plus the three capability
//! getters. Requests are parsed with quick-xml matching on *local* names only:
//! renderers disagree wildly about namespace prefixes (`u:Browse`, `m:Browse`,
//! `ns0:Browse`…), and the four fields read here are simple scalars.

use super::{DlnaState, didl};
use axum::{
    extract::State,
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use quick_xml::{Reader, events::Event};
use std::{collections::HashMap, sync::Arc};

const SOAP_OPEN: &str = r#"<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#;
const SOAP_CLOSE: &str = "</s:Body></s:Envelope>";

pub async fn control(
    State(state): State<Arc<DlnaState>>,
    headers: HeaderMap,
    body: String,
) -> Response {
    let action = soap_action(&headers, &body);
    match action.as_deref() {
        Some("Browse") => browse(&state, &headers, &body).await,
        Some("GetSystemUpdateID") => {
            let id = state.system_update_id().await;
            action_response("GetSystemUpdateID", &format!("<Id>{id}</Id>"))
        }
        Some("GetSearchCapabilities") => {
            action_response("GetSearchCapabilities", "<SearchCaps></SearchCaps>")
        }
        Some("GetSortCapabilities") => {
            action_response("GetSortCapabilities", "<SortCaps></SortCaps>")
        }
        _ => fault(401, "Invalid Action"),
    }
}

async fn browse(state: &DlnaState, headers: &HeaderMap, body: &str) -> Response {
    let fields = soap_fields(
        body,
        &["ObjectID", "BrowseFlag", "StartingIndex", "RequestedCount"],
    );
    let Some(object_id) = fields.get("ObjectID") else {
        return fault(402, "Invalid Args");
    };
    let browse_flag = fields
        .get("BrowseFlag")
        .map(String::as_str)
        .unwrap_or("BrowseDirectChildren");
    let starting_index = fields
        .get("StartingIndex")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    let requested_count = fields
        .get("RequestedCount")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);

    let media_base = match media_base(headers) {
        Some(base) => base,
        None => return fault(501, "Action Failed"),
    };

    let result = match browse_flag {
        "BrowseMetadata" => state.browse_metadata(object_id, &media_base).await,
        _ => {
            state
                .browse_children(object_id, starting_index, requested_count, &media_base)
                .await
        }
    };
    match result {
        Ok(listing) => {
            let update_id = state.system_update_id().await;
            action_response(
                "Browse",
                &format!(
                    "<Result>{}</Result><NumberReturned>{}</NumberReturned><TotalMatches>{}</TotalMatches><UpdateID>{update_id}</UpdateID>",
                    didl::escape(&didl::envelope(&listing.entries)),
                    listing.returned,
                    listing.total,
                ),
            )
        }
        Err(super::BrowseError::NoSuchObject) => fault(701, "No such object"),
        Err(super::BrowseError::Internal) => fault(501, "Action Failed"),
    }
}

/// Scheme+authority for `res`/media URLs, from the Host header the renderer used
/// to reach this listener — necessarily an address routable from that renderer.
fn media_base(headers: &HeaderMap) -> Option<String> {
    let host = headers.get(header::HOST)?.to_str().ok()?;
    Some(format!("http://{host}"))
}

/// The action name from the `SOAPACTION` header
/// (`"urn:...:ContentDirectory:1#Browse"`), falling back to sniffing the body for
/// renderers that omit the header.
fn soap_action(headers: &HeaderMap, body: &str) -> Option<String> {
    if let Some(value) = headers
        .get("soapaction")
        .and_then(|value| value.to_str().ok())
    {
        let trimmed = value.trim().trim_matches('"');
        if let Some((_, action)) = trimmed.rsplit_once('#') {
            return Some(action.to_string());
        }
    }
    for action in [
        "Browse",
        "GetSystemUpdateID",
        "GetSearchCapabilities",
        "GetSortCapabilities",
    ] {
        if body.contains(&format!("{action}>")) || body.contains(&format!("{action} ")) {
            return Some(action.to_string());
        }
    }
    None
}

/// Extracts the text content of the named elements, matched by local name so any
/// namespace prefix works.
fn soap_fields(body: &str, names: &[&str]) -> HashMap<String, String> {
    let mut reader = Reader::from_str(body);
    reader.config_mut().trim_text(true);
    let mut fields = HashMap::new();
    let mut current: Option<String> = None;
    loop {
        match reader.read_event() {
            Ok(Event::Start(start)) => {
                let local = String::from_utf8_lossy(start.local_name().as_ref()).to_string();
                current = names
                    .iter()
                    .find(|name| ***name == local)
                    .map(|name| name.to_string());
                if let Some(name) = &current {
                    // An empty element or immediate close yields no Text event;
                    // default the field so presence is still recorded.
                    fields.entry(name.clone()).or_default();
                }
            }
            Ok(Event::Text(text)) => {
                if let Some(name) = &current
                    && let Ok(value) = text.unescape()
                {
                    fields.insert(name.clone(), value.to_string());
                }
            }
            Ok(Event::End(_)) => current = None,
            Ok(Event::Eof) => break,
            Err(_) => break,
            _ => {}
        }
    }
    fields
}

fn action_response(action: &str, arguments: &str) -> Response {
    let body = format!(
        r#"{SOAP_OPEN}<u:{action}Response xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1">{arguments}</u:{action}Response>{SOAP_CLOSE}"#
    );
    xml_response(StatusCode::OK, body)
}

fn fault(code: u16, description: &str) -> Response {
    let body = format!(
        r#"{SOAP_OPEN}<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>{code}</errorCode><errorDescription>{description}</errorDescription></UPnPError></detail></s:Fault>{SOAP_CLOSE}"#
    );
    xml_response(StatusCode::INTERNAL_SERVER_ERROR, body)
}

fn xml_response(status: StatusCode, body: String) -> Response {
    (
        status,
        [(header::CONTENT_TYPE, r#"text/xml; charset="utf-8""#)],
        body,
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn soap_fields_ignore_namespace_prefixes() {
        for prefix in ["u", "m", "ns0"] {
            let body = format!(
                r#"<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><{prefix}:Browse xmlns:{prefix}="urn:schemas-upnp-org:service:ContentDirectory:1"><ObjectID>music:artists</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><StartingIndex>5</StartingIndex><RequestedCount>10</RequestedCount></{prefix}:Browse></s:Body></s:Envelope>"#
            );
            let fields = soap_fields(
                &body,
                &["ObjectID", "BrowseFlag", "StartingIndex", "RequestedCount"],
            );
            assert_eq!(fields.get("ObjectID").unwrap(), "music:artists");
            assert_eq!(fields.get("BrowseFlag").unwrap(), "BrowseDirectChildren");
            assert_eq!(fields.get("StartingIndex").unwrap(), "5");
            assert_eq!(fields.get("RequestedCount").unwrap(), "10");
        }
    }

    #[test]
    fn empty_object_id_is_still_present() {
        let body = r#"<Envelope><Body><Browse><ObjectID></ObjectID></Browse></Body></Envelope>"#;
        let fields = soap_fields(body, &["ObjectID"]);
        assert_eq!(fields.get("ObjectID").unwrap(), "");
    }

    #[test]
    fn action_comes_from_the_soapaction_header() {
        let mut headers = HeaderMap::new();
        headers.insert(
            "soapaction",
            r#""urn:schemas-upnp-org:service:ContentDirectory:1#Browse""#
                .parse()
                .unwrap(),
        );
        assert_eq!(soap_action(&headers, "").as_deref(), Some("Browse"));
    }

    #[test]
    fn action_falls_back_to_body_sniffing() {
        let headers = HeaderMap::new();
        let body = r#"<s:Body><u:GetSystemUpdateID xmlns:u="x"/></s:Body>"#;
        assert_eq!(
            soap_action(&headers, body).as_deref(),
            Some("GetSystemUpdateID")
        );
    }

    #[test]
    fn media_base_uses_the_host_header() {
        let mut headers = HeaderMap::new();
        headers.insert(header::HOST, "192.168.1.5:4850".parse().unwrap());
        assert_eq!(media_base(&headers).unwrap(), "http://192.168.1.5:4850");
    }
}
