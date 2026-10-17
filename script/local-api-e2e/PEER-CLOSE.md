# Local API peer closure verification

Run on macOS with the repository's selected Xcode toolchain:

```sh
python3 script/local-api-e2e/verify-peer-close.py --output /tmp/local-api-peer-close
```

The driver compiles the production local API sources and calls `LocalAPIClient`
against fresh same-user Unix socket endpoints. It checks EOF before the response,
a partial header, a partial body, a complete response, and explicit cancellation.
The output directory retains the executable and `report.json`; the fixture removes
only the sockets and empty directories it created. It uses no credentials, grants,
Keychain access, running app, or user profile data.

This proves client framing and error classification. Native Settings, real agent
behavior, authorization, accessibility, and the full preflight are separate checks.
