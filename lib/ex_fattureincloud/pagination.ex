defmodule ExFattureincloud.Pagination do
  @moduledoc """
  Lazy pagination for list operations with `page`/`per_page` parameters.

  `stream/3` emits `{:ok, item}` tuples. On failure it emits one `{:error, error}`
  and halts, so partial results cannot look like a successful complete collection.
  `stream!/3` emits items directly and raises on an error. No page is fetched until
  consumption. `Enum.take/2` stops requests as soon as enough items are available.

      Pagination.stream!(client, :list_clients,
        path: [company_id: 123], query: [per_page: 100])
      |> Enum.take(10)
  """
  alias ExFattureincloud.{API, Error, Operations}

  @doc "Lazily emits tagged results and halts after the first error."
  @spec stream(ExFattureincloud.Client.t(), atom() | String.t(), keyword()) :: Enumerable.t()
  def stream(client, operation, options \\ []) do
    operation |> Operations.get() |> ensure_paginated!()
    query = options |> Keyword.get(:query, []) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    page = query |> Map.get("page", 1) |> ensure_page!()

    Stream.resource(
      fn -> page end,
      &fetch_page(client, operation, options, query, &1),
      fn _ -> :ok end
    )
  end

  @doc "Lazily emits items and raises an Error when a page fails."
  @spec stream!(ExFattureincloud.Client.t(), atom() | String.t(), keyword()) :: Enumerable.t()
  def stream!(client, operation, options \\ []) do
    client |> stream(operation, options) |> Stream.map(&unwrap_item!/1)
  end

  @spec ensure_paginated!(map() | nil) :: :ok
  defp ensure_paginated!(%{paginated: true}), do: :ok

  defp ensure_paginated!(_operation),
    do: raise(ArgumentError, "operation does not support pagination")

  @spec ensure_page!(term()) :: pos_integer()
  defp ensure_page!(page) when is_integer(page) and page > 0, do: page
  defp ensure_page!(_page), do: raise(ArgumentError, "page must be a positive integer")

  @spec fetch_page(
          ExFattureincloud.Client.t(),
          atom() | String.t(),
          keyword(),
          map(),
          pos_integer() | :done
        ) :: tuple()
  defp fetch_page(_client, _operation, _options, _query, :done), do: {:halt, :done}

  defp fetch_page(client, operation, options, query, current) do
    options = Keyword.put(options, :query, Map.put(query, "page", current))
    client |> API.call(operation, options) |> page_result(current)
  end

  @spec page_result(ExFattureincloud.Response.result(), pos_integer()) :: tuple()
  defp page_result({:ok, %{data: items, pagination: pagination}}, current) when is_list(items),
    do: current |> next_page(items, pagination) |> page_items(items)

  defp page_result({:ok, _response}, _current),
    do:
      {[{:error, %Error{kind: :protocol, message: "paginated response data must be a list"}}],
       :done}

  defp page_result({:error, error}, _current), do: {[{:error, error}], :done}

  @spec page_items(term(), list()) :: tuple()
  defp page_items({:error, error}, _items), do: {[{:error, error}], :done}
  defp page_items(next, items), do: {Enum.map(items, &{:ok, &1}), next}

  @spec unwrap_item!({:ok, term()} | {:error, Error.t()}) :: term()
  defp unwrap_item!({:ok, item}), do: item
  defp unwrap_item!({:error, error}), do: raise(error)

  @spec next_page(pos_integer(), list(), map()) :: pos_integer() | :done | {:error, Error.t()}
  defp next_page(current, _, %{"current_page" => actual}) when actual != current,
    do: invalid_metadata("server returned an unexpected page")

  defp next_page(_, [], _), do: :done

  defp next_page(current, _, %{"last_page" => last}) when is_integer(last) and last > 0 do
    if current < last, do: current + 1, else: :done
  end

  defp next_page(current, _, %{"next_page_url" => url}) do
    if is_binary(url) and url != "", do: current + 1, else: :done
  end

  defp next_page(current, items, %{"per_page" => per_page})
       when is_integer(per_page) and per_page > 0 do
    if length(items) < per_page, do: :done, else: current + 1
  end

  defp next_page(_, _, _), do: invalid_metadata("pagination metadata is missing or invalid")

  @spec invalid_metadata(String.t()) :: {:error, Error.t()}
  defp invalid_metadata(message), do: {:error, %Error{kind: :protocol, message: message}}
end
