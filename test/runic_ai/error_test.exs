defmodule RunicAI.ErrorTest do
  use ExUnit.Case, async: true

  alias RunicAI.Error

  test "safe errors round trip through their owned wire contract" do
    error =
      Error.provider("provider unavailable",
        code: "rate_limited",
        retryable: true,
        details: %{status: 429},
        source: "adapter"
      )

    encoded = Error.encode(error)

    assert {:ok, ^error} = encoded |> Jason.encode!() |> Jason.decode!() |> Error.decode()
    assert encoded["retryable"]
  end

  test "exception structs, stack traces, and secret-bearing messages are not encoded" do
    exception = RuntimeError.exception("secret-token-123")
    error = Error.from_exception(exception, source: "test")
    json = error |> Error.encode() |> Jason.encode!()

    refute json =~ "secret-token-123"
    refute json =~ "stacktrace"
    assert json =~ "RuntimeError"
  end
end
