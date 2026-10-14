//! The sync server's API, as the app calls it. The shapes mirror
//! packages/api/src/index.ts; keep the two in step.

use std::io::Read;
use std::time::Duration;

use serde::Deserialize;

/// The app's client ID for Better Auth's device sign-in (APP_CLIENT_ID).
pub const APP_CLIENT_ID: &str = "road-to-sixty-app";

/// The test server on everhold.online. Builds for players set RTS_SERVER.
pub const TEST_SERVER: &str = "https://api.rts.everhold.online";

/// The most a merged journey may unpack to; the server refuses more.
const MAX_JOURNEY: u64 = 32 * 1024 * 1024;

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct UploadResponse {
    pub version: i64,
    /// "queued", or "known" when this exact file was uploaded before.
    pub status: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct CheckEntry {
    pub game: String,
    pub realm: String,
    pub name: String,
    /// None when it needs a newer addon than this PC has.
    pub version: Option<i64>,
    pub fingerprint: String,
    pub replace: bool,
    #[serde(rename = "updateAddon")]
    pub update_addon: bool,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct CheckResponse {
    pub characters: Vec<CheckEntry>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct LinkResponse {
    /// The PC token, for every /v1 call.
    pub token: String,
    /// This PC's ID, which the addon keeps its counts under.
    pub pc: String,
    /// Who the PC is linked to.
    pub battletag: String,
}

/// Better Auth's answer to /api/auth/device/code (RFC 8628).
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct DeviceCode {
    pub device_code: String,
    pub user_code: String,
    pub verification_uri_complete: String,
    /// Seconds to wait between polls.
    pub interval: u64,
    pub expires_in: u64,
}

/// One poll of /api/auth/device/token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DevicePoll {
    /// Approved: the session token to trade at /v1/link.
    Approved(String),
    Pending,
    SlowDown,
    /// Denied, expired, or anything else that ends the attempt.
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ApiError {
    /// The PC token is missing, unknown or revoked: link the PC again.
    Unauthorized,
    Status(u16, String),
    /// No answer: offline, or the server is down. Try again later.
    Network(String),
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ApiError::Unauthorized => write!(f, "this PC isn't linked"),
            ApiError::Status(code, body) => write!(f, "the server answered {code}: {body}"),
            ApiError::Network(why) => write!(f, "couldn't reach the server: {why}"),
        }
    }
}

impl std::error::Error for ApiError {}

pub struct Client {
    agent: ureq::Agent,
    server: String,
    token: Option<String>,
}

type Reply = ureq::http::Response<ureq::Body>;

impl Client {
    pub fn new(server: &str, token: Option<String>) -> Self {
        let agent = ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(Some(Duration::from_secs(120)))
            .build()
            .into();
        Client {
            agent,
            server: server.trim_end_matches('/').to_string(),
            token,
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.server)
    }

    fn bearer(&self) -> String {
        format!("Bearer {}", self.token.as_deref().unwrap_or(""))
    }

    /// A character's SavedVariables file, compressed with zstd on the way.
    /// `received` is the version the addon last brought in (syncedVersion).
    pub fn upload(
        &self,
        game: &str,
        realm: &str,
        name: &str,
        addon: Option<&str>,
        received: Option<i64>,
        file: &[u8],
    ) -> Result<UploadResponse, ApiError> {
        let packed = zstd::encode_all(file, 3).map_err(|e| ApiError::Network(e.to_string()))?;
        let mut request = self
            .agent
            .post(self.url("/v1/upload"))
            .header("authorization", self.bearer())
            .query("game", game)
            .query("realm", realm)
            .query("name", name);
        if let Some(addon) = addon {
            request = request.query("addon", addon);
        }
        if let Some(received) = received {
            request = request.query("received", received.to_string());
        }
        json(request.send(&packed[..]))
    }

    pub fn check(&self) -> Result<CheckResponse, ApiError> {
        json(self.agent.get(self.url("/v1/check")).header("authorization", self.bearer()).call())
    }

    /// One merged or restored version, as Parse.Write text.
    pub fn download(&self, version: i64) -> Result<String, ApiError> {
        let mut reply = ok(self
            .agent
            .get(self.url(&format!("/v1/versions/{version}")))
            .header("authorization", self.bearer())
            .call())?;
        let packed = reply
            .body_mut()
            .with_config()
            .limit(MAX_JOURNEY)
            .read_to_vec()
            .map_err(|e| ApiError::Network(e.to_string()))?;
        let mut text = Vec::new();
        zstd::Decoder::new(&packed[..])
            .and_then(|d| d.take(MAX_JOURNEY + 1).read_to_end(&mut text))
            .map_err(|e| ApiError::Status(200, format!("not a journey: {e}")))?;
        if text.len() as u64 > MAX_JOURNEY {
            return Err(ApiError::Status(200, "the journey is over 32 MB".into()));
        }
        String::from_utf8(text).map_err(|_| ApiError::Status(200, "the journey isn't text".into()))
    }

    pub fn device_code(&self) -> Result<DeviceCode, ApiError> {
        json(
            self.agent
                .post(self.url("/api/auth/device/code"))
                .send_json(serde_json::json!({ "client_id": APP_CLIENT_ID })),
        )
    }

    pub fn device_token(&self, device_code: &str) -> Result<DevicePoll, ApiError> {
        let body = serde_json::json!({
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": device_code,
            "client_id": APP_CLIENT_ID,
        });
        let mut reply = self
            .agent
            .post(self.url("/api/auth/device/token"))
            .send_json(body)
            .map_err(network)?;
        let answer: serde_json::Value = reply.body_mut().read_json().map_err(network)?;
        if let Some(token) = answer["access_token"].as_str() {
            return Ok(DevicePoll::Approved(token.to_string()));
        }
        Ok(match answer["error"].as_str() {
            Some("authorization_pending") => DevicePoll::Pending,
            Some("slow_down") => DevicePoll::SlowDown,
            other => DevicePoll::Failed(answer["error_description"].as_str().or(other).unwrap_or("no answer").to_string()),
        })
    }

    /// Trades the device sign-in's session for this PC's own token.
    pub fn link(&self, session: &str, name: &str, platform: &str) -> Result<LinkResponse, ApiError> {
        json(
            self.agent
                .post(self.url("/v1/link"))
                .header("authorization", format!("Bearer {session}"))
                .query("name", name)
                .query("platform", platform)
                .send_empty(),
        )
    }
}

fn network(e: ureq::Error) -> ApiError {
    ApiError::Network(e.to_string())
}

fn ok(reply: Result<Reply, ureq::Error>) -> Result<Reply, ApiError> {
    let mut reply = reply.map_err(network)?;
    match reply.status().as_u16() {
        200..=299 => Ok(reply),
        401 => Err(ApiError::Unauthorized),
        // The server is down or failing: like no answer, try again later.
        code @ 500..=599 => Err(ApiError::Network(format!("the server answered {code}"))),
        code => Err(ApiError::Status(code, reply.body_mut().read_to_string().unwrap_or_default())),
    }
}

fn json<T: serde::de::DeserializeOwned>(reply: Result<Reply, ureq::Error>) -> Result<T, ApiError> {
    ok(reply)?.body_mut().read_json().map_err(network)
}

#[cfg(any(test, feature = "fake"))]
pub mod fake {
    //! A stand-in sync server for tests: answers from a list of canned
    //! replies and keeps what each request sent.

    use std::sync::{Arc, Mutex};
    use std::thread;

    #[derive(Debug, Clone)]
    pub struct Seen {
        pub method: String,
        pub url: String,
        pub authorization: String,
        pub body: Vec<u8>,
    }

    pub struct Fake {
        pub url: String,
        pub seen: Arc<Mutex<Vec<Seen>>>,
    }

    /// Serves `reply(method, url)` -> (status, body) until the test ends.
    pub fn serve(reply: impl Fn(&str, &str) -> (u16, Vec<u8>) + Send + 'static) -> Fake {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let url = format!("http://{}", server.server_addr());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        thread::spawn(move || {
            for mut request in server.incoming_requests() {
                let mut body = Vec::new();
                request.as_reader().read_to_end(&mut body).unwrap();
                let authorization = request
                    .headers()
                    .iter()
                    .find(|h| h.field.equiv("authorization"))
                    .map(|h| h.value.to_string())
                    .unwrap_or_default();
                let (method, url) = (request.method().to_string(), request.url().to_string());
                let (status, answer) = reply(&method, &url);
                log.lock().unwrap().push(Seen {
                    method,
                    url,
                    authorization,
                    body,
                });
                request
                    .respond(tiny_http::Response::from_data(answer).with_status_code(status))
                    .unwrap();
            }
        });
        Fake { url, seen }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upload_sends_the_file_compressed_with_who_and_what_was_received() {
        let fake = fake::serve(|_, _| (200, br#"{"version":5,"status":"queued"}"#.to_vec()));
        let client = Client::new(&fake.url, Some("pc-token".into()));
        let answer = client
            .upload(
                "_classic_beta_",
                "Test Realm",
                "Zoë",
                Some("1.9.0"),
                Some(42),
                b"RoadToSixtyCharDB = {}",
            )
            .unwrap();
        assert_eq!(
            answer,
            UploadResponse {
                version: 5,
                status: "queued".into()
            }
        );
        let seen = fake.seen.lock().unwrap()[0].clone();
        assert_eq!(seen.method, "POST");
        assert_eq!(
            seen.url,
            "/v1/upload?game=_classic_beta_&realm=Test%20Realm&name=Zo%C3%AB&addon=1.9.0&received=42"
        );
        assert_eq!(seen.authorization, "Bearer pc-token");
        assert_eq!(zstd::decode_all(&seen.body[..]).unwrap(), b"RoadToSixtyCharDB = {}");
    }

    #[test]
    fn check_reads_every_character_and_a_401_means_unlinked() {
        let fake = fake::serve(|_, _| {
            (200, br#"{"characters":[{"game":"_classic_beta_","realm":"Test Realm","name":"Ann","version":null,"fingerprint":"ab","replace":false,"updateAddon":true}]}"#.to_vec())
        });
        let entry = &Client::new(&fake.url, Some("t".into())).check().unwrap().characters[0];
        assert_eq!((entry.version, entry.update_addon), (None, true));
        let refused = fake::serve(|_, _| (401, br#"{"error":"unknown or unlinked PC"}"#.to_vec()));
        assert_eq!(Client::new(&refused.url, None).check(), Err(ApiError::Unauthorized));
    }

    #[test]
    fn download_unpacks_the_journey() {
        let fake = fake::serve(|_, _| (200, zstd::encode_all(&b"{[\"version\"]=3,}"[..], 3).unwrap()));
        assert_eq!(Client::new(&fake.url, Some("t".into())).download(9).unwrap(), "{[\"version\"]=3,}");
        assert_eq!(fake.seen.lock().unwrap()[0].url, "/v1/versions/9");
    }

    #[test]
    fn no_server_is_a_network_error() {
        let client = Client::new("http://127.0.0.1:9", Some("t".into()));
        assert!(matches!(client.check(), Err(ApiError::Network(_))));
    }

    #[test]
    fn device_polls_read_pending_slow_down_and_the_token() {
        let replies = std::sync::Mutex::new(vec![
            r#"{"access_token":"session-1","token_type":"Bearer"}"#,
            r#"{"error":"slow_down"}"#,
            r#"{"error":"authorization_pending"}"#,
        ]);
        let fake = fake::serve(move |_, _| (400, replies.lock().unwrap().pop().unwrap().as_bytes().to_vec()));
        let client = Client::new(&fake.url, None);
        assert_eq!(client.device_token("dc").unwrap(), DevicePoll::Pending);
        assert_eq!(client.device_token("dc").unwrap(), DevicePoll::SlowDown);
        assert_eq!(client.device_token("dc").unwrap(), DevicePoll::Approved("session-1".into()));
        let body: serde_json::Value = serde_json::from_slice(&fake.seen.lock().unwrap()[0].body).unwrap();
        assert_eq!(body["client_id"], APP_CLIENT_ID);
    }
}
