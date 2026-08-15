defmodule RunicAI.Tool.Binding do
  @moduledoc "Host-owned executable binding for an inert tool specification."

  alias RunicAI.Tool.Spec

  @enforce_keys [:spec, :executor]
  defstruct spec: nil, executor: nil, authorize: nil, metadata: %{}

  @type executor :: (map(), map() -> term()) | {module(), atom(), [term()]} | module()
  @type t :: %__MODULE__{
          spec: Spec.t(),
          executor: executor(),
          authorize: function() | nil,
          metadata: map()
        }

  def new(%Spec{} = spec, executor, opts \\ []) do
    binding = %__MODULE__{
      spec: spec,
      executor: executor,
      authorize: Keyword.get(opts, :authorize),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    cond do
      not executable?(executor) ->
        {:error, :invalid_executor}

      not is_nil(binding.authorize) and not is_function(binding.authorize, 2) ->
        {:error, :invalid_authorizer}

      true ->
        {:ok, binding}
    end
  end

  def new!(spec, executor, opts \\ []) do
    case new(spec, executor, opts) do
      {:ok, binding} -> binding
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  defp executable?(fun) when is_function(fun, 2), do: true

  defp executable?({module, function, extra})
       when is_atom(module) and is_atom(function) and is_list(extra), do: true

  defp executable?(module) when is_atom(module), do: function_exported?(module, :execute, 2)
  defp executable?(_other), do: false
end
