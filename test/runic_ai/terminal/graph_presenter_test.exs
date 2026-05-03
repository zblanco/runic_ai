defmodule RunicAI.Terminal.GraphPresenterTest do
  use ExUnit.Case, async: true

  alias RunicAI.Terminal.GraphPresenter

  test "renders dependency graphs as adjacency text by default" do
    rendered =
      GraphPresenter.adjacency_text(%{
        objective: "Explain Demo",
        nodes: [
          %{id: "inspect", kind: :tool, dependencies: []},
          %{id: "answer", kind: :reducer, dependencies: ["inspect"]}
        ]
      })

    assert rendered =~ "objective: Explain Demo"
    assert rendered =~ "[inspect] tool <- root"
    assert rendered =~ "[answer] reducer <- inspect"
  end

  test "generates deterministic Mermaid source" do
    mermaid =
      GraphPresenter.to_mermaid(%{
        nodes: [
          %{id: "inspect", kind: :tool, dependencies: []},
          %{id: "answer", kind: :reducer, dependencies: ["inspect"]}
        ]
      })

    assert mermaid == """
           flowchart TD
             n1["inspect\\n(tool)"]
             n2["answer\\n(reducer)"]
             n1 --> n2\
           """
  end

  test "uses Runic serializer output for Mermaid graph rendering" do
    rendered =
      GraphPresenter.render(
        %{
          graph_summary: %{
            runic: %{
              native_nodes: [%{name: "assistant_input", kind: :input}],
              serializers: %{mermaid: "flowchart LR\n  A --> B"}
            }
          }
        },
        mode: :mermaid
      )

    assert rendered.status == :ok
    assert rendered.output == "flowchart LR\n  A --> B"
  end

  test "renders Runic native runtime nodes as adjacency text" do
    rendered =
      GraphPresenter.adjacency_text(%{
        runic: %{
          native_nodes: [
            %{id: "input", name: "assistant_input", kind: :input},
            %{id: "map", name: "assistant_node_3_map", kind: :map}
          ],
          edgelist: [%{from: "assistant_input", to: "assistant_node_3_map"}]
        }
      })

    assert rendered =~ "[assistant_input] input <- root"
    assert rendered =~ "[assistant_node_3_map] map <- assistant_input"
  end

  test "mmdflux mode degrades to a graph warning when the binary is unavailable" do
    result =
      GraphPresenter.render(
        %{nodes: [%{id: "a", kind: :tool, dependencies: []}]},
        mode: :mmdflux
      )

    assert result.status in [:pass, :blocked]

    if result.status == :blocked do
      assert result.warning =~ "mmdflux executable"
      assert result.output =~ "flowchart TD"
    end
  end
end
