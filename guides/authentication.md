# Autenticazione

## Token manuale

```elixir
client = ExFattureincloud.new(token: System.fetch_env!("FIC_ACCESS_TOKEN"))
```

Il token deve appartenere all'azienda scelta e includere gli scope necessari.
La libreria non cerca variabili d'ambiente implicitamente e non memorizza token
nella configurazione globale di un'applicazione multiutente.

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

## Refresh

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
account nella tua applicazione, così richieste concorrenti non usano lo stesso
refresh token contemporaneamente. Una funzione `token: fn -> ... end` permette
di leggere il token corrente da un archivio gestito dall'applicazione.

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

Ogni invocazione esegue un solo poll. Nessun processo rimane in attesa internamente.
`device_code/2` gestisce sia il formato diretto mostrato nelle guide sia quello
dentro `data` usato dagli helper Go e TypeScript. Per un refresh device ometti
`client_secret`.

Fonti: [Authorization Code](https://developers.fattureincloud.it/docs/authentication/code-flow/vanilla-code/),
[Device Code](https://developers.fattureincloud.it/docs/authentication/device-code/).
