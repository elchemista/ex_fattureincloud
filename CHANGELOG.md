# Changelog

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
