#!/usr/bin/env python3
"""Generate Elixir endpoint wrappers from the vendored official OpenAPI. No dependencies."""
import argparse
import collections
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def snake(value):
    return re.sub(r"([a-z0-9])([A-Z])", r"\1_\2",
                  re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", value)).lower()


def string(value):
    return json.dumps(value, ensure_ascii=False).replace("#{", r"\#{")


def literal(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return string(value)
    if isinstance(value, list):
        return "[" + ", ".join(literal(v) for v in value) + "]"
    if isinstance(value, dict):
        return "%{" + ", ".join(f"{k}: {literal(v)}" for k, v in value.items()) + "}"
    raise TypeError(value)


def generate():
    spec = json.loads((ROOT / "priv/openapi.json").read_text())
    extensions = json.loads((ROOT / "priv/openapi-extensions.json").read_text())
    modules = collections.defaultdict(list)
    catalogue = []
    docs = ["# Endpoint disponibili", "", "Generato da `scripts/generate.py`. Non modificare manualmente.", "",
            "Ogni funzione riceve `client`, i parametri del percorso nell'ordine indicato,",
            "il body (se previsto) e infine `opts \\\\ []` per i parametri query.", "",
            "I body JSON mantengono l'envelope ufficiale, es. `%{data: %{name: \"Rossi\"}}`.",
            "Per gli upload il body è una lista di campi multipart Req.", "",
            "| Modulo | Funzione e argomenti dopo client | HTTP | Percorso |",
            "| --- | --- | --- | --- |"]

    def resolve(obj):
        if "$ref" not in obj:
            return obj
        node = spec
        for part in obj["$ref"].removeprefix("#/").split("/"):
            node = node[part]
        return node

    for path, item in sorted((spec["paths"] | extensions["paths"]).items()):
        for method, op in sorted(item.items()):
            if method not in {"get", "post", "put", "delete", "patch"}:
                continue
            name = snake(op["operationId"])
            module = {"Issued e-invoices": "IssuedEInvoices", "PriceLists": "PriceLists"}.get(
                op["tags"][0], op["tags"][0].replace(" ", ""))
            path_params = re.findall(r"\{([^}]+)\}", path)
            parameters = {}
            for p in item.get("parameters", []) + op.get("parameters", []):
                p = resolve(p)
                parameters[p["in"], p["name"]] = p
            query = []
            for p in parameters.values():
                if p["in"] != "query":
                    continue
                schema = resolve(p.get("schema", {}))
                query.append(dict(name=p["name"], required=p.get("required", False),
                                  type=schema.get("type"), enum=schema.get("enum", []),
                                  minimum=schema.get("minimum", 1 if p["name"] == "page" else None),
                                  maximum=schema.get("maximum")))
            content = resolve(op.get("requestBody", {})).get("content", {})
            accepts = []
            for status, response in op.get("responses", {}).items():
                if str(status).startswith("2"):
                    accepts.extend(resolve(response).get("content", {}))
            accept = "application/json" if "application/json" in accepts or not accepts else accepts[0]
            body = "multipart" if "multipart/form-data" in content else "json" if content else "none"
            args = path_params + (["body"] if content else []) + ["opts \\\\ []"]
            call_options = "path: [" + ", ".join(f"{p}: {p}" for p in path_params) + "], query: opts"
            if content:
                call_options += f", {'multipart' if body == 'multipart' else 'body'}: body"
            info = op.get("description", op.get("summary", name)).replace('"""', "'''")
            query_doc = "\n\nQuery options: " + ", ".join(
                f"`:{q['name']}`" + (" (required)" if q["required"] else "") for q in query) if query else ""
            doc = info + query_doc + f"\n\nOfficial operation: `{op['operationId']}`."
            types = ["ExFattureincloud.Client.t()"] + ["integer() | String.t()"] * len(path_params)
            if content:
                types += ["list()" if body == "multipart" else "map() | nil"]
            types += ["keyword() | map()"]
            modules[module].append(f'  @doc {string(doc)}\n  @spec {name}({", ".join(types)}) :: ExFattureincloud.Response.result()\n'
                                   f'  def {name}(client, {", ".join(args)}), do: ExFattureincloud.API.call(client, :{name}, {call_options})\n')
            meta = dict(operation_id=op["operationId"], path=path, path_params=path_params,
                        query=query, paginated=any(q["name"] == "page" for q in query),
                        module=module, accept=accept, body_required=op.get("requestBody", {}).get("required", False))
            entry = literal(meta)[:-1] + f", id: :{name}, method: :{method}, body: :{body}" + "}"
            catalogue.append(entry)
            signature = ", ".join(path_params + (["body"] if content else []) + ["opts"])
            docs.append(f"| `{module}` | `{name}({signature})` | {method.upper()} | `{path}` |")

    files = {}
    for module, functions in modules.items():
        filename = snake(module) + ".ex"
        files["lib/ex_fattureincloud/resources/" + filename] = (
            f"# Generated by scripts/generate.py. Do not edit.\ndefmodule ExFattureincloud.{module} do\n"
            f'  @moduledoc "Fatture in Cloud {module} endpoints. See the README for client configuration and response conventions."\n\n'
            + "\n".join(functions) + "end\n")

    files["lib/ex_fattureincloud/operations.ex"] = (
        '# Generated by scripts/generate.py. Do not edit.\ndefmodule ExFattureincloud.Operations do\n'
        '  @moduledoc "Pinned OpenAPI operation catalogue, including documented extensions."\n'
        '  @operations [\n' + ",\n".join(catalogue) + '\n]\n'
        '  @lookup Map.new(@operations, &{Atom.to_string(&1.id), &1})\n'
        '  @official Map.new(@operations, &{&1.operation_id, &1})\n'
        '  @doc "All supported operation descriptors."\n'
        '  @spec all() :: [map()]\n  def all, do: @operations\n'
        '  @doc "Finds an operation without converting user input to atoms."\n'
        '  @spec get(atom() | String.t()) :: map() | nil\n'
        '  def get(id) when is_atom(id), do: get(Atom.to_string(id))\n'
        '  def get(id) when is_binary(id), do: @lookup[id] || @official[id]\n'
        '  def get(_), do: nil\nend\n')
    scopes = spec["components"]["securitySchemes"]["OAuth2AuthenticationCodeFlow"]["flows"]["authorizationCode"]["scopes"]
    files["lib/ex_fattureincloud/scopes.ex"] = (
        '# Generated by scripts/generate.py. Do not edit.\ndefmodule ExFattureincloud.Scopes do\n'
        '  @moduledoc "Official OAuth scope strings and their descriptions."\n'
        '  @scopes %{' + ", ".join(f"{string(k)} => {string(v)}" for k, v in scopes.items()) + '}\n'
        '  @doc "Returns scope names with descriptions."\n  @spec all() :: %{String.t() => String.t()}\n  def all, do: @scopes\n'
        '  @doc "Whether a scope is in the pinned specification."\n  @spec valid?(String.t()) :: boolean()\n  def valid?(scope), do: Map.has_key?(@scopes, scope)\nend\n')
    files["guides/endpoints.md"] = "\n".join(docs) + "\n"
    return files, len(catalogue)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail when generated files differ")
    args = parser.parse_args()
    files, count = generate()
    stale = []
    for name, content in files.items():
        if name.endswith(".ex"):
            content = subprocess.run(["mix", "format", "--stdin-filename", name, "-"],
                                     input=content, text=True, capture_output=True, check=True, cwd=ROOT).stdout
        path = ROOT / name
        if args.check:
            if not path.exists() or path.read_text() != content:
                stale.append(name)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
    if stale:
        print("Stale generated files:\n" + "\n".join(stale), file=sys.stderr)
        return 1
    print(f"{'Verified' if args.check else 'Generated'} {count} operations across {len(files) - 3} resource modules.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
