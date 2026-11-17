# Autenticazione

## Token manuale

```elixir
client = ExFattureincloud.new(token: System.fetch_env!("FIC_ACCESS_TOKEN"))
```

Il token deve appartenere all'azienda scelta e includere gli scope necessari.
La libreria non cerca variabili d'ambiente implicitamente e non memorizza token
nella configurazione globale di un'applicazione multiutente.
Il token manuale continua a usare questo percorso semplice, senza gestore di
rinnovo, callback di persistenza o processi aggiuntivi.

## Authorization Code Flow

```elixir
alias ExFattureincloud.OAuth

client = ExFattureincloud.new()
state = OAuth.generate_state()
# Salva state nella sessione server dell'utente prima del redirect.

url = OAuth.authorization_url(client,
  client_id: System.fetch_env!("FIC_CLIENT_ID"),
  redirect_uri: "https://example.com/oauth/fic/callback",
  scope: ["entity.clients:r", "issued_documents.invoices:a"],
  state: state
)

# Nel callback, dopo aver letto code/state dai query params:
:ok = OAuth.validate_state(saved_session_state, callback_state)
# Consuma lo state dalla sessione affinché non sia riutilizzabile.

{:ok, token} = OAuth.exchange_code(client,
  client_id: System.fetch_env!("FIC_CLIENT_ID"),
  client_secret: System.fetch_env!("FIC_CLIENT_SECRET"),
  redirect_uri: "https://example.com/oauth/fic/callback",
  code: callback_code
)

authenticated_client = ExFattureincloud.new(token: token.access_token)
```

Il redirect URI deve coincidere esattamente con quello registrato. Lo scope è
una stringa separata da spazi oppure una lista di stringhe. `Scopes.all/0` espone
i valori ufficiali; scope futuri possono essere inviati senza modificare l'SDK.

## Refresh esplicito

```elixir
if OAuth.Token.expired?(saved_token) do
  {:ok, new_token} = OAuth.refresh_token(client,
    client_id: System.fetch_env!("FIC_CLIENT_ID"),
    client_secret: System.fetch_env!("FIC_CLIENT_SECRET"),
    refresh_token: saved_token.refresh_token
  )
  # Salva atomicamente entrambi i nuovi token e la scadenza.
end
```

`expired?/2` applica un margine predefinito di 60 secondi. Serializza i refresh per
connessione nella tua applicazione, così richieste concorrenti non usano lo stesso
refresh token contemporaneamente. Questi helper non avviano cicli in background.
Una funzione `token: fn -> ... end` permette di leggere il token corrente da un
archivio gestito dall'applicazione.

## Rinnovo gestito con OTP

`ExFattureincloud.OAuth.TokenManager` è un processo supervisionabile opzionale per
una singola connessione OAuth. Prima di avviarlo, salva il token iniziale ottenuto
con `exchange_code/2` o `device_token/2` nell'archivio della tua applicazione:

```elixir
:ok = MyApp.FicCredentials.save_token(connection_id, token)
```

Il contratto di persistenza è esplicito:

- `load_token(connection_id)` restituisce `{:ok, %ExFattureincloud.OAuth.Token{}}`
  oppure `{:error, reason}`. Deve ricostruire anche il refresh token e `expires_at`
  come Unix timestamp in secondi, non solo l'access token.
- `save_token(connection_id, token)` salva access token, refresh token e scadenza
  nella stessa transazione e restituisce `:ok` dopo il commit, oppure
  `{:error, reason}`. Un ritorno `{:ok, record}` del tuo database va convertito in
  `:ok` dal callback; la libreria non dipende da Ecto o da uno specifico database.

Aggiungi poi il gestore ai figli del tuo supervisor:

```elixir
alias ExFattureincloud.OAuth.TokenManager

oauth_client = ExFattureincloud.new(
  req_options: [connect_options: [timeout: 5_000]]
)

children = [
  {TokenManager,
   id: {:fic_oauth, connection_id},
   name: MyApp.FicTokenManager,
   client: oauth_client,
   client_id: System.fetch_env!("FIC_CLIENT_ID"),
   client_secret: System.fetch_env!("FIC_CLIENT_SECRET"),
   load: fn -> MyApp.FicCredentials.load_token(connection_id) end,
   save: fn updated_token ->
     MyApp.FicCredentials.save_token(connection_id, updated_token)
   end,
   refresh_margin: 60,
   retry_interval: 30_000}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

client = TokenManager.client(MyApp.FicTokenManager)
{:ok, companies} = ExFattureincloud.User.list_user_companies(client)
```

