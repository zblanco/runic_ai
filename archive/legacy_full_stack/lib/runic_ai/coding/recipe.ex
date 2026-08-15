defmodule RunicAI.Coding.Recipe do
  @moduledoc """
  Mode-specific configuration for the standard coding agent.

  A recipe selects which coding tools are visible, how many tool turns the
  integrated loop may take, and whether patch operations are forced into dry-run
  mode. The low-level tool implementations remain in `RunicAI.Coding.Tools`.
  """

  alias RunicAI.Error

  @read_tools ~w(list_dir find_files read_file read_range read_many search_text search_regex extract_diagrams render_mermaid)
  @git_read_tools ~w(git_status git_diff git_log git_show git_branch)
  @patch_tools ~w(apply_patch)
  @verification_tools ~w(compile_project run_tests run_formatter project_command runtime_smoke source_assert changed_file_inventory)
  @code_execution_tools ~w(execute_code sandbox_status)

  @valid_modes [:read_only, :patch, :verify]

  @enforce_keys [
    :name,
    :mode,
    :visible_tools,
    :tool_requirement,
    :max_turns,
    :dry_run?,
    :verification_policy,
    :metadata
  ]
  defstruct name: :general,
            mode: :verify,
            visible_tools: @read_tools ++ @git_read_tools ++ @patch_tools ++ @verification_tools,
            tool_requirement: :optional,
            max_turns: 10,
            dry_run?: false,
            verification_policy: :targeted_first,
            metadata: %{}

  @type mode :: :read_only | :patch | :verify

  @type t :: %__MODULE__{
          name: atom(),
          mode: mode(),
          visible_tools: [String.t()],
          tool_requirement: :optional | :required | :per_turn | nil,
          max_turns: pos_integer(),
          dry_run?: boolean(),
          verification_policy: atom(),
          metadata: map()
        }

  @spec read_tools() :: [String.t()]
  def read_tools, do: @read_tools

  @spec git_read_tools() :: [String.t()]
  def git_read_tools, do: @git_read_tools

  @spec patch_tools() :: [String.t()]
  def patch_tools, do: @patch_tools

  @spec verification_tools() :: [String.t()]
  def verification_tools, do: @verification_tools

  @spec code_execution_tools() :: [String.t()]
  def code_execution_tools, do: @code_execution_tools

  @spec named(atom(), keyword()) :: t()
  def named(name, opts \\ [])

  def named(:explain_repo, opts) do
    new!(
      Keyword.merge(
        [
          name: :explain_repo,
          mode: :read_only,
          visible_tools: @read_tools ++ @git_read_tools,
          max_turns: 6,
          metadata: %{command: "/explain-repo"}
        ],
        opts
      )
    )
  end

  def named(:review, opts) do
    new!(
      Keyword.merge(
        [
          name: :review,
          mode: :read_only,
          visible_tools: @read_tools ++ @git_read_tools,
          max_turns: 8,
          metadata: %{command: "/review", focus: :diff_review}
        ],
        opts
      )
    )
  end

  def named(:triage_bug, opts) do
    new!(
      Keyword.merge(
        [
          name: :triage_bug,
          mode: :read_only,
          visible_tools: @read_tools ++ @git_read_tools,
          max_turns: 8,
          metadata: %{command: "/triage-bug", focus: :bug_investigation}
        ],
        opts
      )
    )
  end

  def named(:write_tests, opts) do
    new!(
      Keyword.merge(
        [
          name: :write_tests,
          mode: :verify,
          visible_tools: @read_tools ++ @git_read_tools ++ @patch_tools ++ @verification_tools,
          max_turns: 12,
          verification_policy: :targeted_first,
          metadata: %{command: "/write-tests", focus: :test_writing}
        ],
        opts
      )
    )
  end

  def named(:fix_ci, opts) do
    new!(
      Keyword.merge(
        [
          name: :fix_ci,
          mode: :verify,
          visible_tools: @read_tools ++ @git_read_tools ++ @patch_tools ++ @verification_tools,
          max_turns: 14,
          verification_policy: :command_output_driven,
          metadata: %{command: "/fix-ci", focus: :ci_repair}
        ],
        opts
      )
    )
  end

  def named(:sandboxed_verify, opts) do
    new!(
      Keyword.merge(
        [
          name: :sandboxed_verify,
          mode: :verify,
          visible_tools:
            @read_tools ++
              @git_read_tools ++
              @patch_tools ++
              @verification_tools ++
              @code_execution_tools,
          max_turns: 12,
          verification_policy: :targeted_first,
          metadata: %{command: "/sandboxed-verify", focus: :sandboxed_verification}
        ],
        opts
      )
    )
  end

  def named(:polyglot_experiment, opts) do
    new!(
      Keyword.merge(
        [
          name: :polyglot_experiment,
          mode: :read_only,
          visible_tools: @read_tools ++ @git_read_tools ++ @code_execution_tools,
          max_turns: 8,
          metadata: %{command: "/polyglot-experiment", focus: :sandboxed_experiment}
        ],
        opts
      )
    )
  end

  def named(:read_only, opts), do: new!(Keyword.merge([mode: :read_only], opts))
  def named(:patch, opts), do: new!(Keyword.merge([mode: :patch], opts))
  def named(:verify, opts), do: new!(Keyword.merge([mode: :verify], opts))
  def named(:general, opts), do: new!(opts)

  def named(name, _opts) do
    raise ArgumentError, "unknown coding recipe: #{inspect(name)}"
  end

  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) when is_list(opts) do
    mode = Keyword.get(opts, :mode, :verify)
    name = Keyword.get(opts, :name, mode_name(mode))

    visible_tools =
      case Keyword.fetch(opts, :visible_tools) do
        {:ok, nil} -> default_visible_tools(mode)
        {:ok, tools} -> tools
        :error -> default_visible_tools(mode)
      end

    tool_requirement = Keyword.get(opts, :tool_requirement, :optional)
    max_turns = Keyword.get(opts, :max_turns, default_max_turns(mode))
    dry_run? = Keyword.get(opts, :dry_run?, false)
    verification_policy = Keyword.get(opts, :verification_policy, :targeted_first)
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, mode} <- normalize_mode(mode),
         :ok <- validate_name(name),
         {:ok, visible_tools} <- normalize_visible_tools(visible_tools),
         :ok <- validate_tool_requirement(tool_requirement),
         :ok <- validate_max_turns(max_turns),
         :ok <- validate_boolean(dry_run?, :dry_run?),
         :ok <- validate_atom(verification_policy, :verification_policy),
         :ok <- validate_metadata(metadata) do
      {:ok,
       %__MODULE__{
         name: name,
         mode: mode,
         visible_tools: visible_tools,
         tool_requirement: tool_requirement,
         max_turns: max_turns,
         dry_run?: dry_run?,
         verification_policy: verification_policy,
         metadata: metadata
       }}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, recipe} -> recipe
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec from_input(t() | keyword() | map() | atom() | nil) :: {:ok, t()} | {:error, Error.t()}
  def from_input(nil), do: new()
  def from_input(%__MODULE__{} = recipe), do: validate(recipe)

  def from_input(recipe)
      when recipe in [
             :explain_repo,
             :review,
             :triage_bug,
             :write_tests,
             :fix_ci,
             :sandboxed_verify,
             :polyglot_experiment,
             :read_only,
             :patch,
             :verify,
             :general
           ],
      do: {:ok, named(recipe)}

  def from_input(recipe) when is_atom(recipe) do
    {:error,
     Error.validation("unknown coding recipe",
       source: __MODULE__,
       details: %{recipe: recipe}
     )}
  end

  def from_input(opts) when is_list(opts), do: new(opts)

  def from_input(input) when is_map(input) do
    new(
      name: get(input, :name, :general),
      mode: get(input, :mode, :verify),
      visible_tools: get(input, :visible_tools, nil),
      tool_requirement: get(input, :tool_requirement, :optional),
      max_turns: get(input, :max_turns, default_max_turns(get(input, :mode, :verify))),
      dry_run?: get(input, :dry_run?, get(input, :dry_run, false)),
      verification_policy: get(input, :verification_policy, :targeted_first),
      metadata: get(input, :metadata, %{})
    )
  end

  def from_input(other) do
    {:error,
     Error.validation("expected a Coding.Recipe-compatible value",
       source: __MODULE__,
       details: %{input: other}
     )}
  end

  @spec from_input!(t() | keyword() | map() | atom() | nil) :: t()
  def from_input!(input) do
    case from_input(input) do
      {:ok, recipe} -> recipe
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = recipe) do
    new(
      name: recipe.name,
      mode: recipe.mode,
      visible_tools: recipe.visible_tools,
      tool_requirement: recipe.tool_requirement,
      max_turns: recipe.max_turns,
      dry_run?: recipe.dry_run?,
      verification_policy: recipe.verification_policy,
      metadata: recipe.metadata
    )
  end

  @spec default_visible_tools(mode() | String.t() | atom()) :: [String.t()]
  def default_visible_tools(mode) do
    case normalize_mode(mode) do
      {:ok, :read_only} -> @read_tools ++ @git_read_tools
      {:ok, :patch} -> @read_tools ++ @git_read_tools ++ @patch_tools
      {:ok, :verify} -> @read_tools ++ @git_read_tools ++ @patch_tools ++ @verification_tools
      {:error, _error} -> @read_tools ++ @git_read_tools ++ @patch_tools ++ @verification_tools
    end
  end

  defp default_max_turns(mode) do
    case normalize_mode(mode) do
      {:ok, :read_only} -> 6
      {:ok, :patch} -> 8
      {:ok, :verify} -> 12
      {:error, _error} -> 10
    end
  end

  defp mode_name(:read_only), do: :read_only
  defp mode_name(:patch), do: :patch
  defp mode_name(:verify), do: :verify
  defp mode_name(_mode), do: :general

  defp normalize_mode(mode) when mode in @valid_modes, do: {:ok, mode}
  defp normalize_mode("read_only"), do: {:ok, :read_only}
  defp normalize_mode("patch"), do: {:ok, :patch}
  defp normalize_mode("verify"), do: {:ok, :verify}

  defp normalize_mode(mode) do
    {:error,
     Error.validation("invalid coding recipe mode",
       source: __MODULE__,
       details: %{mode: mode, valid_modes: @valid_modes}
     )}
  end

  defp validate_name(name) when is_atom(name), do: :ok
  defp validate_name(name), do: validate_atom(name, :name)

  defp normalize_visible_tools(nil), do: {:ok, default_visible_tools(:verify)}

  defp normalize_visible_tools(tools) when is_list(tools) do
    if Enum.all?(tools, &is_binary/1) do
      {:ok, tools}
    else
      invalid_visible_tools(tools)
    end
  end

  defp normalize_visible_tools(tools), do: invalid_visible_tools(tools)

  defp invalid_visible_tools(tools) do
    {:error,
     Error.validation("visible tools must be a list of strings",
       source: __MODULE__,
       details: %{visible_tools: tools}
     )}
  end

  defp validate_tool_requirement(value) when value in [:optional, :required, :per_turn, nil],
    do: :ok

  defp validate_tool_requirement(value) do
    {:error,
     Error.validation("invalid tool requirement",
       source: __MODULE__,
       details: %{tool_requirement: value}
     )}
  end

  defp validate_max_turns(max_turns) when is_integer(max_turns) and max_turns > 0, do: :ok

  defp validate_max_turns(max_turns) do
    {:error,
     Error.validation("max_turns must be a positive integer",
       source: __MODULE__,
       details: %{max_turns: max_turns}
     )}
  end

  defp validate_boolean(value, _field) when is_boolean(value), do: :ok

  defp validate_boolean(value, field) do
    {:error,
     Error.validation("#{field} must be a boolean",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_atom(value, _field) when is_atom(value), do: :ok

  defp validate_atom(value, field) do
    {:error,
     Error.validation("#{field} must be an atom",
       source: __MODULE__,
       details: %{field: field, value: value}
     )}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: :ok

  defp validate_metadata(metadata) do
    {:error,
     Error.validation("metadata must be a map",
       source: __MODULE__,
       details: %{metadata: metadata}
     )}
  end

  defp get(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
