# Claude Credential Cache Design

## Goal

Stop Token Usage from asking macOS Keychain for Claude Code's credential on
every usage refresh while preserving correct behavior when Claude rotates or
expires its OAuth token.

## Constraints

- Keep the access token in process memory only. Never write or log it.
- Continue treating Claude Code as the owner of the credential and refresh
  lifecycle. Token Usage remains read-only.
- Preserve the current statusline fallback and user-facing failure states.
- Bound authentication recovery to one Keychain reread and one HTTP retry.
- Keep concurrent refreshes from causing duplicate Keychain reads.

## Considered Approaches

### View-model cache

The view model could retain a token between refreshes. This is simple, but it
puts credential policy in UI state and leaves other API callers unprotected.

### API-client cache

`ClaudeUsageAPI` could cache the token it receives. This keeps the view model
clean, but combines transport and credential lifetime policy and makes the
Keychain reader's fresh-read behavior easy to misuse elsewhere.

### Credential-layer cache

Make `KeychainCredentials` concurrency-safe and let it cache the parsed token
and expiry. This centralizes Keychain access, naturally serializes concurrent
reads, and keeps transport retry logic separate. This is the selected approach.

## Design

`KeychainCredentials` becomes an actor with one optional in-memory credential.
The credential contains the token and its optional expiration date.

`accessToken(now:forceRefresh:)` returns the cached token when it has not
expired. A missing expiry means the token remains cached for the process and is
invalidated by an authentication failure. `forceRefresh` bypasses and replaces
the cache. An expired Keychain value still produces `CredentialError.expired`.

`ClaudeUsageAPI.fetch` obtains a cached token and performs the usage request. If
the server returns `401` or `403`, it forces one credential refresh and retries
the request once. A second authentication rejection returns
`ClaudeUsageAPIError.unauthorized`; no retry loop is possible.

The cache is discarded when the app process exits. Token Usage never mutates
the Keychain item.

## Error Handling

- Missing, malformed, or expired Keychain data retains the existing errors.
- Transport failures, rate limits, and non-authentication HTTP errors are not
  retried by the credential path.
- Authentication recovery performs exactly one forced read and one retry.
- The existing view-model fallback continues to show statusline data or the
  last known reading when live access is unavailable.

## Testing

Credential tests cover:

- repeated access returns the cached token after one underlying read;
- reaching the recorded expiry causes a fresh read;
- forced refresh bypasses a valid cached token;
- a token without an expiry remains cached for the process;
- malformed and expired values preserve their existing errors.

API tests use an injected credential reader and URL protocol to verify:

- successful requests do not force a refresh;
- one authentication failure forces a reread and retries successfully;
- a second authentication failure stops after the single retry;
- other HTTP failures are never retried.
