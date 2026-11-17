# Changelog

## Unreleased

- Optional supervised OAuth TokenManager with asynchronous Task workers, shared
  refresh results for concurrent callers and scheduled or on-demand renewal.
- Required credential load/save callbacks, persistence-before-use, pending-save
  recovery and explicit reconciliation of uncertain refresh outcomes.
- Documented, typed public APIs refactored around function-head matching,
  pipelines and lazy streams.
- Credo strict and Dialyzer checks through `mix quality`, with both dependencies
  restricted to development and separate CI matrices for Elixir 1.19/OTP 28 and
  Elixir 1.20/OTP 29.
- Full test coverage gates on both modern runtime combinations, retained
  Elixir 1.16/OTP 26 compatibility, reproducible generation and cached PLTs.
- Independent OpenAPI HTTP mocks with test-only OpenApiSpex, schema-generated
  requests and responses for all 124 operations, and JSON wire-type checks.
- SHA-bound baseline of 26 upstream JSON media-example inconsistencies,
  preserving the original validation schemas and contract source files.
- Transport regressions for all 26 inconsistent examples, with measured
  Go/JavaScript/TypeScript behavior and upstream issue/fix references.
- Regressions for omitted versus empty e-invoice bodies, OAuth response field
  names and supplier fields absent from generated upstream models.
- Documentation/package artifacts, Hex dependency auditing and an
  isolated production package smoke test without provider API calls.

## 0.1.0

- 124 API operations in 17 resource modules, generated from pinned OpenAPI 2.1.8
  plus the subsequently documented Get API Usage endpoint.
- Req transport with safe-read retries, structured errors, quota headers,
  configurable Go SDK compatibility User-Agent and endpoint-specific Accept.
- OAuth authorization code, refresh and device-code helpers; official scopes.
- Lazy pagination, composable filters, streamed multipart uploads and raw XML.
- Live plan/document capacity checks and API usage inspection.
- Webhook ES256 JWT and CloudEvents verification.
- Offline contract and behavior tests, documentation and CI.
