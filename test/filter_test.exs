defmodule ExFattureincloud.FilterTest do
  use ExUnit.Case, async: true
  alias ExFattureincloud.Filter
  doctest Filter

  # Parity cases from the official Go/TypeScript filter test suites; see guides/sdk-parity.md.
  for {field, op, value, expected} <- [
        {"qualified", :eq, true, "qualified = true"},
        {"price", :lte, 10.12, "price <= 10.12"},
        {"sweet", :ends_with, "cioccolato", "sweet ends with 'cioccolato'"},
        {"girlfriend", :is_not, nil, "girlfriend is not null"},
        {"count", :eq, 0, "count = 0"},
        {"active", :eq, false, "active = false"}
      ] do
    test "official condition: #{expected}" do
      assert Filter.where(unquote(field), unquote(op), unquote(value)) |> Filter.build() ==
               unquote(expected)
    end
  end

  test "nested parentheses preserve AND/OR grouping and Unicode" do
    left =
      Filter.where("city", :eq, "Warsaw")
      |> Filter.and_where("company", :eq, "Przewodniczka Social Media")

    right = Filter.where("nation", :eq, "IT") |> Filter.or_where("nation", :eq, "FR")

    assert Filter.all(left, right) |> Filter.build() ==
             "((city = 'Warsaw' and company = 'Przewodniczka Social Media') and (nation = 'IT' or nation = 'FR'))"

    assert Filter.build(left) == "(city = 'Warsaw' and company = 'Przewodniczka Social Media')"
  end

  test "all official operators are supported" do
    for op <- [
          "=",
          ">",
          ">=",
          "<",
          "<=",
          "<>",
          "is",
          "is not",
          "like",
          "contains",
          "not like",
          "not contains",
          "starts with",
          "ends with"
        ] do
      assert Filter.where("field", op, 1) |> Filter.build() == "field #{op} 1"
    end
  end

  test "invalid identifiers, unsupported values and ambiguous quoting are rejected" do
    assert_raise ArgumentError, fn -> Filter.where("field or 1", :eq, 1) end
    assert_raise ArgumentError, fn -> Filter.where("field", :invalid, 1) end
    assert_raise ArgumentError, fn -> apply(Filter, :where, ["field", :eq, %{}]) end

    for value <- ["O'Reilly", "back\\slash", "line\nbreak"] do
      assert_raise ArgumentError, fn -> Filter.where("name", :eq, value) end
    end
  end
end
