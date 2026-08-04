//! ConnectionManager:1 — required by the MediaServer:1 device spec, but for an
//! HTTP-GET-only server the answers are constants: the source protocol list and a
//! single implicit connection with ID 0.

use axum::{
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};

const SOAP_OPEN: &str = r#"<?xml version="1.0" encoding="utf-8"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>"#;
const SOAP_CLOSE: &str = "</s:Body></s:Envelope>";

/// Every protocolInfo this server can emit, advertised via `GetProtocolInfo`.
/// Kept to the MIME level (fourth field `*`): the per-track fourth field is
/// declared on each `res` element instead.
const SOURCE_PROTOCOLS: &str = "http-get:*:audio/flac:*,http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,http-get:*:audio/aac:*,http-get:*:audio/ogg:*,http-get:*:audio/opus:*,http-get:*:audio/wav:*,http-get:*:audio/aiff:*,http-get:*:audio/x-ms-wma:*";

pub async fn control(headers: HeaderMap, body: String) -> Response {
    let action = headers
        .get("soapaction")
        .and_then(|value| value.to_str().ok())
        .map(|value| value.trim().trim_matches('"'))
        .and_then(|value| value.rsplit_once('#'))
        .map(|(_, action)| action.to_string())
        .or_else(|| {
            [
                "GetProtocolInfo",
                "GetCurrentConnectionIDs",
                "GetCurrentConnectionInfo",
            ]
            .into_iter()
            .find(|action| body.contains(action))
            .map(str::to_string)
        });
    match action.as_deref() {
        Some("GetProtocolInfo") => respond(
            "GetProtocolInfo",
            &format!("<Source>{SOURCE_PROTOCOLS}</Source><Sink></Sink>"),
        ),
        Some("GetCurrentConnectionIDs") => {
            respond("GetCurrentConnectionIDs", "<ConnectionIDs>0</ConnectionIDs>")
        }
        Some("GetCurrentConnectionInfo") => respond(
            "GetCurrentConnectionInfo",
            "<RcsID>-1</RcsID><AVTransportID>-1</AVTransportID><ProtocolInfo></ProtocolInfo><PeerConnectionManager></PeerConnectionManager><PeerConnectionID>-1</PeerConnectionID><Direction>Output</Direction><Status>OK</Status>",
        ),
        _ => (
            StatusCode::INTERNAL_SERVER_ERROR,
            [(header::CONTENT_TYPE, r#"text/xml; charset="utf-8""#)],
            format!(
                r#"{SOAP_OPEN}<s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>401</errorCode><errorDescription>Invalid Action</errorDescription></UPnPError></detail></s:Fault>{SOAP_CLOSE}"#
            ),
        )
            .into_response(),
    }
}

fn respond(action: &str, arguments: &str) -> Response {
    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, r#"text/xml; charset="utf-8""#)],
        format!(
            r#"{SOAP_OPEN}<u:{action}Response xmlns:u="urn:schemas-upnp-org:service:ConnectionManager:1">{arguments}</u:{action}Response>{SOAP_CLOSE}"#
        ),
    )
        .into_response()
}
