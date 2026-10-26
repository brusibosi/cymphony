defmodule CymphonyElixir.Agent.ProviderFailure do
  @moduledoc """
  An actionable provider or tool-permission refusal, distinct from a failed coding attempt.

  Only recognized CLI error envelopes or structured final tool-permission
  denials establish a refusal. Tool output, quoted fixtures and ordinary HTTP
  errors are never searched for refusal keywords.
  Raw error payloads stay out of the exception; its message is safe to publish.
  `retry_at` is a Unix millisecond deadline, or nil when operator action is needed.
  """

  defexception [:kind, :retry_at, message: "Provider unavailable"]

  @type t :: %__MODULE__{kind: :authentication | :quota | :permission, retry_at: integer() | nil, message: String.t()}

  @max_line_bytes 262_144
  @max_unix_ms 253_402_300_799_999
  @authentication_codes ["authentication_failed", "authentication_error", "invalid_api_key", "unauthenticated"]
  @quota_codes ["resource_exhausted", "quota_exceeded", "insufficient_quota", "usage_limit_reached"]

  @doc "Classifies chronological CLI JSON lines before public excerpt redaction."
  @spec classify([term()], integer()) :: t() | nil
  def classify(lines, now_ms) do
    Enum.reduce(lines, nil, &observe(&2, &1, now_ms))
  end

  @doc "Keeps only typed refusal metadata while the bounded transcript advances."
  @spec observe(t() | nil, term(), integer()) :: t() | nil
  def observe(previous, line, now_ms) do
    case decode_error(line) do
      :success -> nil
      error -> merge_failure(previous, failure(error, now_ms))
    end
  end

  defp decode_error(line) when is_binary(line) and byte_size(line) <= @max_line_bytes do
    case String.trim(line) do
      "AGY_ERROR: " <> json -> decode_agy_error(json)
      json -> decode_event(json)
    end
  end

  defp decode_error(_line), do: nil

  defp decode_agy_error(json) do
    case Jason.decode(json) do
      {:ok, %{"status" => "RESOURCE_EXHAUSTED"} = error} ->
        %{"code" => "RESOURCE_EXHAUSTED", "message" => error["short_error"]}

      _ ->
        nil
    end
  end

  defp decode_event(json) do
    case Jason.decode(json) do
      {:ok, event} -> event_error(event)
      _ -> nil
    end
  end

  defp event_error(%{"type" => "assistant", "isApiErrorMessage" => true, "error" => error}), do: error

  defp event_error(%{"type" => "result", "is_error" => is_error} = event) when is_boolean(is_error) do
    cond do
      permission_denied?(event["permission_denials"]) -> :permission_denied
      is_error -> event["error"]
      true -> :success
    end
  end

  defp event_error(%{"type" => "turn.failed", "error" => error}), do: error
  defp event_error(%{"type" => "turn.completed"}), do: :success
  defp event_error(%{"event" => "error"} = event), do: event["error"] || event
  defp event_error(%{"event" => "result", "result" => %{"status" => "ERROR", "error" => error}}), do: agy_error(error)
  defp event_error(%{"event" => "result", "result" => %{"status" => "SUCCESS"}}), do: :success
  defp event_error(_event), do: nil

  defp permission_denied?([_ | _] = denials), do: Enum.all?(denials, &valid_permission_denial?/1)
  defp permission_denied?(_denials), do: false

  defp valid_permission_denial?(%{"tool_name" => name, "tool_use_id" => id, "tool_input" => input})
       when is_binary(name) and is_binary(id) and is_map(input),
       do: String.trim(name) != "" and String.trim(id) != ""

  defp valid_permission_denial?(_denial), do: false

  # This literal is AGY's structured quota refusal, not arbitrary stdout text.
  defp agy_error("Individual quota reached." <> _rest = message),
    do: %{"code" => "RESOURCE_EXHAUSTED", "message" => message}

  defp agy_error(error), do: error

  defp failure(code, now_ms) when is_binary(code), do: failure(%{"code" => code}, now_ms)

  defp failure(:permission_denied, _now_ms) do
    %__MODULE__{kind: :permission, message: "Tool permission denied; grant the required tool permissions, then retry manually."}
  end

  defp failure(%{} = error, now_ms) do
    case error["code"] || error["status"] do
      code when is_binary(code) -> failure_for_code(String.downcase(code), error, now_ms)
      _ -> nil
    end
  end

  defp failure(_error, _now_ms), do: nil

  defp failure_for_code(code, _error, _now_ms) when code in @authentication_codes do
    %__MODULE__{kind: :authentication, message: "Provider authentication failed; sign in or correct credentials, then retry manually."}
  end

  defp failure_for_code(code, error, now_ms) when code in @quota_codes do
    retry_at = retry_deadline(error, now_ms)
    action = if retry_at, do: "waiting for the provider reset.", else: "restore quota, then retry manually."
    %__MODULE__{kind: :quota, retry_at: retry_at, message: "Provider quota exhausted; " <> action}
  end

  defp failure_for_code(_code, _error, _now_ms), do: nil

  defp merge_failure(previous, nil), do: previous

  defp merge_failure(%{kind: :quota} = previous, %{kind: :quota, retry_at: nil}), do: previous

  defp merge_failure(_previous, failure), do: failure

  defp retry_deadline(error, now_ms) do
    absolute_deadline(error["retry_at_ms"] || error["reset_at_ms"], now_ms) ||
      timestamp_deadline(error["retry_at"] || error["reset_at"], now_ms) ||
      relative_deadline(error["retry_after_ms"], 1, now_ms) ||
      relative_deadline(error["retry_after"], 1_000, now_ms) ||
      retry_info_deadline(error["details"], now_ms) ||
      reset_message_deadline(error["message"], now_ms)
  end

  defp absolute_deadline(value, now_ms) when is_integer(value) and value > now_ms and value <= @max_unix_ms, do: value
  defp absolute_deadline(_value, _now_ms), do: nil

  defp timestamp_deadline(value, now_ms) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> absolute_deadline(DateTime.to_unix(datetime, :millisecond), now_ms)
      _ -> nil
    end
  end

  defp timestamp_deadline(_value, _now_ms), do: nil

  defp relative_deadline(value, multiplier, now_ms) when is_integer(value) and value > 0,
    do: absolute_deadline(now_ms + value * multiplier, now_ms)

  defp relative_deadline(_value, _multiplier, _now_ms), do: nil

  defp retry_info_deadline(details, now_ms) when is_list(details) do
    Enum.find_value(details, fn
      %{"@type" => "type.googleapis.com/google.rpc.RetryInfo", "retryDelay" => delay} when is_binary(delay) ->
        case Regex.run(Regex.compile!("^(\\d+)(?:\\.(\\d{1,3}))?s$"), delay, capture: :all_but_first) do
          [seconds | fraction] ->
            milliseconds = String.to_integer(seconds) * 1_000 + fractional_ms(fraction)
            relative_deadline(milliseconds, 1, now_ms)

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  defp retry_info_deadline(_details, _now_ms), do: nil
  defp fractional_ms([]), do: 0
  defp fractional_ms([fraction]), do: fraction |> String.pad_trailing(3, "0") |> String.to_integer()

  defp reset_message_deadline(message, now_ms) when is_binary(message) do
    pattern = Regex.compile!("\\bResets in[ \\t]+(?:(\\d+)h)?(?:(\\d+)m)?(?:(\\d+)s)?\\b(?=\\.|[ \\t]*$)")

    case Regex.run(pattern, message, capture: :all_but_first) do
      units when is_list(units) ->
        [hours, minutes, seconds] = Enum.map(Enum.take(units ++ ["", "", ""], 3), &duration_unit/1)
        relative_deadline(hours * 3_600 + minutes * 60 + seconds, 1_000, now_ms)

      _ ->
        nil
    end
  end

  defp reset_message_deadline(_message, _now_ms), do: nil
  defp duration_unit(""), do: 0
  defp duration_unit(value), do: String.to_integer(value)
end
