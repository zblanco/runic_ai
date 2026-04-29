defmodule RunicAI.LLM do
  @moduledoc """
  Behaviour and facade for LLM interactions.

  The canonical text-generation path is:

      RunicAI.LLM.Request -> RunicAI.LLM.Result

  Convenience wrappers remain available for ergonomic direct use.

  All public functions accept an optional `:client` in the opts keyword list.
  The client can be:

  - **A module** implementing the `RunicAI.LLM` behaviour
  - **A function** matching the called function's arity

  When no `:client` is provided, defaults to `RunicAI.LLM.ReqLLMClient`
  which delegates to ReqLLM.

  ## Examples

      # Default — uses ReqLLM
      RunicAI.LLM.generate_text("anthropic:claude-haiku-4-5", "Hello")

      # Module-based client
      RunicAI.LLM.generate_text("anthropic:claude-haiku-4-5", "Hello", client: MyClient)

      # Function-based client (useful for tests)
      RunicAI.LLM.generate_text("model", "Hello",
        client: fn _model, _prompt, _opts -> {:ok, response} end
      )

  """

  @type model :: String.t() | {atom(), String.t()} | map()
  alias RunicAI.Error
  alias RunicAI.LLM.Request
  alias RunicAI.LLM.Result
  alias RunicAI.Prompt

  @type prompt :: String.t() | Prompt.t()
  @type options :: keyword()
  @type schema :: keyword() | map() | struct()

  @callback generate_text(model(), prompt(), options()) ::
              {:ok, Result.t() | ReqLLM.Response.t()} | {:error, Error.t() | term()}

  @callback stream_text(model(), prompt(), options()) ::
              {:ok, ReqLLM.StreamResponse.t()} | {:error, Error.t() | term()}

  @callback generate_object(model(), prompt(), schema(), options()) ::
              {:ok, map()} | {:error, Error.t() | term()}

  @default_client RunicAI.LLM.ReqLLMClient

  @doc """
  Generate text from a normalized request.
  """
  @spec generate_text(Request.t()) ::
          {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()}
  def generate_text(%Request{} = request) do
    with {:ok, request} <- Request.validate(request) do
      {client, client_opts} = Keyword.pop(request.opts, :client, @default_client)

      client
      |> dispatch(:generate_text, [request.model, request.prompt, client_opts])
      |> normalize_text_outcome(client)
    end
  end

  @doc """
  Generate text from convenience arguments.

  Accepts `:client` in opts — a module or `fn(model, prompt, opts)`.
  """
  @spec generate_text(model(), prompt(), options()) ::
          {:ok, Result.t()} | {:retry, Error.t()} | {:error, Error.t()}
  def generate_text(model, prompt, opts \\ []) do
    with {:ok, request} <- Request.new(model, prompt, opts) do
      generate_text(request)
    end
  end

  @doc """
  Stream text from an LLM.

  Accepts `:client` in opts — a module or `fn(model, prompt, opts)`.
  """
  @spec stream_text(model(), prompt(), options()) ::
          {:ok, ReqLLM.StreamResponse.t()} | {:error, Error.t()}
  def stream_text(model, prompt, opts \\ []) do
    {client, opts} = Keyword.pop(opts, :client, @default_client)

    client
    |> dispatch(:stream_text, [model, prompt, opts])
    |> normalize_passthrough_outcome(client, "stream_text")
  end

  @doc """
  Generate a structured object from an LLM.

  Accepts `:client` in opts — a module or `fn(model, prompt, schema, opts)`.
  """
  @spec generate_object(model(), prompt(), schema(), options()) ::
          {:ok, map()} | {:error, Error.t()}
  def generate_object(model, prompt, schema, opts \\ []) do
    {client, opts} = Keyword.pop(opts, :client, @default_client)

    client
    |> dispatch(:generate_object, [model, prompt, schema, opts])
    |> normalize_object_outcome(client)
  end

  defp dispatch(client, func, args) when is_atom(client) do
    apply(client, func, args)
  end

  defp dispatch(client, _func, args) when is_function(client) do
    apply(client, args)
  end

  defp normalize_text_outcome({:ok, %Result{} = result}, _client), do: {:ok, result}

  defp normalize_text_outcome({:ok, %ReqLLM.Response{} = response}, _client) do
    Result.from_req_llm_response(response)
  end

  defp normalize_text_outcome({:error, %Error{retryable?: true} = error}, _client),
    do: {:retry, error}

  defp normalize_text_outcome({:error, %Error{} = error}, _client), do: {:error, error}

  defp normalize_text_outcome({:error, reason}, client) do
    {:error, Error.from_reason(reason, kind: :provider, source: client_source(client))}
  end

  defp normalize_text_outcome(other, client) do
    {:error,
     Error.from_reason(other,
       kind: :unexpected,
       message: "unexpected LLM client outcome",
       source: client_source(client)
     )}
  end

  defp normalize_object_outcome({:ok, value}, _client)
       when is_map(value) and not is_struct(value),
       do: {:ok, value}

  defp normalize_object_outcome({:ok, %ReqLLM.Response{object: value}}, _client)
       when is_map(value),
       do: {:ok, value}

  defp normalize_object_outcome({:ok, value}, client) do
    {:error,
     Error.from_reason(value,
       kind: :unexpected,
       message: "unexpected generate_object client outcome",
       source: client_source(client)
     )}
  end

  defp normalize_object_outcome({:error, %Error{} = error}, _client),
    do: {:error, error}

  defp normalize_object_outcome({:error, reason}, client) do
    {:error,
     Error.from_reason(reason,
       kind: :provider,
       message: "generate_object failed",
       source: client_source(client)
     )}
  end

  defp normalize_passthrough_outcome({:ok, value}, _client, _operation), do: {:ok, value}

  defp normalize_passthrough_outcome({:error, %Error{} = error}, _client, _operation),
    do: {:error, error}

  defp normalize_passthrough_outcome({:error, reason}, client, operation) do
    {:error,
     Error.from_reason(reason,
       kind: :provider,
       message: "#{operation} failed",
       source: client_source(client)
     )}
  end

  defp normalize_passthrough_outcome(other, client, operation) do
    {:error,
     Error.from_reason(other,
       kind: :unexpected,
       message: "unexpected #{operation} client outcome",
       source: client_source(client)
     )}
  end

  defp client_source(client) when is_atom(client), do: client
  defp client_source(client) when is_function(client), do: :function_client
end
