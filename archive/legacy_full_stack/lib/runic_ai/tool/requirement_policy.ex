defmodule RunicAI.Tool.RequirementPolicy do
  @moduledoc """
  Semantic tool-use policy for recipe-level tool loops.

  This contract exists above provider-specific `tool_choice` flags.
  Recipes use it to express what they actually mean:

  - `:optional` — tools are available but not required
  - `:required` — require tool use until at least one tool batch has been
    executed for the current loop, then allow a normal answer turn
  - `:per_turn` — require tool use on every model turn while tools are visible
  """

  alias RunicAI.Agent.State
  alias RunicAI.Agent.TurnRequest
  alias RunicAI.Error
  alias RunicAI.Message
  alias RunicAI.Tool.Selection

  @valid_modes [:optional, :required, :per_turn]
  @metadata_key :tool_requirement
  @post_tool_key :post_tool_turn

  @enforce_keys [:mode, :metadata]
  defstruct [:mode, :metadata]

  @type mode :: :optional | :required | :per_turn

  @type t :: %__MODULE__{
          mode: mode(),
          metadata: map()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :optional)
    metadata = Keyword.get(opts, :metadata, %{})

    with :ok <- validate_mode(mode),
         :ok <- validate_metadata(metadata) do
      {:ok, %__MODULE__{mode: mode, metadata: metadata}}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | mode() | keyword() | map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = policy), do: validate(policy)
  def from_input(mode) when mode in @valid_modes, do: new(mode: mode)
  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      mode: Map.get(input, :mode) || Map.get(input, "mode") || :optional,
      metadata: Map.get(input, :metadata) || Map.get(input, "metadata") || %{}
    )
  end

  def from_input(other) do
    {:error,
     Error.validation(
       "expected a Tool.RequirementPolicy-compatible value, got: #{inspect(other)}",
       source: __MODULE__
     )}
  end

  @spec from_input!(t() | mode() | keyword() | map() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, policy} -> policy
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    new(mode: policy.mode, metadata: policy.metadata)
  end

  @spec from_recipe_opts!(keyword()) :: t()
  def from_recipe_opts!(opts) when is_list(opts) do
    reject_raw_tool_choice!(opts)
    from_input!(Keyword.get(opts, :tool_requirement))
  end

  @spec resolve_tool_choice(
          t() | mode() | keyword() | map() | nil,
          TurnRequest.t(),
          Selection.t()
        ) ::
          {:ok, :required | :auto | nil} | {:error, Error.t()}
  def resolve_tool_choice(policy, %TurnRequest{} = turn_request, %Selection{} = selection) do
    with {:ok, policy} <- from_input(policy),
         {:ok, turn_request} <- TurnRequest.validate(turn_request),
         {:ok, selection} <- Selection.validate(selection) do
      {:ok, do_resolve_tool_choice(policy, turn_request, selection)}
    end
  end

  @spec resolve_tool_choice!(
          t() | mode() | keyword() | map() | nil,
          TurnRequest.t(),
          Selection.t()
        ) ::
          :required | :auto | nil
  def resolve_tool_choice!(policy, %TurnRequest{} = turn_request, %Selection{} = selection) do
    case resolve_tool_choice(policy, turn_request, selection) do
      {:ok, tool_choice} -> tool_choice
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec mark_post_tool_turn(map()) :: map()
  def mark_post_tool_turn(metadata) when is_map(metadata) do
    requirement_metadata =
      metadata
      |> Map.get(@metadata_key, %{})
      |> then(&Map.put(&1, @post_tool_key, true))

    metadata
    |> Map.delete("tool_requirement")
    |> Map.put(@metadata_key, requirement_metadata)
  end

  @spec clear_post_tool_turn(map()) :: map()
  def clear_post_tool_turn(metadata) when is_map(metadata) do
    requirement_metadata =
      metadata
      |> Map.get(@metadata_key)
      |> case do
        map when is_map(map) ->
          map
          |> Map.delete(@post_tool_key)
          |> Map.delete("post_tool_turn")

        _ ->
          nil
      end

    metadata =
      metadata
      |> Map.delete(@metadata_key)
      |> Map.delete("tool_requirement")

    case requirement_metadata do
      map when is_map(map) and map_size(map) > 0 -> Map.put(metadata, @metadata_key, map)
      _ -> metadata
    end
  end

  defp reject_raw_tool_choice!(opts) do
    if Keyword.has_key?(opts, :tool_choice) do
      raise ArgumentError,
            "recipe-level :tool_choice is not supported; use :tool_requirement with :optional, :required, or :per_turn"
    end

    llm_opts = Keyword.get(opts, :llm_opts, [])

    if Keyword.keyword?(llm_opts) and Keyword.has_key?(llm_opts, :tool_choice) do
      raise ArgumentError,
            "provider-level llm_opts[:tool_choice] is not supported in recipe APIs; use :tool_requirement instead"
    end
  end

  defp do_resolve_tool_choice(_policy, _turn_request, %Selection{visible_tools: []}), do: nil
  defp do_resolve_tool_choice(%__MODULE__{mode: :optional}, _turn_request, _selection), do: nil

  defp do_resolve_tool_choice(%__MODULE__{mode: :per_turn}, _turn_request, _selection),
    do: :required

  defp do_resolve_tool_choice(
         %__MODULE__{mode: :required},
         %TurnRequest{} = turn_request,
         _selection
       ) do
    if post_tool_turn?(turn_request), do: :auto, else: :required
  end

  defp post_tool_turn?(%TurnRequest{input_message: %Message{}}), do: false

  defp post_tool_turn?(%TurnRequest{} = turn_request) do
    state_post_tool_turn?(turn_request.state) or observations_post_tool_turn?(turn_request)
  end

  defp state_post_tool_turn?(%State{metadata: metadata, conversation: conversation})
       when is_map(metadata) do
    case Map.get(metadata, @metadata_key) do
      %{@post_tool_key => true} -> true
      %{"post_tool_turn" => true} -> true
      _ -> latest_non_system_role(conversation.messages) == :tool
    end
  end

  defp observations_post_tool_turn?(%TurnRequest{observations: observations})
       when is_list(observations) do
    Enum.any?(observations, &match?(%Message{role: :tool}, &1))
  end

  defp latest_non_system_role(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :system} -> nil
      %Message{role: role} -> role
      _ -> nil
    end)
  end

  defp validate_mode(mode) when mode in @valid_modes, do: :ok

  defp validate_mode(mode) do
    {:error,
     Error.validation("invalid tool requirement mode: #{inspect(mode)}",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("tool requirement metadata must be a map, got: #{inspect(metadata)}",
       source: __MODULE__
     )}
  end
end
