defmodule RunicAI.RLM.Robustness.WorkspaceFactory do
  @moduledoc """
  Creates isolated Mix workspaces for robustness project scenarios.
  """

  alias RunicAI.Error
  alias RunicAI.RLM.Robustness.ProjectScenario

  @spec create(ProjectScenario.t(), atom(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create(%ProjectScenario{} = scenario, lane, opts \\ [])
      when is_atom(lane) and is_list(opts) do
    root =
      opts
      |> Keyword.get(:root, default_root(scenario, lane, opts))
      |> Path.expand()

    with :ok <- prepare_root(root),
         :ok <- write_mix_project(root, scenario),
         :ok <- maybe_seed_existing(root, scenario) do
      {:ok,
       %{
         root: root,
         app: app_name(scenario),
         module: module_name(scenario),
         scenario_id: scenario.id,
         lane: lane,
         created_at: DateTime.utc_now()
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.from_reason(reason, source: __MODULE__, message: "workspace setup failed")}
    end
  end

  defp default_root(%ProjectScenario{} = scenario, lane, opts) do
    base = Keyword.get(opts, :base_dir, Path.join(File.cwd!(), "tmp/rlm_robustness/workspaces"))
    label = Keyword.get(opts, :run_label, timestamp_label())
    Path.join([base, label, safe_name(scenario.id), Atom.to_string(lane)])
  end

  defp prepare_root(root) do
    if String.contains?(Path.expand(root), "/tmp/rlm_robustness/") do
      File.rm_rf!(root)
      File.mkdir_p!(root)
      :ok
    else
      {:error,
       Error.validation("refusing to create robustness workspace outside tmp/rlm_robustness",
         source: __MODULE__,
         details: %{root: root}
       )}
    end
  end

  defp write_mix_project(root, %ProjectScenario{} = scenario) do
    app = app_name(scenario)
    module = module_name(scenario)

    files = %{
      "mix.exs" => mix_exs(app, module),
      "lib/#{app}.ex" => scaffold_module(module),
      "test/test_helper.exs" => "ExUnit.start()\n",
      "test/#{app}_test.exs" => scaffold_test(module)
    }

    Enum.each(files, fn {path, content} ->
      absolute = Path.join(root, path)
      File.mkdir_p!(Path.dirname(absolute))
      File.write!(absolute, content)
    end)

    :ok
  end

  defp maybe_seed_existing(root, %ProjectScenario{workspace_factory: :seeded_mix_project}) do
    File.mkdir_p!(Path.join(root, "lib/existing_app"))

    File.write!(Path.join(root, "lib/existing_app/accounts.ex"), """
    defmodule ExistingApp.Accounts do
      @moduledoc false

      def list_users, do: [%{id: 1, email: "ada@example.test"}]
    end
    """)

    File.write!(Path.join(root, "test/existing_app_accounts_test.exs"), """
    defmodule ExistingApp.AccountsTest do
      use ExUnit.Case, async: true

      test "lists seeded users" do
        assert [%{email: "ada@example.test"}] = ExistingApp.Accounts.list_users()
      end
    end
    """)

    :ok
  end

  defp maybe_seed_existing(root, %ProjectScenario{
         workspace_factory: :broken_field_service_mix_project
       }) do
    File.rm(Path.join(root, "lib/field_service_repair_followup.ex"))
    File.rm(Path.join(root, "test/field_service_repair_followup_test.exs"))

    File.write!(Path.join(root, "lib/field_service_dispatch.ex"), """
    defmodule FieldServiceDispatch do
      @moduledoc false

      def new_work_order(id, required_skill) do
        %{kind: :WorkOrder, id: id, required_skill: required_skill, status: :new}
      end

      def technician(id, skills), do: %{kind: :Technician, id: id, skills: skills}

      def assign(work_order, _technicians), do: {:error, :not_implemented}
      def transition(_work_order, _event), do: {:error, :not_implemented}
    end
    """)

    File.write!(Path.join(root, "test/field_service_dispatch_test.exs"), """
    defmodule FieldServiceDispatchTest do
      use ExUnit.Case, async: true

      test "broken seed documents the expected repair target" do
        order = FieldServiceDispatch.new_work_order("WO-1", :hvac)
        tech = FieldServiceDispatch.technician("T-1", [:hvac])
        assert {:ok, %{technician_id: "T-1"}} = FieldServiceDispatch.assign(order, [tech])
      end
    end
    """)

    :ok
  end

  defp maybe_seed_existing(
         root,
         %ProjectScenario{
           workspace_factory: :internal_repair_mix_project
         } = scenario
       ) do
    remove_generated_scaffold(root, scenario)

    File.write!(Path.join(root, "lib/internal_repair_demo.ex"), """
    defmodule InternalRepairDemo do
      @moduledoc false

      def answer, do: 41
    end
    """)

    File.write!(Path.join(root, "test/internal_repair_demo_test.exs"), """
    defmodule InternalRepairDemoTest do
      use ExUnit.Case, async: true

      test "repair loop fixes behavior and reruns verification" do
        assert InternalRepairDemo.answer() == 42
        assert InternalRepairDemo.repaired?()
      end
    end
    """)

    :ok
  end

  defp maybe_seed_existing(
         root,
         %ProjectScenario{
           workspace_factory: :semantic_repair_mix_project
         } = scenario
       ) do
    remove_generated_scaffold(root, scenario)

    File.write!(Path.join(root, "lib/work_order.ex"), """
    defmodule WorkOrder do
      @moduledoc false

      defstruct [:id, :status]

      def new(id), do: %__MODULE__{id: id, status: :open}
      def complete(order), do: %{order | status: :completed}
    end
    """)

    File.write!(Path.join(root, "test/work_order_test.exs"), """
    defmodule WorkOrderTest do
      use ExUnit.Case, async: true

      test "completes a work order" do
        order = WorkOrder.new("wo-1")
        assert %WorkOrder{status: :completed} = WorkOrder.complete(order)
      end
    end
    """)

    :ok
  end

  defp maybe_seed_existing(
         root,
         %ProjectScenario{
           workspace_factory: :runtime_smoke_repair_mix_project
         } = scenario
       ) do
    remove_generated_scaffold(root, scenario)

    File.write!(Path.join(root, "lib/dispatch_runtime.ex"), """
    defmodule DispatchRuntime do
      @moduledoc false

      def new_work_order(id), do: %{id: id, status: :new}

      def runtime_smoke do
        {:error, :supervision_not_started}
      end
    end
    """)

    File.write!(Path.join(root, "test/dispatch_runtime_test.exs"), """
    defmodule DispatchRuntimeTest do
      use ExUnit.Case, async: true

      test "creates a work order" do
        assert %{status: :new} = DispatchRuntime.new_work_order("wo-1")
      end
    end
    """)

    :ok
  end

  defp maybe_seed_existing(_root, _scenario), do: :ok

  defp remove_generated_scaffold(root, %ProjectScenario{} = scenario) do
    app = app_name(scenario)

    File.rm(Path.join(root, "lib/#{app}.ex"))
    File.rm(Path.join(root, "test/#{app}_test.exs"))
  end

  defp mix_exs(app, module) do
    """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          elixir: "~> 1.19",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end

      def application do
        [
          extra_applications: [:logger]
        ]
      end
    end
    """
  end

  defp scaffold_module(module) do
    """
    defmodule #{module} do
      @moduledoc false

      def hello, do: :world
    end
    """
  end

  defp scaffold_test(module) do
    """
    defmodule #{module}Test do
      use ExUnit.Case, async: true

      test "greets the world" do
        assert #{module}.hello() == :world
      end
    end
    """
  end

  defp app_name(%ProjectScenario{id: id}), do: safe_name(id)

  defp module_name(%ProjectScenario{id: id}) do
    id
    |> String.split(["_", "-"], trim: true)
    |> Enum.map(&Macro.camelize/1)
    |> Enum.join()
  end

  defp safe_name(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
  end

  defp timestamp_label do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d%H%M%S")
  end
end
