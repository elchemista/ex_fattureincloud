# Run from the unpacked package with MIX_ENV=prod; no external API requests.
{:ok, _applications} = Application.ensure_all_started(:ex_fattureincloud)

for module <- [Credo, Dialyxir, ExDoc, Plug, OpenApiSpex] do
  if Code.ensure_loaded?(module) do
    raise "development or test dependency present in production package: #{inspect(module)}"
  end
end

for path <- ["openapi.json", "openapi-source.json", "openapi-extensions.json", "UPSTREAM_LICENSE"] do
  unless File.regular?(Application.app_dir(:ex_fattureincloud, "priv/" <> path)) do
    raise "required runtime contract file missing from package: #{path}"
  end
end

client = ExFattureincloud.new(token: "package-smoke-placeholder")

{:error, %ExFattureincloud.Error{kind: :validation}} =
  ExFattureincloud.call(client, :unknown_package_smoke_operation)

unless length(ExFattureincloud.Operations.all()) >= 124 do
  raise "packaged operation catalogue is incomplete"
end

IO.puts("Packaged SDK starts in production without development or contract-test dependencies.")
