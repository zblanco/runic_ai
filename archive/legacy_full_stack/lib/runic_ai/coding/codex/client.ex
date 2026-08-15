defmodule RunicAI.Coding.Codex.Client do
  @moduledoc """
  `RunicAI.LLM` client adapter backed by local `codex exec --json`.

  This path is opt-in and intended for local, subscription-backed experiments.
  It preserves the standard coding-agent tool policy because the surrounding
  RunicAI agent loop still owns tool selection and execution.
  """

  @behaviour RunicAI.LLM

  alias RunicAI.Agent.ModelClientResolver
  alias RunicAI.Coding.Codex.ExecClient
  alias RunicAI.Coding.Workspace
  alias RunicAI.Error
  alias RunicAI.LLM.Result
  alias RunicAI.Message
  alias RunicAI.Prompt

  @impl true
  def generate_text(model, prompt, opts \\ []) do
    with {:ok, workspace} <- workspace(opts),
         {:ok, text_prompt} <- prompt_text(prompt),
         {:ok, codex_opts} <- maybe_put_model(opts, model),
         {:ok, output} <-
           ExecClient.run(workspace, text_prompt, codex_opts),
         {:ok, text} <- final_text(output.final) do
      {:ok,
       Result.new!(
         Message.new!(:assistant, text),
         finish_reason: :stop,
         raw: output,
         metadata: %{client: :codex_exec}
       )}
    end
  end

  @impl true
  def stream_text(_model, _prompt, _opts \\ []) do
    {:error,
     Error.new(:unsupported, "Codex local bridge does not support stream_text",
       source: __MODULE__
     )}
  end

  @impl true
  def generate_object(_model, _prompt, _schema, _opts \\ []) do
    {:error,
     Error.new(:unsupported, "Codex local bridge does not support generate_object",
       source: __MODULE__
     )}
  end

  defp workspace(opts) do
    cond do
      Keyword.has_key?(opts, :workspace) ->
        Workspace.from_input(Keyword.fetch!(opts, :workspace))

      Keyword.has_key?(opts, :root) ->
        Workspace.from_input(root: Keyword.fetch!(opts, :root))

      true ->
        Workspace.from_input(File.cwd!())
    end
  end

  defp prompt_text(%Prompt{} = prompt) do
    text =
      prompt.messages
      |> Enum.map(fn message -> "#{message.role}: #{Message.text(message)}" end)
      |> Enum.join("\n\n")

    {:ok, text}
  end

  defp prompt_text(prompt) when is_binary(prompt), do: {:ok, prompt}

  defp prompt_text(prompt) do
    {:error,
     Error.validation("Codex prompt must be a binary or RunicAI.Prompt",
       source: __MODULE__,
       details: %{prompt: prompt}
     )}
  end

  defp final_text(%{"message" => value}) when is_binary(value), do: {:ok, value}
  defp final_text(%{"content" => value}) when is_binary(value), do: {:ok, value}
  defp final_text(%{"text" => value}) when is_binary(value), do: {:ok, value}
  defp final_text(%{message: value}) when is_binary(value), do: {:ok, value}
  defp final_text(%{content: value}) when is_binary(value), do: {:ok, value}
  defp final_text(%{text: value}) when is_binary(value), do: {:ok, value}
  defp final_text(value) when is_binary(value), do: {:ok, value}

  defp final_text(value) do
    {:ok, Jason.encode!(value)}
  end

  defp maybe_put_model(opts, model) do
    case ModelClientResolver.normalize_codex_model(model) do
      {:ok, nil, decision} ->
        {:ok,
         opts
         |> Keyword.delete(:model)
         |> Keyword.put_new(:model_resolution, decision)}

      {:ok, model, decision} ->
        {:ok,
         opts
         |> Keyword.put_new(:model, model)
         |> Keyword.put_new(:model_resolution, decision)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end
end
