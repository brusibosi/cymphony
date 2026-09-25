defmodule CymphonyElixir.PublicEvent do
  @moduledoc """
  The retention boundary for agent-originated messages shown outside the host.

  The adapters still parse the complete event for results, session IDs and
  usage. Only the copy retained for status and log-event snapshots crosses
  this boundary. Oversize scalar values are omitted rather than prefix-cut:
  cutting a credential before redaction could expose a partial secret.
  """

  alias CymphonyElixir.Text

  @max_input_bytes 8192
  @max_scalar_bytes 1024
  @max_total_bytes 8192
  @max_nodes 96
  @max_children 20
  @max_depth 5
  @omitted "[event text omitted]"
  @redacted "[REDACTED]"
  @key_probe "cymphony_probe_value"

  @spec sanitize(term()) :: term()
  def sanitize(value) do
    {public, _budget} = sanitize(value, {@max_total_bytes, @max_nodes}, 0, :event)
    public
  end

  @doc """
  Formats an untrusted reason only after bounding and redacting its leaves.

  Unlike event JSON, diagnostics keep tuple/atom tags. Exception messages that
  are already binaries stay readable; other exceptions are plain sanitized
  fields, never arbitrary `Exception.message/1` or `Inspect` callbacks. Charlist
  candidates and unsupported terms are omitted rather than encoded as bytes.
  The final text crosses the ordinary retention boundary again.
  """
  @spec format_diagnostic(term()) :: String.t()
  def format_diagnostic({%{__exception__: true, message: message}, stacktrace})
      when is_binary(message) and is_list(stacktrace),
      do: sanitize(message)

  def format_diagnostic(value) do
    {public, _budget} = sanitize(value, {@max_total_bytes, @max_nodes}, 0, :diagnostic)

    public
    |> inspect(structs: false, charlists: :as_lists, limit: :infinity, printable_limit: :infinity)
    |> sanitize()
  end

  defp sanitize(_value, {_bytes, 0} = budget, _depth, _mode), do: {nil, budget}

  defp sanitize(value, {bytes, nodes}, _depth, _mode) when is_binary(value) do
    public =
      if byte_size(value) > @max_input_bytes do
        @omitted
      else
        value
        |> Text.scrub_invalid_utf8()
        |> Text.strip_ansi_and_control()
        |> Text.redact_secrets()
        |> Text.truncate_trailing_bytes(@max_scalar_bytes)
      end

    if byte_size(public) <= bytes do
      {public, {bytes - byte_size(public), nodes - 1}}
    else
      {nil, {bytes, nodes - 1}}
    end
  end

  defp sanitize(value, {bytes, nodes}, depth, mode) when is_map(value) and depth < @max_depth do
    {public, budget} =
      value
      |> :maps.iterator()
      |> take_map_entries(@max_children)
      |> Enum.reduce({%{}, {bytes, nodes - 1}}, fn entry, acc -> sanitize_map_entry(entry, acc, depth, mode) end)

    {public, budget}
  end

  defp sanitize([head | _tail], budget, depth, :diagnostic) when is_integer(head),
    do: sanitize(@omitted, budget, depth, :event)

  defp sanitize(value, {bytes, nodes} = budget, depth, mode) when is_list(value) and depth < @max_depth do
    case take_list(value, @max_children) do
      :improper ->
        sanitize(@omitted, budget, depth, :event)

      items ->
        Enum.map_reduce(items, {bytes, nodes - 1}, fn item, budget -> sanitize(item, budget, depth + 1, mode) end)
    end
  end

  defp sanitize(value, {bytes, nodes}, depth, :diagnostic) when is_tuple(value) and depth < @max_depth do
    items =
      cond do
        tuple_size(value) == 2 and secret_key?(elem(value, 0)) -> [elem(value, 0), @redacted]
        tuple_size(value) <= @max_children -> Tuple.to_list(value)
        true -> for index <- 0..(@max_children - 1), do: elem(value, index)
      end

    {items, budget} =
      Enum.map_reduce(items, {bytes, nodes - 1}, fn item, budget ->
        sanitize(item, budget, depth + 1, :diagnostic)
      end)

    {List.to_tuple(items), budget}
  end

  defp sanitize(value, {bytes, nodes}, _depth, _mode)
       when is_number(value) or is_boolean(value) or is_nil(value) do
    size = :erlang.external_size(value)

    if size <= @max_scalar_bytes and size <= bytes do
      {value, {bytes - size, nodes - 1}}
    else
      {nil, {bytes, nodes - 1}}
    end
  end

  defp sanitize(value, budget, _depth, :diagnostic) when is_atom(value), do: sanitize_key(value, budget)

  defp sanitize(_value, budget, depth, :diagnostic), do: sanitize(@omitted, budget, depth, :event)
  defp sanitize(_value, {bytes, nodes}, _depth, :event), do: {nil, {bytes, nodes - 1}}

  defp take_map_entries(_iterator, 0), do: []

  defp take_map_entries(iterator, remaining) do
    case :maps.next(iterator) do
      :none -> []
      {key, value, next} -> [{key, value} | take_map_entries(next, remaining - 1)]
    end
  end

  defp take_list(_tail, 0), do: []
  defp take_list([], _remaining), do: []

  defp take_list([head | tail], remaining) do
    case take_list(tail, remaining - 1) do
      :improper -> :improper
      items -> [head | items]
    end
  end

  defp take_list(_tail, _remaining), do: :improper

  defp sanitize_key(key, budget) when is_binary(key), do: sanitize(key, budget, 0, :event)

  defp sanitize_key(key, budget) when is_atom(key) do
    {public, budget} = sanitize(Atom.to_string(key), budget, 0, :event)
    if public == Atom.to_string(key), do: {key, budget}, else: {public, budget}
  end

  defp sanitize_key(_key, budget), do: {nil, budget}

  defp sanitize_map_entry({key, nested}, {acc, budget}, depth, mode) do
    secret? = secret_key?(key)
    {public_key, budget} = sanitize_key(key, budget)

    if is_nil(public_key) do
      {acc, budget}
    else
      value = if secret?, do: @redacted, else: nested
      {public_value, budget} = sanitize(value, budget, depth + 1, mode)
      {Map.put(acc, public_key, public_value), budget}
    end
  end

  defp secret_key?(key) when is_atom(key), do: secret_key?(Atom.to_string(key))

  defp secret_key?(key) when is_binary(key) do
    if byte_size(key) > @max_input_bytes do
      true
    else
      name = key |> Text.scrub_invalid_utf8() |> Text.strip_ansi_and_control()
      assignment = name <> "=" <> @key_probe
      Text.redact_secrets(assignment) != assignment
    end
  end

  defp secret_key?(_key), do: false
end
