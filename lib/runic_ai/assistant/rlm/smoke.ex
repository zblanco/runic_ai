defmodule RunicAI.Assistant.RLM.Smoke do
  @moduledoc """
  Manual smoke scenario catalog for dynamic assistant workflow generation.
  """

  @spec scenarios() :: [map()]
  def scenarios do
    [
      %{
        id: :long_document_wiki,
        capability_pressure: [:source_splitting, :llm_map, :artifact_write]
      },
      %{
        id: :meeting_actions,
        capability_pressure: [:speaker_chunking, :dedupe, :structured_report]
      },
      %{
        id: :research_brief,
        capability_pressure: [:section_splitting, :claim_evidence, :glossary]
      },
      %{id: :ticket_clusters, capability_pressure: [:semi_structured_input, :grouping, :ranking]},
      %{id: :notes_digest, capability_pressure: [:multi_file_sources, :cross_file_dedupe]},
      %{
        id: :architecture_report,
        capability_pressure: [:repo_exploration, :citations, :docs_write]
      },
      %{id: :csv_cleanup, capability_pressure: [:parsing, :tier1_transforms, :uncertainty]},
      %{id: :document_comparison, capability_pressure: [:paired_sources, :change_classification]}
    ]
  end
end
