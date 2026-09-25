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
    {public, _budget} = sanitize(value, {@max_total_bytes, @max_nodes}, 0)
    public
  end

  defp sanitize(_value, {_bytes, 0} = budget, _depth), do: {nil, budget}

  defp sanitize(value, {bytes, nodes}, _depth) when is_binary(value) do
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

  defp sanitize(value, {bytes, nodes}, depth) when is_map(value) and depth < @max_depth do
    {public, budget} =
      value
      |> Enum.take(@max_children)
      |> Enum.reduce({%{}, {bytes, nodes - 1}}, fn entry, acc -> sanitize_map_entry(entry, acc, depth) end)

    {public, budget}
  end

  defp sanitize(value, {bytes, nodes}, depth) when is_list(value) and depth < @max_depth do
    {items, budget} =
      value
      |> Enum.take(@max_children)
      |> Enum.map_reduce({bytes, nodes - 1}, fn item, budget -> sanitize(item, budget, depth + 1) end)

    {items, budget}
  end

  defp sanitize(value, {bytes, nodes}, _depth)
       when is_number(value) or is_boolean(value) or is_nil(value) do
    size = :erlang.external_size(value)

    if size <= @max_scalar_bytes and size <= bytes do
      {value, {bytes - size, nodes - 1}}
    else
      {nil, {bytes, nodes - 1}}
    end
  end

  defp sanitize(_value, {bytes, nodes}, _depth), do: {nil, {bytes, nodes - 1}}

  defp sanitize_key(key, budget) when is_binary(key), do: sanitize(key, budget, 0)

  defp sanitize_key(key, budget) when is_atom(key) do
    {public, budget} = sanitize(Atom.to_string(key), budget, 0)
    if public == Atom.to_string(key), do: {key, budget}, else: {public, budget}
  end

  defp sanitize_key(_key, budget), do: {nil, budget}

  defp sanitize_map_entry({key, nested}, {acc, budget}, depth) do
    {public_key, budget} = sanitize_key(key, budget)

    if is_nil(public_key) do
      {acc, budget}
    else
      value = if secret_key?(public_key), do: @redacted, else: nested
      {public_value, budget} = sanitize(value, budget, depth + 1)
      {Map.put(acc, public_key, public_value), budget}
    end
  end

  defp secret_key?(key) when is_atom(key), do: secret_key?(Atom.to_string(key))

  defp secret_key?(key) when is_binary(key) do
    assignment = key <> "=" <> @key_probe
    Text.redact_secrets(assignment) != assignment
  end
end
