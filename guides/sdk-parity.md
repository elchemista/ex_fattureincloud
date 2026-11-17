# Riferimenti agli SDK ufficiali e casi verificati

I sorgenti degli SDK ufficiali sono stati letti direttamente, insieme alla
specifica OpenAPI e alle guide. Questo SDK usa Req ed Elixir; non esegue Go,
JavaScript o un servizio intermedio.

Riferimenti fissati durante l'implementazione:

- OpenAPI: [`362e3fe`](https://github.com/fattureincloud/openapi-fattureincloud/tree/362e3fe524ca5a8cd8b79efdf036c464c16c5c42).
- Go SDK: [`e424718`](https://github.com/fattureincloud/fattureincloud-go-sdk/tree/e424718947f265f90bd6e24375f4b2edfc85e65e).
- TypeScript SDK: [`339771d`](https://github.com/fattureincloud/fattureincloud-ts-sdk/tree/339771d28d0d28fef93149e7dab81552bd2a98b3).

| Comportamento verificato | Riferimento ufficiale | Test Elixir |
| --- | --- | --- |
| User-Agent Go esatto, configurabile | Go `api/configuration.go` | `transport_test.exs` |
| Bearer e parametri codificati nel percorso | Go `api/client.go`, TS `src/api/*` | `transport_test.exs`, `contract_test.exs` |
| Code/refresh con JSON, secret solo per flow server | Go `oauth2/oauth2_authorization_code.go`, TS `src/oauth2/oauth2-authorization-code-manager.ts` | `oauth_test.exs` |
| Device code dentro `data`, refresh senza secret | Go `oauth2/oauth2_device_code.go`, TS `src/oauth2/oauth2-device-code-manager.ts` | `oauth_test.exs` |
| Risposta OAuth diretta ed errori `error_description` | Go `oauth2/oauth2.go`, TS OAuth manager, guide ufficiali | `oauth_test.exs` |
| XML mantenuto come stringa | Go `api/client.go`, TS `test/api/IssuedEInvoicesApi.spec.ts` | `transport_test.exs` |
| Distinzione null, false, zero, date e decimali | Go `model/*`, TS `test/api/IssuedDocumentsApi.spec.ts` | `transport_test.exs`, `sdk_parity_test.exs` |
| Campi multipart `filename` e `attachment` separati | TS `src/api/issued-documents-api.ts`, Go API allegati | `contract_test.exs`, `sdk_parity_test.exs` |
| Filtri nulli, booleani, numerici, stringhe e AND/OR annidati | Go `filter/*` e `test/filter/*`, TS `src/filter/*` e `test/filter/*` | `filter_test.exs` |
| Envelope di paginazione completo | TS `test/api/ClientsApi.spec.ts`, OpenAPI | `pagination_test.exs`, `sdk_parity_test.exs` |
| Dettagli di errore completi incluse validazioni SDI | Go `GenericOpenAPIError`, OpenAPI | `transport_test.exs`, `sdk_parity_test.exs` |

## Gestione aggiuntiva e differenze intenzionali

Il confronto con uno SDK non dimostra che ogni caso possibile sia coperto.
Le suite ufficiali contengono anche test che fanno stub del metodo stesso:
qui il contratto verifica invece la richiesta che attraversa davvero Req.

Gli helper aggiungono confronto constant-time dello state, errori strutturati,
backoff limitato su sole letture, quote del piano interrogate dal server e stream
lazy che propagano gli errori. La verifica webhook segue la [documentazione JWT
ufficiale](https://developers.fattureincloud.it/docs/webhooks/notifications/),
non una firma HMAC inventata.

I filtri seguono la grammatica e i casi ufficiali ma rifiutano stringhe con quote
o backslash senza un escaping documentato; non riproducono interpolazioni ambigue.
Gli upload usano File.Stream di Req e vengono verificati sui byte trasmessi.
I body e le risposte restano mappe: non viene copiata la grande gerarchia di classi
generate degli altri linguaggi e non vengono ignorati campi futuri.

Fonti supplementari: [paginazione](https://developers.fattureincloud.it/docs/basics/paginate-results/),
[filtri](https://developers.fattureincloud.it/docs/basics/filter-results/queries/),
[quote API](https://developers.fattureincloud.it/docs/basics/limits-and-quotas/),
[limiti piano](https://developers.fattureincloud.it/docs/guides/plan-management/).
