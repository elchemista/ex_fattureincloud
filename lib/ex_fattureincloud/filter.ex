defmodule ExFattureincloud.Filter do
  @moduledoc """
  Immutable query builder compatible with the official Go/TypeScript filter helpers.

      iex> alias ExFattureincloud.Filter
      iex> Filter.where("name", :contains, "Rossi") |> Filter.and_where("active", :eq, true) |> Filter.build()
      "(name contains 'Rossi' and active = true)"

  Pass `build/1` directly as `q:`; Req URL-encodes it once. `nil` becomes `null`,
  strings are quoted, booleans/numbers are unquoted. Apostrophes, backslashes and
  control characters in string literals are rejected: the provider documents no
  escaping contract for these values. Use a manually verified raw `q` if needed.
  Field availability depends on the selected endpoint.
  """
  @operators %{
    eq: "=",
    gt: ">",
    gte: ">=",
    lt: "<",
    lte: "<=",
    neq: "<>",
    is: "is",
    is_not: "is not",
    like: "like",
    contains: "contains",
    not_like: "not like",
    not_contains: "not contains",
    starts_with: "starts with",
    ends_with: "ends with"
  }
  @enforce_keys [:expression]
  defstruct [:expression]
  @type t :: %__MODULE__{expression: String.t()}
  @type value :: String.t() | number() | boolean() | nil

  @doc "Builds one condition. Operators are atoms (e.g. :eq) or official strings (e.g. =)."
  @spec where(String.t(), atom() | String.t(), value()) :: t()
  def where(field, operator, value) do
    unless is_binary(field) and Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_.]*\z/, field),
      do: raise(ArgumentError, "invalid filter field")

    op = if is_atom(operator), do: @operators[operator], else: operator
    unless op in Map.values(@operators), do: raise(ArgumentError, "unsupported filter operator")
    %__MODULE__{expression: field <> " " <> op <> " " <> encode(value)}
  end

  @doc "Combines an existing filter and a new condition with AND."
  @spec and_where(t(), String.t(), atom() | String.t(), value()) :: t()
  def and_where(left, field, op, value), do: all(left, where(field, op, value))
  @doc "Combines an existing filter and a new condition with OR."
  @spec or_where(t(), String.t(), atom() | String.t(), value()) :: t()
  def or_where(left, field, op, value), do: any(left, where(field, op, value))
  @doc "Combines two filters with parenthesized AND."
  @spec all(t(), t()) :: t()
  def all(%__MODULE__{expression: left}, %__MODULE__{expression: right}),
    do: %__MODULE__{expression: "(" <> left <> " and " <> right <> ")"}

  @doc "Combines two filters with parenthesized OR."
  @spec any(t(), t()) :: t()
  def any(%__MODULE__{expression: left}, %__MODULE__{expression: right}),
    do: %__MODULE__{expression: "(" <> left <> " or " <> right <> ")"}

  @doc "Returns the unencoded query string."
  @spec build(t()) :: String.t()
  def build(%__MODULE__{expression: expression}), do: expression

  defp encode(nil), do: "null"
  defp encode(value) when is_boolean(value) or is_number(value), do: to_string(value)

  defp encode(value) when is_binary(value) do
    if Regex.match?(~r/['\\\x00-\x1F\x7F]/, value),
      do: raise(ArgumentError, "unsupported character in filter literal")

    "'" <> value <> "'"
  end

  defp encode(_),
    do: raise(ArgumentError, "filter value must be a string, number, boolean or nil")
end
