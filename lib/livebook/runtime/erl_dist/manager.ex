defmodule Livebook.Runtime.ErlDist.Manager do
  @moduledoc false

  # The primary Livebook process started on a remote node.
  #
  # This process is responsible for monitoring the owner
  # process on the main node and cleaning up if it terminates.
  # Also, this process keeps track of the evaluators
  # and spawns/terminates them whenever necessary for the evaluation.

  use GenServer

  alias Livebook.Evaluator
  alias Livebook.Runtime.ErlDist

  @name __MODULE__

  @await_owner_timeout 5_000

  @doc """
  Starts the manager.

  Note: make sure to `set_owner` within `@await_owner_timeout`
  or the manager assumes it's not needed and terminates.
  """
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts, name: @name)
  end

  @doc """
  Sets the owner process.

  The owner process is watched and as soon as it terminates,
  the manager also terminates. All the evaluation results are
  send directly to the owner.
  """
  @spec set_owner(node(), pid()) :: :ok
  def set_owner(node, owner) do
    GenServer.cast({@name, node}, {:set_owner, owner})
  end

  @doc """
  Evaluates the given code using an `Evaluator` process
  belonging to the given `container_ref` and instructs
  it to send all the outputs to the owner process.

  If that's the first evaluation for this `container_ref`,
  a new evaluator is started.

  See `Evaluator` for more details.
  """
  @spec evaluate_code(
          node(),
          String.t(),
          Evaluator.ref(),
          Evaluator.ref(),
          Evaluator.ref() | nil,
          keyword()
        ) :: :ok
  def evaluate_code(node, code, container_ref, evaluation_ref, prev_evaluation_ref, opts \\ []) do
    GenServer.cast(
      {@name, node},
      {:evaluate_code, code, container_ref, evaluation_ref, prev_evaluation_ref, opts}
    )
  end

  @doc """
  Removes the specified evaluation from the history.

  See `Evaluator` for more details.
  """
  @spec forget_evaluation(node(), Evaluator.ref(), Evaluator.ref()) :: :ok
  def forget_evaluation(node, container_ref, evaluation_ref) do
    GenServer.cast({@name, node}, {:forget_evaluation, container_ref, evaluation_ref})
  end

  @doc """
  Terminates the `Evaluator` process belonging to the given container.
  """
  @spec drop_container(node(), Evaluator.ref()) :: :ok
  def drop_container(node, container_ref) do
    GenServer.cast({@name, node}, {:drop_container, container_ref})
  end

  @doc """
  Asynchronously sends completion request for the given `hint` text.

  The completion request is forwarded to `Evaluator` process
  belonging to the given `container_ref`. If there's not evaluator,
  there's also no binding and environment, so the completion is handled
  by a temporary process.

  See `Livebook.Runtime` for more details.
  """
  @spec request_completion_items(
          node(),
          pid(),
          term(),
          String.t(),
          Evaluator.ref(),
          Evaluator.ref()
        ) :: :ok
  def request_completion_items(node, send_to, ref, hint, container_ref, evaluation_ref) do
    GenServer.cast(
      {@name, node},
      {:request_completion_items, send_to, ref, hint, container_ref, evaluation_ref}
    )
  end

  @doc """
  Stops the manager.

  This results in all Livebook-related modules being unloaded from this node.
  """
  @spec stop(node()) :: :ok
  def stop(node) do
    GenServer.stop({@name, node})
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :check_owner, @await_owner_timeout)

    ## Initialize the node

    Process.flag(:trap_exit, true)

    {:ok, evaluator_supervisor} = ErlDist.EvaluatorSupervisor.start_link()
    {:ok, io_forward_gl_pid} = ErlDist.IOForwardGL.start_link()
    {:ok, completion_supervisor} = Task.Supervisor.start_link()

    # Set `ignore_module_conflict` only for the Manager lifetime.
    initial_ignore_module_conflict = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)

    # Register our own standard error IO devices that proxies
    # to sender's group leader.
    original_standard_error = Process.whereis(:standard_error)
    Process.unregister(:standard_error)
    Process.register(io_forward_gl_pid, :standard_error)

    {:ok,
     %{
       owner: nil,
       evaluators: %{},
       evaluator_supervisor: evaluator_supervisor,
       completion_supervisor: completion_supervisor,
       initial_ignore_module_conflict: initial_ignore_module_conflict,
       original_standard_error: original_standard_error
     }}
  end

  @impl true
  def terminate(_reason, state) do
    Code.compiler_options(ignore_module_conflict: state.initial_ignore_module_conflict)

    Process.unregister(:standard_error)
    Process.register(state.original_standard_error, :standard_error)

    ErlDist.unload_required_modules()

    :ok
  end

  @impl true
  def handle_info(:check_owner, state) do
    # If not owner has been set within @await_owner_timeout
    # from the start, terminate the process.
    if state.owner do
      {:noreply, state}
    else
      {:stop, :no_owner, state}
    end
  end

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _, :process, pid, reason}, state) do
    state.evaluators
    |> Enum.find(fn {_container_ref, evaluator_pid} ->
      evaluator_pid == pid
    end)
    |> case do
      {container_ref, _} ->
        message = Exception.format_exit(reason)
        send(state.owner, {:container_down, container_ref, message})
        {:noreply, %{state | evaluators: Map.delete(state.evaluators, container_ref)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _from, _reason}, state) do
    {:stop, :shutdown, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_cast({:set_owner, owner}, state) do
    Process.monitor(owner)

    {:noreply, %{state | owner: owner}}
  end

  def handle_cast(
        {:evaluate_code, code, container_ref, evaluation_ref, prev_evaluation_ref, opts},
        state
      ) do
    state = ensure_evaluator(state, container_ref)

    Evaluator.evaluate_code(
      state.evaluators[container_ref],
      state.owner,
      code,
      evaluation_ref,
      prev_evaluation_ref,
      opts
    )

    {:noreply, state}
  end

  def handle_cast({:forget_evaluation, container_ref, evaluation_ref}, state) do
    with {:ok, evaluator} <- Map.fetch(state.evaluators, container_ref) do
      Evaluator.forget_evaluation(evaluator, evaluation_ref)
    end

    {:noreply, state}
  end

  def handle_cast({:drop_container, container_ref}, state) do
    state = discard_evaluator(state, container_ref)
    {:noreply, state}
  end

  def handle_cast(
        {:request_completion_items, send_to, ref, hint, container_ref, evaluation_ref},
        state
      ) do
    if evaluator = Map.get(state.evaluators, container_ref) do
      Evaluator.request_completion_items(evaluator, send_to, ref, hint, evaluation_ref)
    else
      # Since there's no evaluator, we may as well get the completion items here.
      Task.Supervisor.start_child(state.completion_supervisor, fn ->
        binding = []
        env = :elixir.env_for_eval([])
        items = Livebook.Completion.get_completion_items(hint, binding, env)
        send(send_to, {:completion_response, ref, items})
      end)
    end

    {:noreply, state}
  end

  defp ensure_evaluator(state, container_ref) do
    if Map.has_key?(state.evaluators, container_ref) do
      state
    else
      {:ok, evaluator} = ErlDist.EvaluatorSupervisor.start_evaluator(state.evaluator_supervisor)
      Process.monitor(evaluator)
      %{state | evaluators: Map.put(state.evaluators, container_ref, evaluator)}
    end
  end

  defp discard_evaluator(state, container_ref) do
    case Map.fetch(state.evaluators, container_ref) do
      {:ok, evaluator} ->
        ErlDist.EvaluatorSupervisor.terminate_evaluator(state.evaluator_supervisor, evaluator)
        %{state | evaluators: Map.delete(state.evaluators, container_ref)}

      :error ->
        state
    end
  end
end
