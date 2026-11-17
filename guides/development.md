# Sviluppo e aggiornamento

```sh
mix deps.get
mix check
mix docs --warnings-as-errors
python3 scripts/generate.py --check
mix hex.build
```

I test sono offline, usano Req.Test e non creano documenti né inviano fatture.
Il contratto verifica tutte le operazioni, il routing dei wrapper, i parametri
obbligatori e i body multipart/JSON. I test del trasporto e degli helper coprono
errori, quote, retry, redirect, OAuth, filtri, paginazione e JWT ES256 con chiavi
generate in test. Questi controlli non sostituiscono una verifica con un account
reale autorizzato prima di rilasciare un'integrazione di produzione.

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

Il token provider deve essere rapido e restituire una stringa non vuota.
Le opzioni Req avanzate sono un punto di estensione per trasporto e test; non
impostare lì body, query o decoder incompatibili con il contratto dell'SDK.
Non attivare log HTTP completi se non gestisci esplicitamente le credenziali.

## Pubblicazione

`mix hex.build` genera il pacchetto senza pubblicarlo. Prima di pubblicare,
verifica nome, versione, licenza, changelog e verifica d'integrazione reale.
La CI controlla formattazione, compilazione, test e generazione riproducibile.
