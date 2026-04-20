defmodule RunicAI.Decomposition.Callable do
  @moduledoc false

  alias RunicAI.Error

  @type t ::
          (term() -> term())
          | {module(), atom()}
          | {module(), atom(), list()}

  @spec validate(t() | nil, String.t(), module()) :: :ok | {:error, Error.t()}
  def validate(nil, label, source) when is_binary(label) do
    {:error,
     Error.validation("#{label} must be a function or MFA, got: nil",
       source: source,
       details: %{label: label}
     )}
  end

  def validate(callable, _label, _source) when is_function(callable, 1), do: :ok

  def validate({module, function}, _label, _source)
      when is_atom(module) and is_atom(function),
      do: :ok

  def validate({module, function, extra_args}, _label, _source)
      when is_atom(module) and is_atom(function) and is_list(extra_args),
      do: :ok

  def validate(callable, label, source) when is_binary(label) do
    {:error,
     Error.validation("#{label} must be a function or MFA",
       source: source,
       details: %{label: label, callable: callable}
     )}
  end

  @spec invoke(t(), term()) :: term()
  def invoke(callable, input)

  def invoke(callable, input) when is_function(callable, 1), do: callable.(input)

  def invoke({module, function}, input) do
    apply(module, function, [input])
  end

  def invoke({module, function, extra_args}, input) do
    apply(module, function, [input | extra_args])
  end
end
