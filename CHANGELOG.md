# Changelog

## Unreleased

- Optional supervised OAuth TokenManager with asynchronous Task workers, shared
  refresh results for concurrent callers and scheduled or on-demand renewal.
- Required credential load/save callbacks, persistence-before-use, pending-save
  recovery and explicit reconciliation of uncertain refresh outcomes.
- Credo strict and Dialyzer checks through `mix quality`, using development-only
  dependencies and a dedicated CI job.

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
