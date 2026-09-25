defmodule CymphonyElixir.Agent.OutputWindow do
  @moduledoc """
  A finite transcript retained until an agent adapter parses a finished turn.

  Keep an opening window, a tail, and the most recent semantic milestones. A
  plain tail would lose Codex's early thread ID or a final agent message when
  thousands of progress events follow it. The local debug logger receives
  each complete raw line separately; this window is not the debug transcript.
  """

  @max_line_bytes 262_144
  @max_first_bytes 262_144
  @max_first_lines 4
  @max_tail_bytes 786_432
  @max_tail_lines 64
  @max_special_bytes 524_288
  @max_antigravity_text_bytes 65_536
  @truncated " [truncated]"

  @type t :: map()

  @spec new() :: t()
  def new do
    %{next: 0, first: [], first_bytes: 0, tail: [], tail_bytes: 0, special: %{}, antigravity_step: nil}
  end

  @spec push(t(), binary()) :: t()
  def push(window, line) when is_binary(line) and byte_size(line) <= @max_line_bytes do
    index = window.next
    entry = {index, line}
    bytes = byte_size(line)

    window
    |> Map.put(:next, index + 1)
    |> maybe_keep_first(entry, bytes)
    |> keep_tail(entry, bytes)
    |> maybe_keep_special(entry, bytes)
    |> maybe_keep_antigravity_step(entry)
  end

  def push(window, _line), do: %{window | next: window.next + 1}

  @spec lines(t()) :: [binary()]
  def lines(window) do
    entries = window.first ++ window.tail ++ Map.values(window.special)

    entries =
      case window.antigravity_step do
        nil -> entries
        step -> [antigravity_step_entry(step) | Enum.reject(entries, fn {_, line} -> antigravity_step_line?(line) end)]
      end

    entries
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp maybe_keep_first(window, entry, bytes) do
    if length(window.first) < @max_first_lines and window.first_bytes + bytes <= @max_first_bytes do
      %{window | first: [entry | window.first], first_bytes: window.first_bytes + bytes}
    else
      window
    end
  end

  defp keep_tail(window, entry, bytes) do
    {tail, tail_bytes} = trim_tail([entry | window.tail], window.tail_bytes + bytes)
    %{window | tail: tail, tail_bytes: tail_bytes}
  end

  defp trim_tail(tail, bytes) when length(tail) > @max_tail_lines or bytes > @max_tail_bytes do
    {_oldest_index, oldest_line} = List.last(tail)
    trim_tail(List.delete_at(tail, -1), bytes - byte_size(oldest_line))
  end

  defp trim_tail(tail, bytes), do: {tail, bytes}

  defp maybe_keep_special(window, {_, line} = entry, _bytes) do
    case classify(line) do
      nil ->
        window

      kind ->
        special = Map.put(window.special, kind, entry)
        %{window | special: trim_special(special)}
    end
  end

  defp trim_special(special) do
    bytes = Enum.reduce(special, 0, fn {_, {_, line}}, acc -> acc + byte_size(line) end)

    if bytes > @max_special_bytes do
      {oldest_kind, _entry} = Enum.min_by(special, fn {_, {index, _}} -> index end)
      trim_special(Map.delete(special, oldest_kind))
    else
      special
    end
  end

  defp classify(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} -> classify_event(event)
      _ -> nil
    end
  end

  defp classify_event(%{"type" => "thread.started"}), do: :thread_started
  defp classify_event(%{"type" => "item.completed", "item" => %{"type" => "agent_message"}}), do: :agent_message
  defp classify_event(%{"type" => "turn.completed"}), do: :turn_completed
  defp classify_event(%{"type" => "turn.failed"}), do: :turn_failed
  defp classify_event(%{"type" => "result"}), do: :claude_result
  defp classify_event(%{"event" => "init"}), do: :antigravity_init
  defp classify_event(%{"event" => "result"}), do: :antigravity_result
  defp classify_event(_event), do: nil

  defp maybe_keep_antigravity_step(window, {index, line}) do
    case Jason.decode(line) do
      {:ok, %{"event" => "step_update", "step_update" => %{} = step}} ->
        summary =
          window.antigravity_step ||
            %{last_index: index, deltas_rev: [], text_bytes: 0, truncated?: false, usage: nil}

        summary = summary |> keep_antigravity_delta(step) |> keep_antigravity_usage(step)
        %{window | antigravity_step: %{summary | last_index: index}}

      _ ->
        window
    end
  end

  defp keep_antigravity_delta(summary, %{"text_delta" => delta}) when is_binary(delta) do
    remaining = max(@max_antigravity_text_bytes - summary.text_bytes, 0)
    piece = CymphonyElixir.Text.truncate_trailing_bytes(delta, remaining)
    deltas_rev = if piece == "", do: summary.deltas_rev, else: [piece | summary.deltas_rev]

    %{
      summary
      | deltas_rev: deltas_rev,
        text_bytes: summary.text_bytes + byte_size(piece),
        truncated?: summary.truncated? or byte_size(piece) < byte_size(delta)
    }
  end

  defp keep_antigravity_delta(summary, _step), do: summary

  defp keep_antigravity_usage(summary, %{"usage" => %{} = usage}) do
    allowed = ["input_tokens", "output_tokens", "total_tokens"]

    public_usage =
      usage
      |> Map.take(allowed)
      |> Map.new(fn {key, value} -> {key, bounded_usage_number(value)} end)

    %{summary | usage: public_usage}
  end

  defp keep_antigravity_usage(summary, _step), do: summary

  defp bounded_usage_number(value) when is_integer(value) and value >= 0 do
    if :erlang.external_size(value) <= 64, do: value, else: 0
  end

  defp bounded_usage_number(_value), do: 0

  defp antigravity_step_entry(summary) do
    text = summary.deltas_rev |> Enum.reverse() |> IO.iodata_to_binary()
    text = if summary.truncated?, do: text <> @truncated, else: text

    step = %{}
    step = if summary.deltas_rev == [], do: step, else: Map.put(step, "text_delta", text)
    step = if is_map(summary.usage), do: Map.put(step, "usage", summary.usage), else: step

    {summary.last_index, Jason.encode!(%{"event" => "step_update", "step_update" => step})}
  end

  defp antigravity_step_line?(line) do
    match?({:ok, %{"event" => "step_update"}}, Jason.decode(line))
  end
end
