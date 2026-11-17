# Riferimenti agli SDK ufficiali e casi verificati

I sorgenti degli SDK ufficiali sono stati letti direttamente, insieme alla
specifica OpenAPI e alle guide. Questo SDK usa Req ed Elixir; non esegue Go,
JavaScript o un servizio intermedio.

Riferimenti fissati durante l'implementazione:

- OpenAPI: [`362e3fe`](https://github.com/fattureincloud/openapi-fattureincloud/tree/362e3fe524ca5a8cd8b79efdf036c464c16c5c42).
- Go SDK: [`e424718`](https://github.com/fattureincloud/fattureincloud-go-sdk/tree/e424718947f265f90bd6e24375f4b2edfc85e65e).
- TypeScript SDK: [`339771d`](https://github.com/fattureincloud/fattureincloud-ts-sdk/tree/339771d28d0d28fef93149e7dab81552bd2a98b3).
- JavaScript SDK: [`439192a`](https://github.com/fattureincloud/fattureincloud-js-sdk/tree/439192ae97720105aa2fcff603a2a2f81191dad0).

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

## Esempi incoerenti: verifica del comportamento reale degli SDK

L'audit del contratto identifica 26 esempi JSON che contraddicono il relativo
schema: 17 risposte e 9 richieste. Sono stati provati anche con il codice degli
SDK ufficiali ai commit sopra indicati. Il report
[`official_sdk_behavior.json`](https://github.com/elchemista/ex_fattureincloud/blob/main/test/fixtures/official_sdk_behavior.json)
registra, per ogni esempio, il puntatore JSON originale, l'operazione, gli esiti,
gli errori e i percorsi dei campi modificati. Non include risposte HTTP reali o
credenziali. Il contratto vendorizzato non è stato corretto per far passare i test.

I tre esperimenti verificano punti diversi del codice:

- **Go:** deserializzazione di tutti i 26 esempi nel rispettivo modello generato
  con `json.Unmarshal`, seguita dalla serializzazione dei modelli accettati.
  È il decoder usato anche da [`APIClient.decode`](https://github.com/fattureincloud/fattureincloud-go-sdk/blob/e424718947f265f90bd6e24375f4b2edfc85e65e/api/client.go#L534-L545).
  8 esempi sono accettati e 18 rifiutati. La prova riguarda i modelli: non simula
  l'accettazione di una richiesta da parte del servizio.
- **JavaScript:** passaggio di tutti i 26 esempi attraverso
  [`ApiClient.deserialize`](https://github.com/fattureincloud/fattureincloud-js-sdk/blob/439192ae97720105aa2fcff603a2a2f81191dad0/src/ApiClient.js#L352-L365)
  e i modelli generati, poi serializzazione JSON. 24 costruzioni del modello
  riescono e 2 falliscono. Separatamente, le 9 richieste originali sono state
  inviate come oggetti raw tramite `ApiClient.callApi` a un server HTTP locale:
  il JSON trasmesso è rimasto identico in tutti i casi. Costruire un modello e
  trasmettere un body raw non hanno gli stessi effetti.
- **TypeScript:** invocazione delle classi API e dei metodi generati con un adapter
  Axios locale, conservando le trasformazioni standard Axios. Tutte le 17 risposte
  e tutte le 9 richieste mantengono il JSON originale. Le interfacce TypeScript
  descrivono i tipi durante la compilazione; il
  [trasporto generato](https://github.com/fattureincloud/fattureincloud-ts-sdk/blob/339771d28d0d28fef93149e7dab81552bd2a98b3/common.ts#L109-L126)
  non applica quella validazione alle risposte ricevute o ai valori JavaScript
  non tipizzati.

| Famiglia di esempi e operazioni | Go | Modelli JavaScript | Trasporto TypeScript |
| --- | --- | --- | --- |
| `createCashbookEntry`, risposta con `id` numerico | Rifiuta: attende stringa | Converte l'ID in stringa e la data in `Date` | Preserva il JSON |
| VAT `ei_type` numerico: create/modify/get, `getClientInfo`, `getTaxProfile` | Rifiuta: attende stringa | Converte in stringa | Preserva il JSON |
| `listVatTypes`, `e_invoice` stringa | Rifiuta: attende booleano | `Boolean("string")` produce `true` | Preserva il JSON |
| `getEInvoiceRejectionReason`, data senza orario | Rifiuta: attende RFC3339 | Converte in `Date` | Preserva la stringa originale |
| `getIssuedDocumentPreCreateInfo`, numerazione `null` | Accetta ma converte il valore in `0` nel roundtrip | Accetta; può omettere altri campi non modellati | Preserva `null` e gli altri campi |
| `getReceiptPreCreateInfo`, numerazioni annidate | Rifiuta gli oggetti dove attende interi | Accetta: il modello usa valori `Object` | Preserva il JSON |
| `listClients`, metodo di pagamento `null` | Accetta come puntatore nil e omette il campo nel roundtrip | Omette il campo nel roundtrip del modello | Preserva il campo e `null` |
| `listF24`, totale numerico rappresentato come stringa | Rifiuta: attende numero | Converte con `parseFloat` | Preserva la stringa |
| `listPendingReceivedDocuments`, tipo `expense` | Rifiuta il valore non previsto dall'enum | Accetta il valore; il modello può omettere altri campi | Preserva il JSON |
| `listUserCompanies`, partita IVA numerica | Rifiuta: attende stringa | Converte in stringa | Preserva il numero ricevuto |
| Subscription create/list/modify: vecchi eventi e `warnings` stringa | Rifiuta gli enum; rifiuta anche la stringa dove attende `[]string` | Non valida gli enum, ma le due risposte con `warnings` stringa falliscono durante `data.map` | Preserva il JSON |
| Richieste cashbook create/modify, issued create, received totals, F24 create/modify: campi `required` mancanti | I modelli hanno campi opzionali e li serializzano omettendoli | Costruzione del modello accettata; alcune date diventano `Date` | Trasmette il JSON originale |

Le conversioni JavaScript derivano da
[`ApiClient.convertToType`](https://github.com/fattureincloud/fattureincloud-js-sdk/blob/439192ae97720105aa2fcff603a2a2f81191dad0/src/ApiClient.js#L527-L555),
non da correzioni dedicate a questi esempi. Per le numerazioni dei corrispettivi
il modello usa esplicitamente
[`{ String: Object }`](https://github.com/fattureincloud/fattureincloud-js-sdk/blob/439192ae97720105aa2fcff603a2a2f81191dad0/src/model/ReceiptPreCreateInfo.js#L47-L52).
In Go le mancanze obbligatorie dell'OpenAPI enriched non diventano automaticamente
controlli nel modello: per esempio il
[`CashbookEntry` generato](https://github.com/fattureincloud/fattureincloud-go-sdk/blob/e424718947f265f90bd6e24375f4b2edfc85e65e/model/model_cashbook_entry.go#L22-L48)
ha campi opzionali e un costruttore senza argomenti.

Per il trasporto Elixir è stata scelta la conservazione del JSON osservata in
TypeScript: nessuna conversione implicita di identificativi, importi, booleani o
date e nessuna perdita di campi nuovi. Questa scelta non dimostra che TypeScript
sia lo SDK più affidabile in produzione, né che il backend accetti gli esempi
incoerenti. I mock OpenAPI continuano a rifiutarli; test separati verificano che il
trasporto sappia conservarli senza indebolire la validazione del contratto.

## Segnalazioni ufficiali e regressioni di trasporto

Sono state lette anche issue, pull request e review dei repository ufficiali.
Un'issue chiusa non equivale necessariamente a una correzione dello SDK: sotto
sono distinte le conferme del maintainer, le PR effettivamente integrate e le
segnalazioni ancora aperte. Il numero di issue non costituisce una misura
comparabile dell'affidabilità dei diversi SDK.

| Segnalazione | Evidenza primaria | Comportamento Elixir verificato |
| --- | --- | --- |
| [TS #19, invio e-invoice con body vuoto](https://github.com/fattureincloud/fattureincloud-ts-sdk/issues/19), chiusa il 5 dicembre 2022 | Il [maintainer](https://github.com/fattureincloud/fattureincloud-ts-sdk/issues/19#issuecomment-1309912137) conferma una variazione della validazione JSON del servizio e il ripristino del comportamento. Il problema riguarda la distinzione fra body omesso e `{}`. | I test mantengono distinti `nil`, `%{}` e `%{data: %{}}`: rispettivamente body omesso, oggetto vuoto ed envelope con `data` vuoto. Nessun retry automatico dell'invio allo SDI. |
| [TS #14, nomi dei campi OAuth](https://github.com/fattureincloud/fattureincloud-ts-sdk/issues/14), chiusa il 22 settembre 2022 | Il [commento del maintainer](https://github.com/fattureincloud/fattureincloud-ts-sdk/issues/14#issuecomment-1255134615) conferma la correzione rilasciata per la discrepanza fra nomi camelCase nei tipi e snake_case effettivo. | Gli helper leggono `access_token`, `refresh_token` ed `expires_in` dal JSON e restituiscono `OAuth.Token`; code exchange e refresh sono testati sui dati ricevuti da Req. |
| [TS PR #46, Device Code Flow](https://github.com/fattureincloud/fattureincloud-ts-sdk/pull/46), integrata il 17 giugno 2024 | PR con review approvata: aggiunge il device-code manager e corregge l'accesso all'envelope `data` della risposta. | `OAuth.device_code/2` è testato sia sulla risposta dentro `data` sia sulla forma diretta mostrata nelle guide; ogni poll del token rimane esplicito. |
| [JS #80, refresh con proprietà `undefined`](https://github.com/fattureincloud/fattureincloud-js-sdk/issues/80), chiusa il 7 marzo 2024 | La correzione è nella [PR #82](https://github.com/fattureincloud/fattureincloud-js-sdk/pull/82), approvata e integrata il 19 febbraio 2024: attende la Promise prima di costruire il risultato. La PR #81 omonima non è stata integrata. | Il chiamante riceve il risultato del refresh solo dopo la risposta HTTP; il gestore opzionale pubblica i nuovi token solo dopo il salvataggio riuscito. I test includono rinnovi concorrenti e persistenza fallita. |
| Campi nuovi: [TS #55, `Supplier.ei_code`](https://github.com/fattureincloud/fattureincloud-ts-sdk/issues/55) e [JS #114, `merged_in`](https://github.com/fattureincloud/fattureincloud-js-sdk/issues/114), aperte all'ispezione del 17 novembre 2026 | Le segnalazioni dell'11 agosto 2025 e del 9 settembre 2026 non hanno una soluzione del maintainer. Nel sorgente JS esaminato `IssuedDocument.constructFromObject` copia i campi noti e non include `merged_in`. | Le risposte restano mappe: i test conservano `ei_code` e campi futuri nelle risposte e nei body inviati, senza attendere l'aggiornamento di classi generate. |
| [Go PR #46, helper OAuth e test](https://github.com/fattureincloud/fattureincloud-go-sdk/pull/46), integrata il 17 ottobre 2025 | Refactor OAuth con review approvata e test `httptest` per gli esiti positivi di fetch, refresh e device code. È un miglioramento verificabile, non prova di copertura di ogni errore. | I test Elixir attraversano il trasporto Req e coprono risultati positivi, errori OAuth, scadenza, refresh concorrenti, errori di salvataggio ed esiti incerti. |

Queste verifiche sostengono la scelta di un trasporto che conservi i valori
ricevuti e distingua gli input forniti dal chiamante. Non sostituiscono una prova
con un account reale, e non giustificano normalizzazioni implicite dei body o
conclusioni generali sulla disponibilità del servizio.

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
