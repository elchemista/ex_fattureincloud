# ExFattureincloud

SDK Elixir per le API REST v2 di **Fatture in Cloud**, basato su Req. Include 124
operazioni in 17 moduli: le 123 operazioni della specifica ufficiale 2.1.8 e
`get_api_usage`, documentata successivamente dal fornitore. È una libreria
indipendente, non uno SDK ufficiale Fatture in Cloud.

Il trasporto è scritto per Elixir; endpoint e scope sono generati dalla specifica
OpenAPI ufficiale inclusa in `priv/openapi.json`. Autenticazione, filtri e casi di
serializzazione sono confrontati con gli SDK ufficiali Go, JavaScript e TypeScript. Commit,
fonti e test corrispondenti sono elencati in [SDK parity](guides/sdk-parity.md).

## Installazione

Richiede Elixir 1.16 o successivo. La libreria è utilizzabile come dipendenza locale;
il pacchetto non è ancora pubblicato su Hex.

Nel progetto Phoenix o Elixir che la utilizza:

```elixir
defp deps do
  [{:ex_fattureincloud, path: "../ex_fattureincloud"}]
end
```

Esegui `mix deps.get`. Per il token manuale e gli helper OAuth espliciti basta
creare un client; Req gestisce il pool HTTP. Per il rinnovo OAuth automatico puoi
aggiungere il processo opzionale `OAuth.TokenManager` al tuo supervision tree.
Ogni connessione mantiene credenziali proprie.

## Prima chiamata

```elixir
alias ExFattureincloud.{Clients, IssuedDocuments, User}

client = ExFattureincloud.new(token: System.fetch_env!("FIC_ACCESS_TOKEN"))

{:ok, response} = User.list_user_companies(client)
companies = response.data["companies"]

{:ok, response} = Clients.list_clients(client, 12345, per_page: 50, page: 1)
clients = response.data

{:ok, response} = IssuedDocuments.list_issued_documents(
  client, 12345, type: :invoice, per_page: 50, sort: "-date"
)
```

`company_id` è sempre esplicito. Tutti i moduli seguono la stessa convenzione:
`client`, parametri del percorso, body se previsto, opzioni query facoltative.
Anche un body facoltativo è un argomento esplicito: usa `nil` per ometterlo.
Le opzioni query accettano keyword list o mappe, con chiavi stringa o atom.

## Limiti del piano e fatture disponibili

I limiti vengono letti dall'azienda, senza tabelle commerciali hardcoded:

```elixir
alias ExFattureincloud.Usage

{:ok, quota} = Usage.documents(client, 12345)
quota.limit      # es. 3000, valore restituito dal piano
quota.used       # es. 100
quota.remaining  # es. 2900
quota.period     # :annual

{:ok, available?} = Usage.can_create_documents?(client, 12345, 10)
# true / false / :unknown

{:ok, capacity} = Usage.invoice_capacity(client, 12345, 10)
capacity.can_create                # combina quota, scadenza e permessi aziendali
capacity.e_invoice_enabled         # funzione fatturazione elettronica del piano
capacity.license_expire
capacity.documents.remaining

{:ok, clients_quota} = Usage.plan(client, 12345, :clients)
{:ok, api_usage} = Usage.api(client, 12345)
api_usage.data["hourly"]["remaining"]
api_usage.data["monthly"]["remaining"]
```

Il limite `documents` è **annuale** e riguarda il contatore documenti del piano,
non esclusivamente fatture inviate allo SDI; clienti, fornitori e prodotti hanno
contatori globali. `invoice_capacity/3` esegue due GET. Un dato nullo o assente
produce `:unknown`, senza assumere un piano illimitato. La verifica è una fotografia
del momento, non riserva disponibilità. L'invio di una fattura già esistente è
un'operazione diversa; esito SDI, scope OAuth e validità fiscale del documento
rimangono da verificare. La scadenza della licenza viene confrontata con la data UTC.

