defmodule RunicAI.Coding.Review do
  @moduledoc """
  Convenience constructors for operator review decisions in coding sessions.

  The underlying RunicAI contract uses `RunicAI.ReviewDecision` statuses:
  `:approved`, `:rejected`, `:edited`, and `:cancelled`. This module names them
  in coding-agent terms: allow, deny, rewrite, and final stop.
  """

  alias RunicAI.ReviewDecision
  alias RunicAI.ReviewRequest

  @spec allow(ReviewRequest.t(), keyword()) :: ReviewDecision.t()
  def allow(%ReviewRequest{} = request, opts \\ []) do
    ReviewDecision.new!(request.resume_key, :approved, opts)
  end

  @spec deny(ReviewRequest.t(), keyword()) :: ReviewDecision.t()
  def deny(%ReviewRequest{} = request, opts \\ []) do
    ReviewDecision.new!(request.resume_key, :rejected, opts)
  end

  @spec rewrite(ReviewRequest.t(), term(), keyword()) :: ReviewDecision.t()
  def rewrite(%ReviewRequest{} = request, replacement, opts \\ []) do
    ReviewDecision.new!(
      request.resume_key,
      :edited,
      Keyword.put(opts, :edited_value, replacement)
    )
  end

  @spec final_stop(ReviewRequest.t(), keyword()) :: ReviewDecision.t()
  def final_stop(%ReviewRequest{} = request, opts \\ []) do
    ReviewDecision.new!(request.resume_key, :cancelled, opts)
  end
end
