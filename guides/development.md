# Sviluppo e aggiornamento

```sh
mix deps.get
mix check
mix test --only contract --warnings-as-errors
mix test --cover --warnings-as-errors
mix quality
mix docs --warnings-as-errors
python3 scripts/generate.py --check
mix hex.build
```

I test sono offline e non creano documenti né inviano fatture. Il trasporto viene
esercitato con Req.Test; OpenApiSpex controlla gli schemi dei contratti HTTP.
OpenApiSpex e Plug sono dipendenze **solo `:test`**; Req.Test è il supporto di test
fornito da Req, che rimane il client HTTP usato anche in produzione.
I test del trasporto e degli helper coprono
errori, quote, retry, redirect, OAuth, filtri, paginazione e JWT ES256 con chiavi
generate in test. Il gestore OAuth è verificato su rinnovi concorrenti, timer,
Task asincroni, persistenza fallita, token pendenti scaduti e recupero dello stato.
Questi controlli verificano il contratto HTTP versionato, senza attestare la
correttezza fiscale dei dati o sostituire una verifica con un account reale
autorizzato prima di rilasciare un'integrazione di produzione.

`mix check` usa l'ambiente `test` ed esegue controllo della formattazione,
compilazione e test con i warning trattati come errori. `mix quality` usa `dev` ed
esegue formattazione, compilazione, `mix credo --strict` e `mix dialyzer`.
Credo e Dialyxir sono dipendenze **solo `:dev`**, con `runtime: false`; non
aggiungono processi all'applicazione in produzione. La prima analisi Dialyzer
costruisce le PLT in `_build/dev/plts` e può richiedere più tempo delle successive.

## Contratti OpenAPI e mock HTTP

`ExFattureincloud.TestSupport.OpenAPIMock`, in `test/support/open_api_mock.ex`, legge
direttamente `priv/openapi.json` e le estensioni documentate in
`priv/openapi-extensions.json`. Non usa gli schemi del catalogo generato dell'SDK
come oracolo per verificare quello stesso catalogo. Il contratto decodificato e
gli indici vengono riutilizzati tramite `:persistent_term` nell'helper di test;
questo codice e la sua cache non entrano nella libreria di produzione.

Per tutte le **124 operazioni**, `ContractTest` costruisce parametri e body dagli
schemi, chiama il wrapper Elixir e verifica la richiesta HTTP effettiva. Il mock
controlla metodo, percorso, autorizzazione, parametri e body JSON/multipart con
OpenApiSpex, quindi valida anche la risposta simulata rispetto allo schema della
risposta e al relativo stato HTTP. Il test verifica infine ciò che il client
riceve, incluse risposte vuote e XML. Sono controllate anche le arità dei wrapper
con query facoltativa e l'assenza dei parametri obbligatori.

La validazione non modifica il payload trasmesso. Un controllo aggiuntivo confronta
i tipi JSON prima e dopo il casting: per esempio, `"amount": "10"` non può
passare come numero grazie a una conversione implicita. I normali parametri URL
restano stringhe sul collegamento HTTP e vengono interpretati secondo lo schema;
i formati data possono essere riconosciuti come `Date`/`DateTime` dal validatore.

Per aggiungere un test puoi registrare un'aspettativa sullo stesso processo usato
da Req.Test:

```elixir
alias ExFattureincloud.{Clients, TestSupport.OpenAPIMock}

client = ExFattureincloud.new(
  token: "test-token",
  req_options: [plug: {Req.Test, __MODULE__}]
)

OpenAPIMock.expect(__MODULE__, :list_clients, examples: false)
assert {:ok, _response} = Clients.list_clients(client, 12_345)
Req.Test.verify!(__MODULE__)
```

`examples: false` sceglie esplicitamente la generazione dagli schemi con
`OpenApiSpex.Schema.example/2`: rimuove le annotazioni `example`/`examples`
**soltanto dalla copia usata per generare i dati** e seleziona un candidato enum
non nullo quando lo schema non ammette `null`. Gli schemi usati per validare e i
file sorgenti non vengono corretti o indeboliti. `examples: true` usa gli esempi
ufficiali disponibili e fallisce se contraddicono il relativo schema.

La specifica inclusa presenta **26 incoerenze note negli esempi JSON a livello di
media type**, tra richieste e risposte. Sono elencate con puntatore alla sorgente
ed errore in `test/fixtures/openapi_example_issues.json`. La baseline contiene gli
SHA-256 sia del contratto ufficiale sia delle estensioni; il test controlla gli
hash e confronta l'intero insieme di sorgenti con problemi rilevati. Un esempio
nuovo o una modifica del contratto richiede una revisione esplicita, senza introdurre esclusioni
generiche nella validazione. Quando aggiorni la sorgente, riesamina i puntatori
e aggiorna la baseline soltanto dopo aver verificato le differenze.

