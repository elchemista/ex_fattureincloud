%{
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "mix.exs"],
        excluded: [
          ~r"/resources/",
          "lib/ex_fattureincloud/operations.ex",
          "lib/ex_fattureincloud/scopes.ex"
        ]
      },
      checks: %{
        extra: [
          {Credo.Check.Readability.Specs, []}
        ]
      }
    }
  ]
}
