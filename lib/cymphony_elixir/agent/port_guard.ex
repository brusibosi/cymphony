defmodule CymphonyElixir.Agent.PortGuard do
  @moduledoc """
  Owns an agent's OS port inside its runtime's shutdown barrier.

  Port-owner death alone does not kill a silent OS child. This temporary child
  forwards the existing port protocol and kills the tracked process group before
  exiting. OTP's Unix spawn driver gives the child its own process group; group
  leadership is checked before using a negative PID. Detached descendants (and
  remote processes behind a lost SSH connection) cannot be fenced by a local
  process group. The owner receives an immutable captured identity and monitor
  handle before readiness is released, so fallback cleanup never re-reads a
  vanished port or process-group leader.
  """

  use GenServer, restart: :temporary

  @type handle :: %{
          guard: pid(),
          ref: reference(),
          port: port(),
          os_pid: pos_integer() | nil,
          group?: boolean(),
          exited?: boolean()
        }

  @spec open(GenServer.server(), (-> {:ok, port()} | {:error, term()})) ::
          {:ok, port(), handle()} | {:error, term()}
  @spec open(GenServer.server(), (-> {:ok, port()} | {:error, term()}), keyword()) ::
          {:ok, port(), handle()} | {:error, term()}
  def open(supervisor, opener, opts \\ []) when is_function(opener, 0) do
    opts = Keyword.merge(opts, owner: self(), opener: opener)

    case DynamicSupervisor.start_child(supervisor, {__MODULE__, opts}) do
      {:ok, guard} ->
        ref = Process.monitor(guard)
        identity = GenServer.call(guard, :capture)
        handle = Map.merge(identity, %{guard: guard, ref: ref})
        # The owner has the original capture before the shell can create children.
        GenServer.cast(guard, :release)
        {:ok, handle.port, handle}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run(GenServer.server(), (-> {:ok, port()} | {:error, term()}), pos_integer()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, term()}
  @spec run(GenServer.server(), (-> {:ok, port()} | {:error, term()}), pos_integer(), keyword()) ::
          {:ok, {binary(), non_neg_integer()}} | {:error, term()}
  def run(supervisor, opener, timeout_ms, opts \\ []) do
    with {:ok, port, watch} <- open(supervisor, opener, opts) do
      try do
        collect(port, [], System.monotonic_time(:millisecond) + timeout_ms, watch.ref)
      after
        finish(watch)
      end
    end
  end

  defp collect(port, chunks, deadline, ref) do
    receive do
      {:DOWN, ^ref, :process, _guard, reason} -> {:error, {:port_guard_exit, reason}}
      {^port, {:data, bytes}} -> collect(port, [bytes | chunks], deadline, ref)
      {^port, :eof} -> collect(port, chunks, deadline, ref)
      {^port, {:exit_status, status}} -> {:ok, {IO.iodata_to_binary(Enum.reverse(chunks)), status}}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> {:error, :timeout}
    end
  end

  @doc "Gates a task-created shell until its guard captures the OS process group."
  @spec prepare(binary()) :: binary()
  def prepare(command) do
    "IFS= read -r __cymphony_guard_ready || exit 1\nexec </dev/null\n" <> command
  end

  @spec stop_owner(GenServer.server(), pid()) :: :ok | {:error, term()}
  def stop_owner(supervisor, owner) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.reduce_while(:ok, fn {_, guard, _, _}, :ok ->
      case stop_owned_guard(guard, owner) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp stop_owned_guard(guard, owner) do
    if GenServer.call(guard, :owner, 1_000) == owner, do: close(guard)
    :ok
  catch
    :exit, reason ->
      if Process.alive?(guard), do: {:error, {:port_cleanup_failed, reason}}, else: :ok
  end

  @spec finish(handle()) :: :ok
  def finish(watch) do
    Process.demonitor(watch.ref, [:flush])

    case stop_guard(watch.guard) do
      :missing -> kill_process(watch)
      :ok -> :ok
    end

    :ok
  end

  @spec close(pid() | handle()) :: :ok
  def close(%{} = handle), do: finish(handle)

  def close(guard) when is_pid(guard) do
    stop_guard(guard)
    :ok
  end

  defp stop_guard(guard) do
    GenServer.stop(guard, :normal, 2_000)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal] -> :missing
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    ref = Process.monitor(owner)

    case Keyword.fetch!(opts, :opener).() do
      {:ok, port} ->
        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            nil -> nil
          end

        group? = is_integer(os_pid) and owns_group?(os_pid)

        {:ok,
         %{
           owner: owner,
           ref: ref,
           port: port,
           os_pid: os_pid,
           exited?: false,
           group?: group?,
           handshake?: Keyword.get(opts, :handshake, false),
           released?: false
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:capture, _from, state) do
    {:reply, Map.take(state, [:port, :os_pid, :group?, :exited?]), state}
  end

  def handle_call(:owner, _from, state), do: {:reply, state.owner, state}

  @impl true
  def handle_cast(:release, state) do
    if state.handshake? and not state.released? and Process.alive?(state.owner) and
         Port.info(state.port) != nil do
      Port.command(state.port, "\n")
    end

    {:noreply, %{state | released?: true}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _owner, _reason}, %{ref: ref} = state), do: {:stop, :normal, state}

  def handle_info({port, {:exit_status, _status} = payload}, %{port: port} = state) do
    send(state.owner, {port, payload})
    {:noreply, %{state | exited?: true}}
  end

  def handle_info({port, payload}, %{port: port} = state) do
    send(state.owner, {port, payload})
    {:noreply, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port, exited?: false} = state) when reason != :normal do
    # A transport can close stdin during readiness (e.g. SSH auth rejection),
    # yielding :epipe instead of exit_status. Preserve preceding output and
    # terminate collection visibly rather than waiting the whole turn deadline.
    send(state.owner, {port, {:exit_status, 1}})
    {:noreply, %{state | exited?: true}}
  end

  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_process(state)
    close_port(state.port)
    :ok
  end

  defp kill_process(%{os_pid: nil}), do: :ok

  defp kill_process(state) do
    target = if state.group?, do: "-#{state.os_pid}", else: to_string(state.os_pid)
    wait_for_exit? = not state.exited? and Port.info(state.port) != nil
    System.cmd("/bin/kill", ["-KILL", "--", target], stderr_to_stdout: true)

    if wait_for_exit? do
      receive do
        {port, {:exit_status, _status}} when port == state.port -> :ok
      after
        500 -> :ok
      end
    end
  end

  defp owns_group?(os_pid) do
    {output, status} = System.cmd("/bin/ps", ["-o", "pgid=", "-p", to_string(os_pid)], stderr_to_stdout: true)
    status == 0 and String.trim(output) == to_string(os_pid)
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
