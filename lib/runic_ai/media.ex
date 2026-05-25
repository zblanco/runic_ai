defmodule RunicAI.Media do
  @moduledoc """
  Thin media facade over ReqLLM media APIs.

  Tests and offline workflows can pass a function or module client. Production
  defaults delegate to ReqLLM for image generation, speech, transcription, OCR,
  and multimodal vision prompts.
  """

  alias RunicAI.Error

  @type options :: keyword()

  @callback generate_image(term(), String.t(), options()) :: {:ok, term()} | {:error, term()}
  @callback speak(term(), String.t(), options()) :: {:ok, term()} | {:error, term()}
  @callback transcribe(term(), term(), options()) :: {:ok, term()} | {:error, term()}
  @callback ocr(term(), binary(), options()) :: {:ok, term()} | {:error, term()}
  @callback vision_analyze(term(), map(), options()) :: {:ok, term()} | {:error, term()}

  @spec generate_image(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def generate_image(prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    model = Keyword.get(opts, :model, "openai:gpt-image-1")

    opts
    |> dispatch(:generate_image, [model, prompt, request_opts(opts)])
    |> normalize_media_result(:image)
  end

  @spec speak(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def speak(text, opts \\ []) when is_binary(text) and is_list(opts) do
    model = Keyword.get(opts, :model, "openai:tts-1")

    opts
    |> dispatch(:speak, [model, text, request_opts(opts)])
    |> normalize_media_result(:speech)
  end

  @spec transcribe(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def transcribe(audio, opts \\ []) when is_list(opts) do
    model = Keyword.get(opts, :model, "openai:whisper-1")

    opts
    |> dispatch(:transcribe, [model, audio, request_opts(opts)])
    |> normalize_media_result(:transcription)
  end

  @spec ocr(binary(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def ocr(document, opts \\ []) when is_binary(document) and is_list(opts) do
    model = Keyword.get(opts, :model, %{provider: :google_vertex, id: "mistral-ocr-2505"})

    opts
    |> dispatch(:ocr, [model, document, request_opts(opts)])
    |> normalize_media_result(:ocr)
  end

  @spec vision_analyze(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def vision_analyze(input, opts \\ []) when is_map(input) and is_list(opts) do
    model = Keyword.get(opts, :model, "openai:gpt-4o-mini")

    opts
    |> dispatch(:vision_analyze, [model, input, request_opts(opts)])
    |> normalize_media_result(:vision)
  end

  defp dispatch(opts, operation, args) do
    case Keyword.get(opts, :client) do
      nil ->
        default_dispatch(operation, args)

      client when is_atom(client) ->
        apply(client, operation, args)

      client when is_function(client, 4) ->
        apply(client, [operation | args])

      client when is_function(client, 3) ->
        apply(client, args)

      client ->
        {:error,
         Error.validation("media client must be a module or function",
           source: __MODULE__,
           details: %{client: inspect(client)}
         )}
    end
  rescue
    exception -> {:error, Error.from_exception(exception, source: __MODULE__)}
  end

  defp default_dispatch(:generate_image, [model, prompt, opts]),
    do: ReqLLM.generate_image(model, prompt, opts)

  defp default_dispatch(:speak, [model, text, opts]), do: ReqLLM.speak(model, text, opts)

  defp default_dispatch(:transcribe, [model, audio, opts]),
    do: ReqLLM.transcribe(model, audio, opts)

  defp default_dispatch(:ocr, [model, document, opts]), do: ReqLLM.ocr(model, document, opts)

  defp default_dispatch(:vision_analyze, [model, input, opts]) do
    prompt = Map.get(input, :prompt, Map.get(input, "prompt", "Analyze this image."))
    image = Map.get(input, :image, Map.get(input, "image"))
    image_url = Map.get(input, :image_url, Map.get(input, "image_url"))
    media_type = Map.get(input, :media_type, Map.get(input, "media_type", "image/png"))

    parts =
      cond do
        is_binary(image) ->
          [
            ReqLLM.Message.ContentPart.text(prompt),
            ReqLLM.Message.ContentPart.image(image, media_type)
          ]

        is_binary(image_url) ->
          [
            ReqLLM.Message.ContentPart.text(prompt),
            ReqLLM.Message.ContentPart.image_url(image_url)
          ]

        true ->
          [ReqLLM.Message.ContentPart.text(prompt)]
      end

    context = ReqLLM.Context.new([ReqLLM.Context.build(:user, parts)])
    ReqLLM.generate_text(model, context, opts)
  end

  defp request_opts(opts) do
    opts
    |> Keyword.drop([:client, :model])
  end

  defp normalize_media_result({:ok, result}, kind), do: {:ok, media_result(kind, result)}
  defp normalize_media_result({:error, %Error{} = error}, _kind), do: {:error, error}

  defp normalize_media_result({:error, reason}, _kind),
    do: {:error, Error.from_reason(reason, source: __MODULE__)}

  defp normalize_media_result(result, kind), do: {:ok, media_result(kind, result)}

  defp media_result(:image, %ReqLLM.Response{} = response) do
    %{
      kind: :image,
      text: ReqLLM.Response.text(response),
      image: ReqLLM.Response.image_data(response),
      image_url: ReqLLM.Response.image_url(response),
      usage: response.usage
    }
  end

  defp media_result(:speech, %{audio: audio, media_type: media_type, format: format}) do
    %{kind: :speech, audio: audio, media_type: media_type, format: format}
  end

  defp media_result(:transcription, result) when is_map(result) do
    %{
      kind: :transcription,
      text: Map.get(result, :text, Map.get(result, "text")),
      language: Map.get(result, :language, Map.get(result, "language")),
      duration_in_seconds:
        Map.get(result, :duration_in_seconds, Map.get(result, "duration_in_seconds")),
      segments: Map.get(result, :segments, Map.get(result, "segments", []))
    }
  end

  defp media_result(:ocr, result) when is_map(result) do
    %{
      kind: :ocr,
      markdown: Map.get(result, :markdown, Map.get(result, "markdown")),
      pages: Map.get(result, :pages, Map.get(result, "pages", []))
    }
  end

  defp media_result(:vision, %ReqLLM.Response{} = response) do
    %{kind: :vision, text: ReqLLM.Response.text(response), usage: response.usage}
  end

  defp media_result(kind, result) when is_map(result), do: Map.put_new(result, :kind, kind)
  defp media_result(kind, result) when is_binary(result), do: %{kind: kind, text: result}
  defp media_result(kind, result), do: %{kind: kind, result: result}
end