Questo esempio usa il nome fisso `MyApp.FicTokenManager` per una connessione. Per
più connessioni usa nomi distinti, ad esempio tramite `Registry`, senza creare atom
dai loro ID. Per Device Code Flow ometti `client_secret`.

Il gestore carica le credenziali tramite `load` a ogni avvio. Per impostazione
predefinita pianifica il rinnovo con un timer prima della scadenza; il margine è
limitato a metà della durata dichiarata del token per evitare rinnovi continui con
token molto brevi. Con `automatic: false` non viene avviato il timer: la prima
richiesta che richiede un token vicino alla scadenza avvia il rinnovo.

HTTP e persistenza vengono eseguiti in un `Task`. Il `GenServer` continua a
rispondere alle richieste di stato, raccoglie i chiamanti concorrenti e condivide
un solo risultato di rinnovo. I nuovi token vengono usati dal client solo dopo
che `save` ha restituito `:ok`. `TokenManager.client/1` conserva `base_url`, timeout,
User-Agent e opzioni Req del client passato al gestore, aggiungendo il provider
del token corrente.

```elixir
TokenManager.status(MyApp.FicTokenManager)
# %{status: :ready, expires_at: ..., pending_save?: false}

TokenManager.access_token(MyApp.FicTokenManager)
# {:ok, "..."} oppure {:error, %ExFattureincloud.Error{kind: :authentication}}
```

Se il salvataggio fallisce, il gestore mantiene il token ruotato in memoria e
riprova solo il salvataggio dopo `retry_interval`; non ripete il refresh con le
vecchie credenziali. Fino alla persistenza, le richieste ricevono un errore di
autenticazione. Se il token scade durante questa attesa, prima viene salvato e
poi viene rinnovato usando il refresh token aggiornato.

I rifiuti HTTP 403/429 con `Retry-After` rispettano il tempo indicato dal servizio,
senza accorciarlo su richiesta dei chiamanti. Durante l'attesa un access token
ancora valido può essere usato. Gli errori di rete, server o protocollo sospendono
invece il rinnovo con stato `:refresh_failed`: un esito remoto incerto non viene
ripetuto automaticamente. `invalid_grant` produce `:reauthorization_required` e
richiede una nuova autorizzazione dell'utente.

Dopo aver riconciliato e salvato le credenziali correnti puoi ricaricarle:

```elixir
:ok = TokenManager.reload(MyApp.FicTokenManager)
```

`reload/1` rifiuta di scartare un rinnovo in corso o un token ancora da salvare.
Per un errore di persistenza ripristina prima l'archivio: il gestore ritenterà il
salvataggio pendente. Un crash tra il rinnovo remoto e il salvataggio riuscito può
perdere il token ruotato non ancora persistito; il riavvio legge solo ciò che
l'applicazione ha effettivamente salvato.

Serve **un gestore per connessione OAuth**, anche se la connessione comprende più
aziende. Il coordinamento è locale al processo. Su più nodi l'applicazione deve
eleggere un proprietario unico o fornire coordinamento distribuito: avviare lo
stesso gestore indipendentemente su ogni nodo non serializza i refresh.

## Device Code Flow

Questo flow richiede abilitazione del fornitore per l'applicazione.

```elixir
{:ok, device} = OAuth.device_code(client,
  client_id: "client-id", scope: ["settings:r"]
)
# Mostra user_code e verification_uri all'utente; non mostrare device_code.

case OAuth.device_token(client, client_id: "client-id", device_code: device["device_code"]) do
  {:ok, token} ->
    token

  {:error, %{code: code}} when code in ["authorization_pending", "slow_down"] ->
    # Pianifica un nuovo tentativo dopo interval; aumentalo per slow_down.
    {:pending, device["interval"]}

  {:error, error} ->
    {:error, error}
end
```

Ogni invocazione di `device_token/2` esegue un solo poll. L'helper non avvia processi
di polling; dopo il consenso puoi affidare il token ottenuto a `TokenManager`.
`device_code/2` gestisce sia il formato diretto mostrato nelle guide sia quello
dentro `data` usato dagli helper Go e TypeScript. Per un refresh device ometti
`client_secret`.

Fonti: [Authorization Code](https://developers.fattureincloud.it/docs/authentication/code-flow/vanilla-code/),
[Device Code](https://developers.fattureincloud.it/docs/authentication/device-code/).
