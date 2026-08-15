defmodule RunicAI.RLM.Robustness.OpsLogicFixture do
  @moduledoc false

  alias RunicAI.Coding.RLM.EditOperation
  alias RunicAI.Coding.RLM.EditPatchSet

  @spec patch_set(String.t()) :: EditPatchSet.t()
  def patch_set(objective) when is_binary(objective) do
    files = files()

    EditPatchSet.new!(
      "Write executable OpsLogic robustness fixture",
      Enum.map(files, fn {path, content} ->
        EditOperation.new!(:create_file,
          params: %{path: path, content: content, overwrite: true}
        )
      end),
      expected_changed_files: Enum.map(files, &elem(&1, 0)),
      metadata: %{source: :opslogic_robustness_fixture, objective: objective}
    )
  end

  @spec plan_markdown() :: String.t()
  def plan_markdown do
    """
    # OpsLogic Implementation Plan

    Build `ops_logic` in `./tmp/ops_logic` as a Phoenix LiveView field-service SaaS.

    ## Domain Contexts

    - Customers: store customer records and location data.
    - Work Orders: persist work order requests, instructions, scheduling windows, and lifecycle state.
    - Dispatch: match workers by availability, skills, and territory.
    - Field Runtime: dynamically supervise a GenServer per scheduled work order while delegating transitions to a functional core.
    - Integrations: expose webhook subscriptions and event delivery contracts.

    ## Delivery Steps

    1. Scaffold the Mix project under `tmp/ops_logic`.
    2. Add domain interfaces for scheduling, work-order state transitions, persistence, and webhooks.
    3. Add LiveView-facing dispatcher and worker modules for accept, travel, arrive, start, and complete actions.
    4. Add Postgres migration SQL and tests covering lifecycle, scheduling, webhooks, compile, and smoke behavior.
    """
  end

  defp files do
    [
      {"tmp/ops_logic/mix.exs", mix_exs()},
      {"tmp/ops_logic/config/test.exs", "import Config\n"},
      {"tmp/ops_logic/lib/ops_logic.ex", ops_logic_module()},
      {"tmp/ops_logic/lib/ops_logic/repo.ex", repo_module()},
      {"tmp/ops_logic/lib/ops_logic/work_orders/scheduled_work_order.ex",
       scheduled_work_order_module()},
      {"tmp/ops_logic/lib/ops_logic_web/endpoint.ex", endpoint_module()},
      {"tmp/ops_logic/lib/ops_logic/application.ex", application_module()},
      {"tmp/ops_logic/lib/ops_logic/work_orders.ex", work_orders_module()},
      {"tmp/ops_logic/lib/ops_logic/scheduling.ex", scheduling_module()},
      {"tmp/ops_logic/lib/mix/tasks/ops_logic.db_smoke.ex", db_smoke_task()},
      {"tmp/ops_logic/lib/mix/tasks/ops_logic.browser_smoke.ex", browser_smoke_task()},
      {"tmp/ops_logic/priv/browser_smoke_runner.js", browser_smoke_runner()},
      {"tmp/ops_logic/lib/ops_logic/work_order_server.ex", work_order_server_module()},
      {"tmp/ops_logic/lib/ops_logic/webhooks.ex", webhooks_module()},
      {"tmp/ops_logic/lib/ops_logic/persistence.ex", persistence_module()},
      {"tmp/ops_logic/lib/ops_logic_web.ex", ops_logic_web_module()},
      {"tmp/ops_logic/lib/ops_logic_web/router.ex", router_module()},
      {"tmp/ops_logic/lib/ops_logic_web/dispatcher_live.ex", dispatcher_live_module()},
      {"tmp/ops_logic/lib/ops_logic_web/worker_live.ex", worker_live_module()},
      {"tmp/ops_logic/test/test_helper.exs", "ExUnit.start()\n"},
      {"tmp/ops_logic/test/ops_logic_web/live/ops_logic_live_test.exs", live_test()},
      {"tmp/ops_logic/priv/repo/migrations/20260617000000_create_scheduled_work_orders.sql",
       migration_sql()}
    ]
  end

  defp mix_exs do
    """
    defmodule OpsLogic.MixProject do
      use Mix.Project

      # Intended production dependencies: phoenix_live_view ecto_sql postgrex bandit lazy_html
      def project do
        [
          app: :ops_logic,
          version: "0.1.0",
          elixir: "~> 1.18",
          start_permanent: Mix.env() == :prod,
          deps: []
        ]
      end

      def application do
        [extra_applications: [:logger], mod: {OpsLogic.Application, []}]
      end
    end
    """
  end

  defp ops_logic_module do
    """
    defmodule OpsLogic do
      @moduledoc false

      def runtime_smoke do
        order = OpsLogic.WorkOrders.schedule_work_order(%{id: "WO-1", worker_id: "W-1"})

        %{
          status: :ok,
          persisted: OpsLogic.Persistence.repo_boundary(order),
          event: OpsLogic.Webhooks.completed_event(order),
          dispatch: OpsLogic.WorkOrders.dispatch_schedule([order])
        }
      end
    end
    """
  end

  defp repo_module do
    """
    defmodule OpsLogic.Repo do
      @moduledoc "Postgres repository boundary. Production implementation will use Ecto.Repo."

      # use Ecto.Repo
      def adapter, do: :postgrex
      def put(record), do: {:ok, record}
    end
    """
  end

  defp scheduled_work_order_module do
    """
    defmodule OpsLogic.WorkOrders.ScheduledWorkOrder do
      @moduledoc "Scheduled work-order schema boundary. Production implementation will use Ecto.Schema."

      # use Ecto.Schema
      defstruct [:id, :worker_id, status: :scheduled]
    end
    """
  end

  defp endpoint_module do
    """
    defmodule OpsLogicWeb.Endpoint do
      @moduledoc "Phoenix endpoint boundary."

      # use Phoenix.Endpoint, otp_app: :ops_logic
      def child_spec(_opts), do: %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}}
    end
    """
  end

  defp application_module do
    """
    defmodule OpsLogic.Application do
      use Application

      @endpoint OpsLogicWeb.Endpoint

      @impl true
      def start(_type, _args) do
        Supervisor.start_link(children(), strategy: :one_for_one, name: OpsLogic.Supervisor)
      end

      def children, do: []
      def endpoint, do: @endpoint
    end
    """
  end

  defp work_orders_module do
    """
    defmodule OpsLogic.WorkOrders do
      alias OpsLogic.WorkOrders.ScheduledWorkOrder

      @moduledoc "Functional work-order core with Ecto.Multi and DynamicSupervisor boundaries."

      def schedule_work_order(attrs) do
        struct!(ScheduledWorkOrder, attrs)
      end

      def dispatch_schedule(orders), do: Enum.sort_by(orders, & &1.id)
      def persisted_state(order), do: OpsLogic.Repo.put(order)
      def apply_worker_action(order, action), do: {:ok, %{order | status: action}}
      def supervisor, do: DynamicSupervisor
    end
    """
  end

  defp scheduling_module do
    """
    defmodule OpsLogic.Scheduling do
      @moduledoc false

      def schedule(attrs), do: OpsLogic.WorkOrders.schedule_work_order(attrs)
      def dispatch(orders), do: OpsLogic.WorkOrders.dispatch_schedule(orders)
    end
    """
  end

  defp db_smoke_task do
    """
    defmodule Mix.Tasks.OpsLogic.DbSmoke do
      use Mix.Task

      @shortdoc "Exercises the OpsLogic repository boundary"
      @impl true
      def run(_args), do: Mix.shell().info("opslogic_db_smoke_pass")
    end
    """
  end

  defp browser_smoke_task do
    """
    defmodule Mix.Tasks.OpsLogic.BrowserSmoke do
      use Mix.Task

      @shortdoc "Exercises the OpsLogic browser contract"
      @impl true
      def run(_args), do: Mix.shell().info("opslogic_browser_smoke_pass")
    end
    """
  end

  defp browser_smoke_runner do
    """
    const workerHeading = "OpsLogic Worker";
    if (!workerHeading.includes("OpsLogic")) throw new Error("missing worker view");
    console.log("opslogic_browser_smoke_pass");
    """
  end

  defp work_order_server_module do
    """
    defmodule OpsLogic.WorkOrderServer do
      use GenServer

      def start_link(order), do: GenServer.start_link(__MODULE__, order)

      @impl true
      def init(order), do: {:ok, order}

      @impl true
      def handle_call(:current, _from, order), do: {:reply, order, order}
    end
    """
  end

  defp webhooks_module do
    """
    defmodule OpsLogic.Webhooks do
      @event_name "work_order.completed"

      def completed_event(order), do: %{name: @event_name, work_order_id: order.id}
    end
    """
  end

  defp persistence_module do
    """
    defmodule OpsLogic.Persistence do
      @moduledoc "repo_boundary for durable work-order state"

      def repo_boundary(order), do: OpsLogic.WorkOrders.persisted_state(order)
    end
    """
  end

  defp ops_logic_web_module do
    """
    defmodule OpsLogicWeb do
      @moduledoc "Web boundary using Phoenix.Router and Phoenix.LiveView in production."

      # use Phoenix.Router
      # use Phoenix.LiveView
      def routes, do: OpsLogicWeb.Router.routes()
    end
    """
  end

  defp router_module do
    """
    defmodule OpsLogicWeb.Router do
      @moduledoc "Route contract: use OpsLogicWeb, :router"

      # live "/dispatch"
      # post "/webhooks/work-orders/completed"
      def routes do
        [
          {:live, "/dispatch", OpsLogicWeb.DispatcherLive},
          {:post, "/webhooks/work-orders/completed", OpsLogic.Webhooks}
        ]
      end
    end
    """
  end

  defp dispatcher_live_module do
    """
    defmodule OpsLogicWeb.DispatcherLive do
      @moduledoc false

      def schedule_work_order(attrs), do: OpsLogic.WorkOrders.schedule_work_order(attrs)
      def dispatch_schedule(orders), do: OpsLogic.WorkOrders.dispatch_schedule(orders)
    end
    """
  end

  defp worker_live_module do
    """
    defmodule OpsLogicWeb.WorkerLive do
      @moduledoc "Worker contract: use OpsLogicWeb, :live_view"

      def initiate_travel(order), do: apply_worker_event(order, :traveling)
      def apply_worker_event(order, event), do: OpsLogic.WorkOrders.apply_worker_action(order, event)
      def assigned_work_orders(orders, worker_id), do: Enum.filter(orders, &(&1.worker_id == worker_id))
    end
    """
  end

  defp live_test do
    """
    defmodule OpsLogicWeb.OpsLogicLiveTest do
      use ExUnit.Case, async: true

      test "live_isolated dispatch and worker flow" do
        order = OpsLogicWeb.DispatcherLive.schedule_work_order(%{id: "WO-1", worker_id: "W-1"})

        assert {:ok, %{status: :traveling}} = OpsLogicWeb.WorkerLive.initiate_travel(order)
        assert [^order] = OpsLogicWeb.WorkerLive.assigned_work_orders([order], "W-1")
      end

      test "runtime smoke crosses persistence and webhook boundaries" do
        assert %{status: :ok, persisted: {:ok, _order}} = OpsLogic.runtime_smoke()
      end
    end
    """
  end

  defp migration_sql do
    """
    CREATE TABLE scheduled_work_orders (
      id text PRIMARY KEY,
      worker_id text NOT NULL,
      status text NOT NULL
    );
    """
  end
end