Il tag `:contract` comprende i test delle operazioni e quelli del mock:

```sh
mix test --only contract --warnings-as-errors
```

I test con tag `:sdk_compatibility` verificano separatamente che tutti i 26 esempi
incoerenti mantengano i valori JSON durante il trasporto. Usano risposte Req.Test
dirette, perché il mock contrattuale deve continuare a rifiutare quei dati.
Il [confronto con gli SDK ufficiali](sdk-parity.md) descrive gli esperimenti
Go/JavaScript/TypeScript, le issue e le correzioni usate come riferimento.

```sh
mix test --only sdk_compatibility --warnings-as-errors
```

La generazione garantisce dati compatibili con gli schemi, non dati fiscali
utilizzabili per emettere una fattura. Questi test non eseguono chiamate al
fornitore e non verificano regole contabili, disponibilità del piano o accettazione
da parte dello SDI con un account reale.

## Generazione riproducibile

`priv/openapi.json` contiene la specifica enriched completa, convertita da YAML
senza rimuovere campi. `priv/openapi-source.json` riporta commit, versione e hash
della sorgente e della conversione. `priv/UPSTREAM_LICENSE` conserva la licenza.
La compilazione della libreria non accede alla rete e non esegue generatori.

```sh
python3 scripts/generate.py
```

Il generatore usa Python 3.9 o successivo, la libreria standard e `mix format`.
Produce:

- Moduli in `lib/ex_fattureincloud/resources/`.
- Catalogo `Operations` e scope ufficiali.
- Guida `endpoints.md`.

`--check` confronta i risultati senza scrivere file. I file generati non vanno
modificati a mano. Quando aggiorni il contratto, usa un commit ufficiale preciso,
verifica la conversione, aggiorna gli hash e rigenera. Controlla anche gli SDK
Go/JavaScript/TypeScript per cambiamenti agli helper non descritti nell'OpenAPI.

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

## Continuous integration

Il workflow `.github/workflows/ci.yml` parte per i push su `main`, per le pull
request e su avvio manuale. I controlli hanno stati separati:

| Job | Combinazioni | Controlli |
| --- | --- | --- |
| Tests | Elixir 1.16.x / OTP 26.x | Compilazione e suite completa con warning trattati come errori; compatibilità con la versione minima supportata. |
| Tests | Elixir 1.19.x / OTP 28.x e 1.20.x / OTP 29.x | Formattazione, compilazione, suite completa e coverage minima del 90% con report; su 1.20 anche rigenerazione riproducibile degli endpoint. |
| Credo strict | Elixir 1.19.x / OTP 28.x e 1.20.x / OTP 29.x | Job dedicato per ciascuna combinazione, compilazione senza warning e `mix credo --strict`. |
| Dialyzer | Elixir 1.19.x / OTP 28.x e 1.20.x / OTP 29.x | Job dedicato per ciascuna combinazione, compilazione senza warning e analisi dei tipi. |
| Documentation and package dry-run | Elixir 1.20.x / OTP 29.x | Audit delle dipendenze Hex, documentazione senza warning, build ed estrazione del pacchetto, compilazione e smoke test isolati in produzione. |

I job di repository installano le dipendenze con `mix deps.get --check-locked`.
Il formatter viene verificato sulle versioni moderne: quello di Elixir 1.16
ha regole di impaginazione diverse, indipendenti dalla compatibilità del codice.
Le cache di dipendenze, build e PLT sono separate per job e indicizzate dalle
versioni effettive di OTP/Elixir e dall'hash di `mix.lock`. Una matrice fallita
non interrompe le altre combinazioni. I job hanno timeout; un nuovo aggiornamento
annulla l'esecuzione precedente dello stesso workflow e riferimento Git.

Il token GitHub dispone soltanto di `contents: read` e il checkout non conserva
le credenziali Git. I report di coverage, la documentazione generata e l'archivio
Hex locale vengono conservati come artifact per 14 giorni. Il workflow non
pubblica pacchetti, non distribuisce applicazioni e non richiede token Fatture
in Cloud.

`mix hex.audit` fa fallire il job quando Hex segnala pacchetti ritirati o
advisory di sicurezza noti. Il job del pacchetto estrae una copia in una directory
temporanea e lì risolve le sole dipendenze di produzione, compila con i warning
trattati come errori ed esegue `scripts/ci/package_smoke.exs`. Lo smoke test avvia
l'SDK, controlla i file del contratto e il catalogo e verifica che Credo, Dialyxir,
ExDoc, Plug e OpenApiSpex non siano disponibili nel runtime isolato. Esegue una
validazione locale senza richieste HTTP; i test contrattuali completi restano
nel job della suite.
