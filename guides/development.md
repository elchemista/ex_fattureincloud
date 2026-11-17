# Sviluppo e aggiornamento

```sh
mix deps.get
mix check
mix quality
mix docs --warnings-as-errors
python3 scripts/generate.py --check
mix hex.build
```

I test sono offline, usano Req.Test e non creano documenti né inviano fatture.
Il contratto verifica tutte le operazioni, il routing dei wrapper, i parametri
obbligatori e i body multipart/JSON. I test del trasporto e degli helper coprono
errori, quote, retry, redirect, OAuth, filtri, paginazione e JWT ES256 con chiavi
generate in test. Il gestore OAuth è verificato su rinnovi concorrenti, timer,
Task asincroni, persistenza fallita, token pendenti scaduti e recupero dello stato.
Questi controlli non sostituiscono una verifica con un account
reale autorizzato prima di rilasciare un'integrazione di produzione.

`mix check` usa l'ambiente `test` ed esegue controllo della formattazione,
compilazione e test con i warning trattati come errori. `mix quality` usa `dev` ed
esegue formattazione, compilazione, `mix credo --strict` e `mix dialyzer`.
Credo e Dialyxir sono dipendenze solo di sviluppo, con `runtime: false`; non
aggiungono processi all'applicazione in produzione. La prima analisi Dialyzer
costruisce le PLT in `_build/dev/plts` e può richiedere più tempo delle successive.

## Generazione riproducibile

`priv/openapi.json` contiene la specifica enriched completa, convertita da YAML
senza rimuovere campi. `priv/openapi-source.json` riporta commit, versione e hash
della sorgente e della conversione. `priv/UPSTREAM_LICENSE` conserva la licenza.
La compilazione della libreria non accede alla rete e non esegue generatori.

```sh
python3 scripts/generate.py
```

Il generatore usa solo la libreria standard Python e `mix format`. Produce:

- Moduli in `lib/ex_fattureincloud/resources/`.
- Catalogo `Operations` e scope ufficiali.
- Guida `endpoints.md`.

`--check` confronta i risultati senza scrivere file. I file generati non vanno
modificati a mano. Quando aggiorni il contratto, usa un commit ufficiale preciso,
verifica la conversione, aggiorna gli hash e rigenera. Controlla anche gli SDK
Go/TypeScript per cambiamenti agli helper non descritti nell'OpenAPI.

`priv/openapi-extensions.json` aggiunge esclusivamente endpoint pubblicati nelle
guide ma ancora assenti dalla specifica. Per ogni estensione è indicata la fonte.
Quando l'endpoint entra nel contratto ufficiale, elimina l'estensione dopo averne
confrontato parametri e risposte.

## Scelte di progetto

La superficie degli endpoint segue i nomi ufficiali in snake_case. Le risposte
rimangono mappe per preservare campi nuovi e dettagli fiscali del servizio.
La libreria non contiene regole per calcolare IVA, ritenute o arrotondamenti.
Le scritture non sono ripetute automaticamente. La paginazione non maschera errori
come elenchi vuoti; i limiti sconosciuti non diventano disponibilità illimitata.

Il percorso con token manuale e gli helper OAuth espliciti mantengono client
immutabili senza stato globale. `OAuth.TokenManager` è opzionale e usa un
`GenServer` per serializzare i rinnovi di una connessione; HTTP e persistenza
girano in un `Task`, così il coordinatore resta disponibile per le richieste di
stato. Le chiamate concorrenti condividono il risultato, senza avviare un Task
per ogni richiesta API quando il token è già valido.

Il gestore usa callback obbligatori per caricare e salvare atomicamente le
credenziali. Non introduce un database, una cache di risposte o una tabella ETS
globale: il suo stato serve a coordinare rinnovo e persistenza. La paginazione
usa già `Stream` per scaricare solo le pagine consumate e gli allegati usano
`File.stream!` per evitare di caricare l'intero file in memoria. Queste scelte
limitano lavoro e memoria senza duplicare cache o pool già gestiti da Req.

Un token provider personalizzato restituisce una stringa non vuota,
`{:ok, access_token}` oppure `{:error, %ExFattureincloud.Error{}}`.
Il gestore aggiunge il ciclo opzionale descritto nella guida di autenticazione;
un provider personalizzato rimane sotto il controllo dell'applicazione.
Le opzioni Req avanzate sono un punto di estensione per trasporto e test; non
impostare lì body, query o decoder incompatibili con il contratto dell'SDK.
Non attivare log HTTP completi se non gestisci esplicitamente le credenziali.

## Pubblicazione

`mix hex.build` genera il pacchetto senza pubblicarlo. Prima di pubblicare,
verifica nome, versione, licenza, changelog e verifica d'integrazione reale.
La CI controlla formattazione, compilazione, test e generazione riproducibile;
un job dedicato esegue anche Credo e Dialyzer tramite `mix quality`.