Per il monitoraggio ordinario usa `response.rate_limit`: leggerlo non consuma
richieste aggiuntive. `Usage.api/2` consuma quota e il suo consumo è già compreso
nel contatore restituito. Fonti: [piano e documenti](https://developers.fattureincloud.it/docs/guides/plan-management/),
[quote API](https://developers.fattureincloud.it/docs/basics/limits-and-quotas/).

## Risposte ed errori

```elixir
case Clients.get_client(client, 12345, 67890) do
  {:ok, response} ->
    response.data        # risorsa; chiavi JSON stringa
    response.body        # envelope completo, inclusi extra/warnings
    response.pagination  # current_page, last_page, total, ecc.
    response.rate_limit  # quote orarie/mensili e Retry-After

  {:error, error} ->
    error.kind           # :http, :transport, :validation, :authentication, :protocol
    error.status         # es. 422; nil per errori locali/di rete
    error.code           # codice API oppure errore OAuth
    error.message
    error.body           # risposta completa: validation_result, extra, ecc.
    error.retry_after    # secondi, anche da una data HTTP
end
```

Le risposte vuote sono valide. L'XML viene restituito come stringa. Non vengono
creati atom da input o risposte HTTP. Date, valori nulli, stringhe vuote, zero e
booleani restano distinti. Non si applicano conversioni automatiche agli importi:
i numeri JSON decimali sono float Elixir; i calcoli fiscali e gli arrotondamenti
non appartengono al trasporto. Per i totali usa gli endpoint ufficiali
`get_new_issued_document_totals` / `get_existing_issued_document_totals`.

I body sono mappe con la struttura ufficiale, **incluso l'envelope**:

```elixir
{:ok, created} = Clients.create_client(client, 12345, %{
  data: %{name: "Rossi S.r.l.", type: "company", country: "Italia"}
})
```

Vengono validati percorso, query obbligatorie, enum e limiti numerici. Le regole
fiscali e i campi annidati dei body sono validati dal servizio. Le risposte
mantengono anche campi nuovi, senza scartarli per adattarli a modelli datati.

## Retry e configurazione

```elixir
client = ExFattureincloud.new(
  token: fn -> MyApp.TokenStore.current_access_token() end,
  max_retries: 2,
  retry_delay: 500,
  max_retry_delay: 30_000,
  receive_timeout: 15_000,
  req_options: [connect_options: [timeout: 5_000]]
)
```

Le sole richieste GET/HEAD possono essere ripetute automaticamente per errori di
rete, HTTP 408/429/500/502/503/504 e HTTP 403 con `Retry-After`.
Le risposte rispettano `Retry-After`, sia in secondi sia come data HTTP.
Se l'attesa supera il budget, l'errore viene restituito senza anticipare il retry.
Le altre risposte temporanee usano backoff esponenziale con jitter.
`max_retries: 0` disattiva i retry.

**Il trasporto non ripete mai POST, PUT, PATCH e DELETE**, inclusi upload, invio
SDI e singole chiamate di refresh OAuth. Il gestore OAuth opzionale pianifica un
nuovo tentativo solo per un rifiuto esplicito con `Retry-After`; gli esiti incerti
richiedono riconciliazione. I redirect sono disabilitati.
Non esiste un contatore globale locale: tutte le applicazioni che lavorano sulla
stessa azienda possono consumarne le quote.

Come richiesto per questa integrazione, lo `User-Agent` predefinito è identico
a quello dello SDK Go ufficiale: `FattureInCloud/2.1.3/Go-SDK`.
È configurabile con `user_agent: "NomeApplicazione/1.0"`.
`Accept` deriva dal contratto: `application/json` oppure `text/xml` per l'XML.

## Filtri e paginazione

```elixir
alias ExFattureincloud.{Filter, Pagination}

q = Filter.where("name", :contains, "Rossi")
    |> Filter.and_where("vat_number", :is_not, nil)
    |> Filter.build()

{:ok, response} = Clients.list_clients(client, 12345, q: q)

Pagination.stream!(client, :list_issued_documents,
  path: [company_id: 12345],
  query: [type: :invoice, per_page: 100, sort: "id"]
)
|> Enum.take(150)
```

La paginazione è lazy. `stream!/3` restituisce elementi e solleva un errore in caso
di fallimento; `stream/3` emette `{:ok, item}` e, al primo errore, un singolo
`{:error, error}` prima di fermarsi. I link di pagina ricevuti non vengono seguiti
verso altri host. Imposta un ordinamento stabile se il dataset può cambiare.
I filtri vanno passati non codificati; Req applica l'encoding URL una sola volta.
Gli apostrofi/backslash nei literal vengono rifiutati perché la documentazione
non ne definisce un escaping. Resta disponibile il parametro `q` scritto a mano.

## Allegati

```elixir
alias ExFattureincloud.IssuedDocuments

fields = [
  filename: "allegato.pdf",
  attachment: {File.stream!("/percorso/allegato.pdf"),
               filename: "allegato.pdf", content_type: "application/pdf"}
]

{:ok, upload} = IssuedDocuments.upload_issued_document_attachment(client, 12345, fields)
```

Il contenuto viene inviato in multipart con boundary e dimensione gestiti da Req.
L'upload restituisce un token: l'associazione al documento avviene in una chiamata
separata, come negli SDK ufficiali. La libreria non legge l'intero file in memoria.

## OAuth e webhook

Sono disponibili authorization code, refresh token e Device Code Flow. Vedi
[autenticazione](guides/authentication.md) per esempi completi e gestione dello state.
Gli helper OAuth espliciti lasciano rinnovo e salvataggio all'applicazione.
Per coordinarli automaticamente puoi usare `ExFattureincloud.OAuth.TokenManager`:

```elixir
alias ExFattureincloud.OAuth.TokenManager

# Nel supervision tree, dopo aver salvato il token ottenuto dal callback OAuth:
children = [
  {TokenManager,
   name: MyApp.FicTokenManager,
   client_id: System.fetch_env!("FIC_CLIENT_ID"),
   client_secret: System.fetch_env!("FIC_CLIENT_SECRET"),
   load: fn -> MyApp.FicCredentials.load_token(connection_id) end,
   save: fn token -> MyApp.FicCredentials.save_token(connection_id, token) end}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
client = TokenManager.client(MyApp.FicTokenManager)
```

`load` e `save` sono callback obbligatori dell'applicazione: il primo restituisce
`{:ok, %OAuth.Token{}}`, il secondo salva atomicamente access token, refresh token
e scadenza e restituisce `:ok` solo dopo il salvataggio. Entrambi possono restituire
`{:error, reason}`. Il gestore usa un timer per rinnovare prima della scadenza;
con `automatic: false` rinnova solo quando una richiesta ne ha bisogno.
Il lavoro HTTP e il salvataggio avvengono in un `Task`, mentre il `GenServer`
coordina le richieste concorrenti per eseguire un solo rinnovo per connessione.
`TokenManager.client/1` riutilizza anche la configurazione HTTP del gestore.

Un salvataggio fallito conserva il nuovo token in memoria e riprova solo il
salvataggio. Errori di rete, server o risposte non valide sospendono il rinnovo;
`invalid_grant` richiede una nuova autorizzazione. `status/1` espone lo stato senza
credenziali e `reload/1` ricarica un token riconciliato nell'archivio, rifiutando di
scartare un rinnovo in corso o un token ancora da salvare. Il gestore non può
recuperare un token ruotato perso in un crash prima del salvataggio. Usa un solo
gestore per connessione OAuth, anche se comprende più aziende; su più nodi serve
un proprietario unico o un coordinamento distribuito dell'applicazione.

Per le subscription usa `ExFattureincloud.Webhooks`; per autenticare le notifiche
usa `ExFattureincloud.Webhook`:

```elixir
{:ok, event} = ExFattureincloud.Webhook.verify_event(headers, decoded_json_body,
  audience: "https://example.com/webhooks/fic", application_id: 123
)
```

La verifica usa JWT ES256, chiave pubblica del fornitore, issuer, audience, app ID,
scadenza e corrispondenza di event ID/subject. Supporta CloudEvents binary e
structured. Per una rotazione puoi passare `public_key: trusted_pem`.
Per il GET di verifica autentica prima il JWT con `Webhook.verify/2`, poi restituisci
`Webhook.verification_response(challenge)` con HTTP 200. Il challenge è in header
o query secondo la subscription. Deduplicazione e persistenza degli eventi
restano nell'applicazione; la consegna può ripetersi o arrivare fuori ordine.

## Osservabilità

Eventi Telemetry: `[:ex_fattureincloud, :request, :start | :stop | :retry]`.
`start` include `system_time`, `stop` include `duration` in unità native,
`retry` include `delay` in millisecondi. I metadata comprendono operazione,
metodo, tentativo da zero, stato ed esito dove disponibili; non contengono URL,
token, parametri, body o ID aziendali. Gli eventi sono per singolo tentativo.
Client, errori e token OAuth escludono i dati sensibili da `Inspect`.
Le risposte HTTP complete possono contenere dati personali: gestiscile nel tuo logger.

## Catalogo e manutenzione

- [Tutte le funzioni disponibili](guides/endpoints.md)
- [Confronto con Go, JavaScript e TypeScript](guides/sdk-parity.md)
- [Sviluppo, generazione e verifiche](guides/development.md)
- [Specifiche ufficiali](https://github.com/fattureincloud/openapi-fattureincloud)
- [Documentazione API ufficiale](https://developers.fattureincloud.it/)

Gli endpoint nuovi possono essere raggiunti con `ExFattureincloud.request/4` usando
un percorso relativo e le opzioni `query`, `body`, `multipart`, `accept`.
La copertura è verificata offline sul contratto incluso. L'esecuzione con un
account reale richiede token, scope e piano adeguati; non è stata effettuata su
un'azienda reale durante lo sviluppo.

Per sviluppare la libreria usa `mix check` per compilazione e test in ambiente
`test`, e `mix quality` per compilazione, Credo strict e Dialyzer in ambiente `dev`.
Credo e Dialyxir sono dipendenze **solo `:dev`**; Req.Test, Plug e OpenApiSpex
servono ai test, senza aggiungere validatori OpenAPI al client di produzione.

I test contrattuali attraversano Req e validano richieste e risposte simulate per
tutte le 124 operazioni, leggendo gli schemi JSON versionati indipendentemente dal
catalogo generato dell'SDK. Il controllo dei tipi JSON impedisce che un cast da
stringa a numero nasconda errori di serializzazione. Le 26 incoerenze note degli
esempi ufficiali sono registrate in una baseline legata agli hash delle sorgenti;
gli schemi originali restano invariati. Puoi eseguire soltanto questi controlli con:

```sh
mix test --only contract --warnings-as-errors
```

La CI esegue test e coverage minima del **90%** su **Elixir 1.19/OTP 28** e
**Elixir 1.20/OTP 29**, con job separati di Credo strict e Dialyzer per entrambe le
combinazioni. Elixir 1.16/OTP 26 conserva un controllo di compatibilità sui test.
Sono inclusi rigenerazione del contratto, documentazione senza warning, build del
pacchetto e avvio isolato in produzione, senza credenziali o chiamate al servizio.
Cache, artifact, permessi e dettagli dei controlli sono descritti nella
[guida di sviluppo](guides/development.md).

## Licenza

MIT. Le specifiche e i riferimenti agli SDK mantengono i rispettivi crediti in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

