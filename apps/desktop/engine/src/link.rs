//! Linking this PC (spec, "Linking the app"): the server gives a code, the
//! player signs in with Battle.net on the page the app opens and approves
//! it, and the app trades the sign-in for its own PC token.

use std::time::Duration;

use crate::api::{ApiError, Client, DevicePoll, LinkResponse};

/// Links this PC. `open` shows the player the page to approve on (the app
/// opens their browser); `sleep` waits between polls (tests pass a no-op);
/// `keep_going` turns false when the player has started linking over, so
/// an old attempt stops instead of polling until its code expires.
pub fn link(
    client: &Client,
    pc_name: &str,
    open: impl FnOnce(&str, &str),
    sleep: impl Fn(Duration),
    keep_going: impl Fn() -> bool,
) -> Result<LinkResponse, ApiError> {
    let code = client.device_code(pc_name, platform())?;
    open(&code.verification_uri_complete, &code.user_code);
    let mut interval = code.interval.max(1);
    let polls = code.expires_in / interval + 1;
    for _ in 0..polls {
        sleep(Duration::from_secs(interval));
        if !keep_going() {
            return Err(ApiError::Status(0, "started over".into()));
        }
        match client.device_token(&code.device_code)? {
            DevicePoll::Approved(session) => return client.link(&session, pc_name, platform()),
            DevicePoll::Pending => {}
            DevicePoll::SlowDown => interval += 5,
            DevicePoll::Failed(why) => return Err(ApiError::Status(400, why)),
        }
    }
    Err(ApiError::Status(400, "the code expired before it was approved".into()))
}

pub fn platform() -> &'static str {
    if cfg!(windows) {
        "windows"
    } else if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::fake;
    use std::cell::RefCell;
    use std::sync::Mutex;

    #[test]
    fn opens_the_page_polls_until_approved_then_links() {
        let polls = Mutex::new(vec![r#"{"access_token":"session-1"}"#, r#"{"error":"authorization_pending"}"#]);
        let fake = fake::serve(move |_, url| {
            match url {
            "/api/auth/device/code" => (
                200,
                br#"{"device_code":"dc","user_code":"ABCD1234","verification_uri":"x","verification_uri_complete":"https://api/link?user_code=ABCD1234","interval":5,"expires_in":1800}"#.to_vec(),
            ),
            "/api/auth/device/token" => (400, polls.lock().unwrap().pop().unwrap().as_bytes().to_vec()),
            _ => (200, br#"{"token":"pc-token","pc":"pc-1","battletag":"Ann#1234"}"#.to_vec()),
        }
        });
        let opened = RefCell::new(String::new());
        let waits = RefCell::new(0);
        let linked = link(
            &Client::new(&fake.url, None),
            "Desk",
            |url, code| *opened.borrow_mut() = format!("{url} {code}"),
            |_| *waits.borrow_mut() += 1,
            || true,
        )
        .unwrap();
        assert_eq!(linked.battletag, "Ann#1234");
        assert_eq!(*opened.borrow(), "https://api/link?user_code=ABCD1234 ABCD1234");
        let asked = fake.seen.lock().unwrap().iter().find(|s| s.url == "/api/auth/device/code").unwrap().clone();
        let body: serde_json::Value = serde_json::from_slice(&asked.body).unwrap();
        let scope: serde_json::Value = serde_json::from_str(body["scope"].as_str().unwrap()).unwrap();
        assert_eq!(scope["pc"], "Desk");
        assert_eq!(scope["platform"], platform());
        assert_eq!(*waits.borrow(), 2);
        let last = fake.seen.lock().unwrap().last().unwrap().clone();
        assert!(last.url.starts_with("/v1/link?name=Desk&platform="), "{}", last.url);
        assert_eq!(last.authorization, "Bearer session-1");
    }

    #[test]
    fn a_link_that_was_started_over_stops_polling() {
        let fake = fake::serve(|_, url| match url {
            "/api/auth/device/code" => (
                200,
                br#"{"device_code":"dc","user_code":"U","verification_uri_complete":"x","interval":5,"expires_in":1800}"#.to_vec(),
            ),
            _ => (400, br#"{"error":"authorization_pending"}"#.to_vec()),
        });
        let polls = RefCell::new(0);
        let result = link(
            &Client::new(&fake.url, None),
            "Desk",
            |_, _| {},
            |_| *polls.borrow_mut() += 1,
            || *polls.borrow() < 2,
        );
        assert_eq!(result, Err(ApiError::Status(0, "started over".into())));
        assert_eq!(*polls.borrow(), 2);
    }

    #[test]
    fn a_denied_code_stops() {
        let fake = fake::serve(|_, url| match url {
            "/api/auth/device/code" => (
                200,
                br#"{"device_code":"dc","user_code":"U","verification_uri_complete":"x","interval":5,"expires_in":1800}"#.to_vec(),
            ),
            _ => (400, br#"{"error":"access_denied","error_description":"denied"}"#.to_vec()),
        });
        let result = link(&Client::new(&fake.url, None), "Desk", |_, _| {}, |_| {}, || true);
        assert_eq!(result, Err(ApiError::Status(400, "denied".into())));
    }
}
