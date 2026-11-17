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
  @spec stream(ExFattureincloud.Client.t(), atom() | String.t(), keyword()) :: Enumerable.t()
  def stream(client, operation, options \\ []) do
    spec = Operations.get(operation)

    unless spec && spec.paginated,
      do: raise(ArgumentError, "operation does not support pagination")

    query = options |> Keyword.get(:query, []) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    page = Map.get(query, "page", 1)

    unless is_integer(page) and page > 0,
      do: raise(ArgumentError, "page must be a positive integer")

    Stream.resource(
      fn -> page end,
      fn
        :done ->
          {:halt, :done}

        current ->
          opts = Keyword.put(options, :query, Map.put(query, "page", current))

          case API.call(client, operation, opts) do
            {:ok, %{data: items, pagination: pagination}} when is_list(items) ->
              case next_page(current, items, pagination) do
                {:error, error} -> {[{:error, error}], :done}
                next -> {Enum.map(items, &{:ok, &1}), next}
              end

            {:ok, _} ->
              {[
                 {:error,
                  %Error{kind: :protocol, message: "paginated response data must be a list"}}
               ], :done}

            {:error, error} ->
              {[{:error, error}], :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  @spec stream!(ExFattureincloud.Client.t(), atom() | String.t(), keyword()) :: Enumerable.t()
  def stream!(client, operation, options \\ []) do
    stream(client, operation, options)
    |> Stream.map(fn
      {:ok, item} -> item
      {:error, error} -> raise error
    end)
  end

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

  defp invalid_metadata(message), do: {:error, %Error{kind: :protocol, message: message}}
end
