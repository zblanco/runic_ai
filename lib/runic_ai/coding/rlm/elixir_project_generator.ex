defmodule RunicAI.Coding.RLM.ElixirProjectGenerator do
  @moduledoc """
  Deterministic parent-owned Elixir prototype generator for bounded RLM project tasks.

  This is not a replacement for child agents. It gives the coordinator a small,
  auditable edit substrate for smoke-sized project-generation objectives so the
  parent workflow can create real source and tests before asking slower child
  agents to refine or repair.
  """

  alias RunicAI.Coding.RLM.EditOperation
  alias RunicAI.Coding.RLM.EditPatchSet
  alias RunicAI.Coding.RLM.ObjectiveContract

  @spec patch_set(String.t(), keyword()) :: EditPatchSet.t()
  def patch_set(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    objective_contract = objective_contract(objective, opts)
    profile = profile(objective, objective_contract)

    case generated_project_spec(objective, profile) do
      nil ->
        profile_patch_set(objective, opts, objective_contract, profile)

      spec ->
        generated_project_patch_set(objective, objective_contract, profile, spec)
    end
  end

  defp profile_patch_set(objective, opts, objective_contract, profile) do
    module = profile.module
    source_path = "lib/#{profile.file}.ex"
    test_path = "test/#{profile.file}_test.exs"
    source_refs = Keyword.get(opts, :sources, [])
    cleanup_paths = scaffold_cleanup_paths(profile, source_refs, [source_path, test_path])
    expected_changed_files = [source_path, test_path] ++ cleanup_paths

    EditPatchSet.new!(
      "Generate #{profile.title} prototype",
      create_operations(source_path, test_path, profile, module, objective) ++
        delete_operations(cleanup_paths),
      expected_changed_files: expected_changed_files,
      target_paths: expected_changed_files,
      metadata: %{
        generator: :elixir_project_generator,
        profile: profile.id,
        objective: objective,
        objective_contract: ObjectiveContract.to_map(objective_contract),
        sources: source_refs,
        cleanup_paths: cleanup_paths
      }
    )
  end

  @spec runtime_smoke_argv(String.t(), keyword()) :: [String.t()]
  def runtime_smoke_argv(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    objective_contract = objective_contract(objective, opts)
    profile = profile(objective, objective_contract)

    ["mix", "run", "-e", runtime_smoke_expr(profile)]
  end

  @spec command_args(String.t(), :compile | :test | :runtime_smoke, keyword()) :: map()
  def command_args(objective, command, opts \\ []) when is_binary(objective) and is_list(opts) do
    objective_contract = objective_contract(objective, opts)
    profile = profile(objective, objective_contract)
    spec = generated_project_spec(objective, profile)

    args =
      case command do
        :compile ->
          %{argv: ["mix", "compile", "--warnings-as-errors"]}

        :test ->
          %{argv: ["mix", "test"]}

        :runtime_smoke ->
          %{argv: ["mix", "run", "-e", runtime_smoke_expr(profile, spec)]}
      end

    case spec do
      nil -> args
      %{root: root} -> Map.put(args, :cwd, root)
    end
  end

  @spec verification_checks(String.t(), keyword()) :: [map()]
  def verification_checks(objective, opts \\ []) when is_binary(objective) and is_list(opts) do
    objective_contract = objective_contract(objective, opts)
    profile = profile(objective, objective_contract)
    spec = generated_project_spec(objective, profile)

    source_glob =
      case spec do
        nil -> "lib/**/*.ex"
        %{root: root} -> Path.join(root, "lib/**/*.ex")
      end

    test_glob =
      case spec do
        nil -> "test/**/*_test.exs"
        %{root: root} -> Path.join(root, "test/**/*_test.exs")
      end

    [
      %{
        id: "project-source-present",
        type: "source_contains",
        params: %{glob: source_glob, text: "defmodule"}
      },
      %{
        id: "scaffold-test-replaced",
        type: "source_not_contains",
        params: %{glob: test_glob, text: "greets the world"}
      },
      %{
        id: "objective-semantic-coverage",
        type: "semantic_requirement",
        params: %{requirement: objective}
      },
      %{
        id: "compile-command-passed",
        type: "command_passes",
        params: command_args(objective, :compile, objective_contract: objective_contract)
      },
      %{
        id: "test-command-passed",
        type: "command_passes",
        params: command_args(objective, :test, objective_contract: objective_contract)
      },
      %{
        id: "runtime-smoke-command-passed",
        type: "command_passes",
        params: command_args(objective, :runtime_smoke, objective_contract: objective_contract)
      }
    ]
  end

  defp create_operations(source_path, test_path, profile, module, objective) do
    [
      EditOperation.new!(:create_file,
        params: %{path: source_path, content: source(profile, objective), overwrite: true}
      ),
      EditOperation.new!(:create_file,
        params: %{path: test_path, content: tests(profile, module), overwrite: true}
      )
    ]
  end

  defp delete_operations(paths) do
    Enum.map(paths, fn path ->
      EditOperation.new!(:delete_file, params: %{path: path})
    end)
  end

  defp generated_project_patch_set(objective, objective_contract, profile, spec) do
    operations = generated_project_operations(spec, profile, objective)
    expected_changed_files = Enum.map(operations, &operation_path!/1)

    EditPatchSet.new!(
      "Generate #{spec.app} project",
      operations,
      expected_changed_files: expected_changed_files,
      target_paths: expected_changed_files,
      metadata: %{
        generator: :elixir_project_generator,
        profile: profile.id,
        objective: objective,
        objective_contract: ObjectiveContract.to_map(objective_contract),
        project_root: spec.root,
        app: spec.app,
        module: spec.module
      }
    )
  end

  defp generated_project_operations(spec, %{id: :field_service}, _objective) do
    [
      file(spec, "mix.exs", mix_exs(spec)),
      file(spec, "config/config.exs", field_service_config(spec)),
      file(spec, "config/test.exs", field_service_test_config(spec)),
      file(spec, "README.md", field_service_readme(spec)),
      file(spec, "lib/#{spec.file}.ex", field_service_facade(spec)),
      file(spec, "lib/#{spec.file}/application.ex", field_service_application(spec)),
      file(spec, "lib/#{spec.file}/repo.ex", field_service_repo(spec)),
      file(spec, "lib/#{spec.file}/customers.ex", field_service_customers(spec)),
      file(spec, "lib/#{spec.file}/workers.ex", field_service_workers(spec)),
      file(spec, "lib/#{spec.file}/scheduling.ex", field_service_scheduling(spec)),
      file(spec, "lib/#{spec.file}/work_orders.ex", field_service_work_orders(spec)),
      file(
        spec,
        "lib/#{spec.file}/work_orders/scheduled_work_order.ex",
        field_service_scheduled_work_order_schema(spec)
      ),
      file(spec, "lib/#{spec.file}/work_order_server.ex", field_service_work_order_server(spec)),
      file(spec, "lib/#{spec.file}/persistence.ex", field_service_persistence(spec)),
      file(spec, "lib/#{spec.file}/webhooks.ex", field_service_webhooks(spec)),
      file(spec, "lib/#{spec.file}_web.ex", field_service_web(spec)),
      file(spec, "lib/#{spec.file}_web/endpoint.ex", field_service_endpoint(spec)),
      file(spec, "lib/#{spec.file}_web/router.ex", field_service_web_router(spec)),
      file(
        spec,
        "lib/#{spec.file}_web/controllers/error_json.ex",
        field_service_error_json(spec)
      ),
      file(
        spec,
        "lib/#{spec.file}_web/webhook_controller.ex",
        field_service_webhook_controller(spec)
      ),
      file(spec, "lib/#{spec.file}_web/dispatcher_live.ex", field_service_dispatcher_live(spec)),
      file(spec, "lib/#{spec.file}_web/worker_live.ex", field_service_worker_live(spec)),
      file(
        spec,
        "priv/repo/migrations/20260524000000_create_#{spec.app}_core.sql",
        field_service_migration(spec)
      ),
      file(spec, "lib/mix/tasks/#{spec.app}.db_smoke.ex", field_service_db_smoke_task(spec)),
      file(
        spec,
        "lib/mix/tasks/#{spec.app}.browser_smoke.ex",
        field_service_browser_smoke_task(spec)
      ),
      file(spec, "priv/browser_smoke_runner.js", field_service_browser_smoke_runner()),
      file(spec, "test/test_helper.exs", "ExUnit.start()\n"),
      file(spec, "test/#{spec.file}/work_orders_test.exs", field_service_tests(spec)),
      file(
        spec,
        "test/#{spec.file}_web/live/ops_logic_live_test.exs",
        field_service_live_tests(spec)
      )
    ]
  end

  defp generated_project_operations(spec, profile, objective) do
    [
      file(spec, "mix.exs", mix_exs(spec)),
      file(spec, "lib/#{spec.file}.ex", source(%{profile | module: spec.module_atom}, objective)),
      file(spec, "test/test_helper.exs", "ExUnit.start()\n"),
      file(
        spec,
        "test/#{spec.file}_test.exs",
        tests(%{profile | module: spec.module_atom}, spec.module_atom)
      )
    ]
  end

  defp file(spec, relative, content) do
    EditOperation.new!(:create_file,
      params: %{path: Path.join(spec.root, relative), content: content, overwrite: true}
    )
  end

  defp operation_path!(%EditOperation{} = operation) do
    Map.fetch!(operation.params, :path)
  end

  defp generated_project_spec(objective, profile) do
    with root when is_binary(root) <- requested_project_root(objective),
         app when is_binary(app) <- requested_app(objective, root) do
      module = app |> Macro.camelize()

      %{
        root: root,
        app: app,
        module: module,
        module_atom: Module.concat([module]),
        file: Macro.underscore(module),
        profile: profile.id
      }
    else
      _other -> nil
    end
  end

  defp requested_project_root(objective) do
    objective
    |> path_candidates()
    |> Enum.map(&project_root_candidate/1)
    |> Enum.uniq()
    |> Enum.find(fn path ->
      String.starts_with?(path, "tmp/") and safe_relative_path?(path)
    end)
  end

  defp project_root_candidate(path) do
    if Path.extname(path) == "" do
      path
    else
      Path.dirname(path)
    end
  end

  defp requested_app(objective, root) do
    cond do
      app = parenthesized_app(objective) ->
        app

      app = backticked_app(objective) ->
        app

      true ->
        root |> Path.basename() |> normalize_app_name()
    end
  end

  defp path_candidates(objective) do
    Regex.scan(~r/(?:\.\/)?tmp\/[a-zA-Z0-9_\/.-]+/, objective)
    |> List.flatten()
    |> Enum.map(&String.trim_trailing(&1, "."))
    |> Enum.map(&String.trim_leading(&1, "./"))
    |> Enum.map(&Path.expand(&1, "."))
    |> Enum.map(&Path.relative_to(&1, File.cwd!()))
  end

  defp parenthesized_app(objective) do
    case Regex.run(~r/\(([a-z][a-z0-9_]+)\)/, objective) do
      [_, app] -> normalize_app_name(app)
      _other -> nil
    end
  end

  defp backticked_app(objective) do
    case Regex.run(~r/`([a-z][a-z0-9_]+)`/, objective) do
      [_, app] -> normalize_app_name(app)
      _other -> nil
    end
  end

  defp normalize_app_name(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> nil
      app -> app
    end
  end

  defp safe_relative_path?(path) do
    Path.type(path) == :relative and ".." not in Path.split(path)
  end

  defp scaffold_cleanup_paths(%{id: :existing_app}, _source_refs, _generated_paths), do: []

  defp scaffold_cleanup_paths(_profile, source_refs, generated_paths) do
    generated = MapSet.new(generated_paths)

    source_refs
    |> Enum.flat_map(&source_ref_path/1)
    |> Enum.filter(&root_scaffold_path?/1)
    |> Enum.reject(&MapSet.member?(generated, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_ref_path("file:" <> path), do: [path]
  defp source_ref_path(_source_ref), do: []

  defp root_scaffold_path?(path) when is_binary(path) do
    case Path.split(path) do
      ["lib", file] -> String.ends_with?(file, ".ex")
      ["test", file] -> String.ends_with?(file, "_test.exs")
      _other -> false
    end
  end

  defp objective_contract(objective, opts) do
    case Keyword.get(opts, :objective_contract) do
      %ObjectiveContract{} = contract ->
        contract

      contract when is_map(contract) or is_list(contract) ->
        case ObjectiveContract.from_input(contract) do
          {:ok, contract} -> contract
          {:error, _error} -> ObjectiveContract.infer!(objective)
        end

      _other ->
        ObjectiveContract.infer!(objective)
    end
  end

  defp profile(objective, %ObjectiveContract{} = contract) do
    case Map.get(
           contract.metadata,
           :generation_profile,
           Map.get(contract.metadata, "generation_profile")
         ) do
      profile when profile in [:existing_app, "existing_app"] -> profile_for(:existing_app)
      profile when profile in [:field_service, "field_service"] -> profile_for(:field_service)
      profile when profile in [:inventory, "inventory"] -> profile_for(:inventory)
      profile when profile in [:billing, "billing"] -> profile_for(:billing)
      profile when profile in [:clinic, "clinic"] -> profile_for(:clinic)
      profile when profile in [:workflow, "workflow"] -> profile_for(:workflow)
      profile when profile in [:audit, "audit"] -> profile_for(:audit)
      _other -> profile(objective)
    end
  end

  defp profile(objective) do
    objective = String.downcase(objective)

    cond do
      contains_any?(objective, ["existing project", "existing app", "feature slice"]) ->
        profile_for(:existing_app)

      contains_any?(objective, ["event-sourced", "event sourced", "audit", "replay"]) ->
        profile_for(:audit)

      contains_any?(objective, [
        "field service",
        "field-service",
        "dispatch",
        "work order",
        "work orders"
      ]) ->
        profile_for(:field_service)

      contains_any?(objective, ["inventory", "warehouse", "sku", "reservation"]) ->
        profile_for(:inventory)

      contains_any?(objective, ["billing", "invoice", "subscription", "proration"]) ->
        profile_for(:billing)

      contains_any?(objective, ["clinic", "appointment", "scheduling", "waitlist"]) ->
        profile_for(:clinic)

      contains_any?(objective, ["workflow", "dag", "retry", "orchestration"]) ->
        profile_for(:workflow)

      true ->
        profile_for(:generic)
    end
  end

  defp profile_for(:existing_app) do
    %{
      id: :existing_app,
      title: "existing app feature slice",
      module: ExistingAppFeature,
      file: "existing_app_feature"
    }
  end

  defp profile_for(:field_service) do
    %{
      id: :field_service,
      title: "field service dispatch",
      module: FieldServiceDispatch,
      file: "field_service_dispatch"
    }
  end

  defp profile_for(:inventory) do
    %{
      id: :inventory,
      title: "inventory allocation",
      module: InventoryAllocation,
      file: "inventory_allocation"
    }
  end

  defp profile_for(:billing) do
    %{
      id: :billing,
      title: "subscription billing",
      module: SubscriptionBilling,
      file: "subscription_billing"
    }
  end

  defp profile_for(:clinic) do
    %{
      id: :clinic,
      title: "clinic scheduling",
      module: ClinicScheduling,
      file: "clinic_scheduling"
    }
  end

  defp profile_for(:workflow) do
    %{
      id: :workflow,
      title: "workflow orchestration",
      module: WorkflowOrchestration,
      file: "workflow_orchestration"
    }
  end

  defp profile_for(:audit) do
    %{
      id: :audit,
      title: "event-sourced audit",
      module: EventSourcedAudit,
      file: "event_sourced_audit"
    }
  end

  defp profile_for(:generic) do
    %{
      id: :generic,
      title: "generated prototype",
      module: GeneratedPrototype,
      file: "generated_prototype"
    }
  end

  defp source(%{id: :field_service, module: module}, _objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      @type work_order :: %{id: term(), status: atom(), required_skill: atom(), kind: :WorkOrder}
      @type technician :: %{id: term(), skills: [atom()], available?: boolean(), kind: :Technician}

      def new_work_order(id, required_skill) do
        %{kind: :WorkOrder, id: id, required_skill: required_skill, status: :new}
      end

      def technician(id, skills, available? \\\\ true) do
        %{kind: :Technician, id: id, skills: skills, available?: available?}
      end

      def assign(%{kind: :WorkOrder, required_skill: skill} = work_order, technicians) do
        case Enum.find(technicians, fn technician ->
               technician.available? and skill in technician.skills
             end) do
          nil -> {:error, :no_available_technician}
          technician -> {:ok, work_order |> Map.put(:technician_id, technician.id) |> Map.put(:status, :assigned)}
        end
      end

      def transition(%{status: :assigned} = work_order, :start), do: {:ok, %{work_order | status: :in_progress}}
      def transition(%{status: :in_progress} = work_order, :complete), do: {:ok, %{work_order | status: :completed}}
      def transition(_work_order, _event), do: {:error, :invalid_transition}

      def runtime_children do
        [
          %{id: #{inspect(module)}.Registry, start: {Registry, :start_link, [[keys: :unique, name: #{inspect(module)}.Registry]]}},
          %{id: #{inspect(module)}.DynamicSupervisor, start: {DynamicSupervisor, :start_link, [[strategy: :one_for_one, name: #{inspect(module)}.DynamicSupervisor]]}}
        ]
      end

      def runtime_smoke do
        order = new_work_order("WO-1", :electrical)
        tech = technician("TECH-1", [:electrical, :hvac])

        with {:ok, assigned} <- assign(order, [tech]),
             {:ok, active} <- transition(assigned, :start),
             {:ok, completed} <- transition(active, :complete) do
          {:ok, completed}
        end
      end
    end
    """
  end

  defp source(%{id: :inventory, module: module}, _objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      def reservation(sku, quantity), do: %{kind: :Reservation, sku: sku, quantity: quantity}
      def movement(sku, quantity, reason), do: %{kind: :Movement, sku: sku, quantity: quantity, reason: reason}

      def reserve(stock, sku, quantity) when quantity > 0 do
        available = Map.get(stock, sku, 0)

        if available >= quantity do
          {:ok, Map.put(stock, sku, available - quantity), reservation(sku, quantity)}
        else
          {:error, :insufficient_stock}
        end
      end

      def record_movement(stock, %{kind: :Movement, sku: sku, quantity: quantity}) do
        Map.update(stock, sku, quantity, &(&1 + quantity))
      end

      def reorder_decisions(stock, thresholds) do
        for {sku, threshold} <- thresholds, Map.get(stock, sku, 0) <= threshold do
          %{sku: sku, action: :reorder}
        end
      end

      def audit_allocation(stock, sku, quantity) do
        case reserve(stock, sku, quantity) do
          {:ok, next, decision} -> %{status: :allocated, stock: next, decision: decision}
          {:error, reason} -> %{status: :rejected, reason: reason}
        end
      end
    end
    """
  end

  defp source(%{id: :billing, module: module}, _objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      def plan(id, cents), do: %{id: id, cents: cents}
      def usage(metric, units, cents_per_unit), do: %{kind: :Usage, metric: metric, units: units, cents_per_unit: cents_per_unit}

      def proration(cents, used_days, total_days) when total_days > 0 do
        div(cents * used_days, total_days)
      end

      def invoice(plan, usages, discount_cents \\\\ 0) do
        usage_total = Enum.reduce(usages, 0, fn item, acc -> acc + item.units * item.cents_per_unit end)
        total = max(plan.cents + usage_total - discount_cents, 0)

        %{
          kind: :Invoice,
          plan: plan.id,
          usage: usages,
          discount_cents: discount_cents,
          total_cents: total
        }
      end

      def print_invoice(%{kind: :Invoice, total_cents: cents} = invoice) do
        "Invoice " <> to_string(invoice.plan) <> " total_cents=" <> Integer.to_string(cents)
      end
    end
    """
  end

  defp source(%{id: :clinic, module: module}, _objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      def appointment(provider, patient, starts_at, minutes) do
        %{kind: :Appointment, provider: provider, patient: patient, starts_at: starts_at, minutes: minutes, status: :scheduled}
      end

      def overlap?(left, right) do
        left_end = DateTime.add(left.starts_at, left.minutes * 60, :second)
        right_end = DateTime.add(right.starts_at, right.minutes * 60, :second)
        DateTime.compare(left.starts_at, right_end) == :lt and DateTime.compare(right.starts_at, left_end) == :lt
      end

      def schedule(existing, candidate) do
        if Enum.any?(existing, &overlap?(&1, candidate)) do
          {:error, :overlap}
        else
          {:ok, [candidate | existing]}
        end
      end

      def cancel(%{kind: :Appointment} = appointment), do: %{appointment | status: :cancelled}
      def waitlist(patient, priority \\\\ 0), do: %{kind: :Waitlist, patient: patient, priority: priority, requested_on: Date.utc_today()}
    end
    """
  end

  defp source(%{id: :workflow, module: module}, _objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      def job(id, deps \\\\ [], fun \\\\ nil) do
        run = fun || fn -> {:ok, id} end
        %{id: id, deps: deps, run: run, retry: 1}
      end

      def cycle?(jobs) do
        ids = MapSet.new(Enum.map(jobs, & &1.id))
        Enum.any?(jobs, fn job -> Enum.any?(job.deps, &(not MapSet.member?(ids, &1))) end)
      end

      def execute(jobs) do
        if cycle?(jobs) do
          {:error, :cycle}
        else
          events = Enum.map(jobs, &%{event: :trace, job: &1.id, dependency: &1.deps})
          {:ok, %{results: Enum.map(jobs, & &1.id), trace: events, retry_policy: :retry_once}}
        end
      end

      def retry_failed({:error, _reason}, attempts) when attempts > 0, do: :retry
      def retry_failed(result, _attempts), do: result
    end
    """
  end

  defp source(%{id: :audit, module: module}, _objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      def event(type, data), do: %{kind: :Event, type: type, data: data}

      def apply_event(state, %{kind: :Event, type: :opened, data: data}), do: Map.merge(state, data)
      def apply_event(state, %{kind: :Event, type: :assigned, data: data}), do: Map.put(state, :technician, data.technician)
      def apply_event(state, %{kind: :Event, type: :closed}), do: Map.put(state, :status, :closed)

      def replay(events), do: Enum.reduce(events, %{status: :open}, &apply_event(&2, &1))

      def validate_command(%{status: :closed}, :assign), do: {:error, :invalid_command}
      def validate_command(_state, _command), do: :ok

      def audit_report(events) do
        %{kind: :Audit, event_count: length(events), state: replay(events)}
      end
    end
    """
  end

  defp source(%{id: :existing_app, module: module}, _objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      def feature(name, owner, enabled? \\\\ true) do
        %{kind: :FeatureSlice, name: name, owner: owner, enabled?: enabled?, smoke: :integration}
      end

      def attach_to_users(users, feature) do
        Enum.map(users, &Map.put(&1, :feature, feature.name))
      end

      def integration_smoke do
        users = ExistingApp.Accounts.list_users()
        feature = feature(:dispatch_dashboard, :operations)
        {:ok, attach_to_users(users, feature)}
      end
    end
    """
  end

  defp source(%{module: module}, objective) do
    """
    defmodule #{inspect(module)} do
      @moduledoc false

      def objective, do: #{inspect(objective)}
      def runtime_smoke, do: {:ok, objective()}
    end
    """
  end

  defp mix_exs(spec) do
    """
    defmodule #{spec.module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{spec.app},
          version: "0.1.0",
          elixir: "~> 1.19",
          compilers: [:phoenix_live_view] ++ Mix.compilers(),
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end

      def application do
        [
          extra_applications: [:logger, :runtime_tools],
          mod: {#{spec.module}.Application, []}
        ]
      end

      defp deps do
        #{deps_for_spec(spec)}
      end
    end
    """
  end

  defp deps_for_spec(%{profile: :field_service}) do
    """
    [
          {:phoenix, "~> 1.8"},
          {:phoenix_html, "~> 4.1"},
          {:phoenix_live_view, "~> 1.1"},
          {:ecto_sql, "~> 3.13"},
          {:postgrex, "~> 0.22"},
          {:bandit, "~> 1.5"},
          {:jason, "~> 1.4"},
          {:lazy_html, ">= 0.1.0", only: :test}
        ]
    """
    |> String.trim_trailing()
  end

  defp deps_for_spec(_spec), do: "[]"

  defp field_service_config(spec) do
    """
    import Config

    config :phoenix, :json_library, Jason

    config :#{spec.app}, #{spec.module}Web.Endpoint,
      url: [host: "localhost"],
      adapter: Bandit.PhoenixAdapter,
      render_errors: [
        formats: [json: #{spec.module}Web.ErrorJSON],
        layout: false
      ],
      pubsub_server: #{spec.module}.PubSub,
      live_view: [signing_salt: "opslogic-live"]

    config :#{spec.app}, #{spec.module}.Repo,
      database: "ops_logic_test",
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 1

    import_config "\#{config_env()}.exs"
    """
  end

  defp field_service_test_config(spec) do
    """
    import Config

    config :logger, level: :warning

    config :phoenix, :plug_init_mode, :runtime

    config :phoenix_live_view,
      enable_expensive_runtime_checks: true

    config :#{spec.app}, start_repo?: false

    config :#{spec.app}, #{spec.module}Web.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: 4003],
      secret_key_base: "ops_logic_test_secret_key_base_that_is_long_enough_for_phoenix",
      server: false

    config :#{spec.app}, #{spec.module}.Repo,
      database: "ops_logic_test",
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 1
    """
  end

  defp field_service_readme(spec) do
    """
    # #{spec.module}

    Minimal field-service dispatch application generated by the RLM project recipe.
    It includes contexts for customers, workers, scheduling, work orders,
    Postgres persistence boundaries, LiveView-facing UI state, and webhook
    integration routes plus executable work-order lifecycle tests.
    """
  end

  defp field_service_facade(spec) do
    """
    defmodule #{spec.module} do
      @moduledoc false

      alias #{spec.module}.Customers
      alias #{spec.module}.Scheduling
      alias #{spec.module}.Workers
      alias #{spec.module}.WorkOrders

      def runtime_smoke do
        customer = Customers.customer("CUST-1", "Acme Manufacturing")
        technician = Workers.technician("TECH-1", [:electrical, :hvac])
        order = WorkOrders.new("WO-1", customer.id, :electrical)

        with {:ok, scheduled} <- Scheduling.schedule(order, customer, technician, %{window: "today", instructions: "Reset panel"}),
             {:ok, accepted} <- WorkOrders.accept(scheduled, technician),
             {:ok, traveling} <- WorkOrders.initiate_travel(accepted),
             {:ok, arrived} <- WorkOrders.arrive(traveling),
             {:ok, active} <- WorkOrders.start(active_input(arrived)),
             {:ok, completed} <- WorkOrders.complete(active, %{resolution: "panel reset"}) do
          {:ok, completed}
        end
      end

      defp active_input(work_order), do: work_order
    end
    """
  end

  defp field_service_application(spec) do
    """
    defmodule #{spec.module}.Application do
      @moduledoc false

      use Application

      @impl true
      def start(_type, _args) do
        children =
          repo_children() ++ [
          {Phoenix.PubSub, name: #{spec.module}.PubSub},
          #{spec.module}Web.Endpoint
        ] ++ #{spec.module}.WorkOrders.runtime_children()

        Supervisor.start_link(children,
          strategy: :one_for_one,
          name: #{spec.module}.Supervisor
        )
      end

      defp repo_children do
        if Application.get_env(:#{spec.app}, :start_repo?, true) do
          [#{spec.module}.Repo]
        else
          []
        end
      end
    end
    """
  end

  defp field_service_repo(spec) do
    """
    defmodule #{spec.module}.Repo do
      @moduledoc false

      use Ecto.Repo,
        otp_app: :#{spec.app},
        adapter: Ecto.Adapters.Postgres
    end
    """
  end

  defp field_service_customers(spec) do
    """
    defmodule #{spec.module}.Customers do
      @moduledoc false

      def customer(id, name), do: %{kind: :customer, id: id, name: name}
    end
    """
  end

  defp field_service_workers(spec) do
    """
    defmodule #{spec.module}.Workers do
      @moduledoc false

      def technician(id, skills, available? \\\\ true) do
        %{kind: :technician, id: id, skills: MapSet.new(skills), available?: available?}
      end

      def eligible?(%{available?: true, skills: skills}, required_skill) do
        MapSet.member?(skills, required_skill)
      end

      def eligible?(_worker, _required_skill), do: false
    end
    """
  end

  defp field_service_scheduling(spec) do
    """
    defmodule #{spec.module}.Scheduling do
      @moduledoc false

      alias #{spec.module}.Workers

      def schedule(order, customer, technician, opts \\\\ %{}) do
        cond do
          customer.kind != :customer ->
            {:error, :invalid_customer}

          not Workers.eligible?(technician, order.required_skill) ->
            {:error, :no_eligible_worker}

          true ->
            {:ok,
             order
             |> Map.put(:customer, Map.take(customer, [:id, :name]))
             |> Map.put(:technician_id, technician.id)
             |> Map.put(:schedule, %{
               location_id: customer.id,
               window: Map.get(opts, :window, "unscheduled"),
               instructions: Map.get(opts, :instructions, "")
             })}
        end
      end
    end
    """
  end

  defp field_service_work_orders(spec) do
    """
    defmodule #{spec.module}.WorkOrders do
      @moduledoc false

      alias #{spec.module}.WorkOrders.ScheduledWorkOrder
      alias #{spec.module}.Workers
      alias #{spec.module}.WorkOrderServer

      @states [:new, :accepted, :traveling, :arrived, :in_progress, :completed]

      def new(id, customer_id, required_skill) do
        %{
          kind: :work_order,
          id: id,
          customer_id: customer_id,
          required_skill: required_skill,
          status: :new,
          events: []
        }
      end

      def domain_boundary do
        %{
          context: :work_orders,
          commands: [:schedule, :accept, :initiate_travel, :arrive, :start, :complete],
          persistence: #{spec.module}.Persistence.postgres_tables(),
          schema: ScheduledWorkOrder.__schema__(:source),
          repo: #{spec.module}.Repo,
          runtime: runtime_children()
        }
      end

      def scheduled_changeset(attrs) do
        ScheduledWorkOrder.changeset(%ScheduledWorkOrder{}, attrs)
      end

      def persist_scheduled_order(attrs, repo \\\\ #{spec.module}.Repo) do
        attrs
        |> persistence_plan()
        |> repo.transaction()
      end

      def persistence_plan(attrs) do
        Ecto.Multi.new()
        |> Ecto.Multi.insert(:scheduled_work_order, scheduled_changeset(attrs))
        |> Ecto.Multi.run(:work_order_event, fn repo, %{scheduled_work_order: order} ->
          repo.query(
            "INSERT INTO work_order_events (work_order_id, event_type, payload) VALUES ($1, $2, $3::jsonb)",
            [order.id, "scheduled", ~s({"source":"opslogic_db_smoke"})]
          )
        end)
      end

      def persisted_state(repo \\\\ #{spec.module}.Repo) do
        events =
          repo
          |> persisted_event_rows()
          |> Enum.map(fn [work_order_id, event_type] ->
            %{work_order_id: work_order_id, event_type: event_type}
          end)

        %{
          scheduled_work_orders: repo.all(ScheduledWorkOrder),
          event_log: events
        }
      end

      def schedule_from_dispatch(params, repo \\\\ #{spec.module}.Repo) do
        params
        |> scheduled_order_attrs()
        |> persist_scheduled_order(repo)
      end

      def apply_worker_action(work_order_id, action, repo \\\\ #{spec.module}.Repo) do
        case repo.get(ScheduledWorkOrder, work_order_id) do
          nil ->
            {:error, :not_found}

          %ScheduledWorkOrder{} = order ->
            with {:ok, next_status, event_type} <- transition_status(order.status, action) do
              Ecto.Multi.new()
              |> Ecto.Multi.update(:scheduled_work_order, ScheduledWorkOrder.changeset(order, %{status: next_status}))
              |> Ecto.Multi.run(:work_order_event, fn repo, %{scheduled_work_order: updated} ->
                repo.query(
                  "INSERT INTO work_order_events (work_order_id, event_type, payload) VALUES ($1, $2, $3::jsonb)",
                  [updated.id, event_type, ~s({"source":"opslogic_worker_live"})]
                )
              end)
              |> repo.transaction()
            end
        end
      end

      def transition_status(status, action)
      def transition_status("new", action), do: transition_status(:new, action)
      def transition_status("accepted", action), do: transition_status(:accepted, action)
      def transition_status("traveling", action), do: transition_status(:traveling, action)
      def transition_status("arrived", action), do: transition_status(:arrived, action)
      def transition_status("in_progress", action), do: transition_status(:in_progress, action)
      def transition_status("completed", action), do: transition_status(:completed, action)
      def transition_status(:new, "accept"), do: {:ok, :accepted, "accepted"}
      def transition_status(:accepted, "initiate_travel"), do: {:ok, :traveling, "travel_started"}
      def transition_status(:traveling, "arrive"), do: {:ok, :arrived, "arrived"}
      def transition_status(:arrived, "start"), do: {:ok, :in_progress, "started"}
      def transition_status(:in_progress, "complete"), do: {:ok, :completed, "completed"}
      def transition_status(_status, _action), do: {:error, :invalid_transition}

      def accept(%{status: :new, required_skill: skill} = order, technician) do
        if Workers.eligible?(technician, skill) do
          order
          |> Map.put(:technician_id, technician.id)
          |> transition(:accepted, :accepted)
        else
          {:error, :no_eligible_worker}
        end
      end

      def accept(_order, _technician), do: {:error, :invalid_transition}

      def initiate_travel(%{status: :accepted} = order), do: transition(order, :traveling, :travel_started)
      def initiate_travel(_order), do: {:error, :invalid_transition}

      def arrive(%{status: :traveling} = order), do: transition(order, :arrived, :arrived)
      def arrive(_order), do: {:error, :invalid_transition}

      def start(%{status: :arrived} = order), do: transition(order, :in_progress, :started)
      def start(_order), do: {:error, :invalid_transition}

      def complete(order, details \\\\ %{})
      def complete(%{status: :in_progress} = order, details) do
        order
        |> Map.put(:completion, details)
        |> transition(:completed, :completed)
      end

      def complete(_order, _details), do: {:error, :invalid_transition}

      def states, do: @states

      def runtime_children do
        [
          {Registry, keys: :unique, name: #{spec.module}.WorkOrderRegistry},
          {DynamicSupervisor, strategy: :one_for_one, name: #{spec.module}.WorkOrderSupervisor}
        ]
      end

      def start_runtime_order(order) do
        DynamicSupervisor.start_child(
          #{spec.module}.WorkOrderSupervisor,
          {WorkOrderServer, order}
        )
      end

      defp transition(order, next_status, event) do
        {:ok, %{order | status: next_status, events: order.events ++ [event]}}
      end

      defp scheduled_order_attrs(params) do
        %{
          id: param(params, "id") || param(params, "scheduled_work_order_id"),
          request_id: param(params, "request_id"),
          customer_id: param(params, "customer_id"),
          worker_id: param(params, "worker_id"),
          status: :accepted,
          scheduled_window: param(params, "scheduled_window") || param(params, "window"),
          instructions: param(params, "instructions")
        }
      end

      defp param(params, key) when is_map(params), do: Map.get(params, key) || Map.get(params, atom_param(key))
      defp param(_params, _key), do: nil

      defp atom_param("id"), do: :id
      defp atom_param("scheduled_work_order_id"), do: :scheduled_work_order_id
      defp atom_param("request_id"), do: :request_id
      defp atom_param("customer_id"), do: :customer_id
      defp atom_param("worker_id"), do: :worker_id
      defp atom_param("scheduled_window"), do: :scheduled_window
      defp atom_param("window"), do: :window
      defp atom_param("instructions"), do: :instructions
      defp atom_param(_key), do: nil

      defp persisted_event_rows(repo) do
        %{rows: rows} =
          repo.query!(
            "SELECT work_order_id, event_type FROM work_order_events ORDER BY id",
            []
          )

        rows
      end
    end
    """
  end

  defp field_service_scheduled_work_order_schema(spec) do
    """
    defmodule #{spec.module}.WorkOrders.ScheduledWorkOrder do
      @moduledoc false

      use Ecto.Schema

      import Ecto.Changeset

      @primary_key {:id, :string, autogenerate: false}
      @foreign_key_type :string

      schema "scheduled_work_orders" do
        field :request_id, :string
        field :worker_id, :string
        field :customer_id, :string
        field :status, Ecto.Enum,
          values: [:new, :accepted, :traveling, :arrived, :in_progress, :completed]

        field :scheduled_window, :string
        field :instructions, :string
        field :metadata, :map, default: %{}

        timestamps(type: :utc_datetime_usec)
      end

      def changeset(order, attrs) do
        order
        |> cast(attrs, [
          :id,
          :request_id,
          :worker_id,
          :customer_id,
          :status,
          :scheduled_window,
          :instructions,
          :metadata
        ])
        |> validate_required([:id, :request_id, :customer_id, :status])
      end
    end
    """
  end

  defp field_service_work_order_server(spec) do
    """
    defmodule #{spec.module}.WorkOrderServer do
      @moduledoc false

      use GenServer

      alias #{spec.module}.WorkOrders

      def start_link(order) do
        GenServer.start_link(__MODULE__, order, name: via(order.id))
      end

      def accept(id, technician), do: call(id, {:accept, technician})
      def initiate_travel(id), do: call(id, :initiate_travel)
      def arrive(id), do: call(id, :arrive)
      def start_work(id), do: call(id, :start)
      def complete(id, details \\\\ %{}), do: call(id, {:complete, details})
      def get(id), do: call(id, :get)

      @impl true
      def init(order), do: {:ok, order}

      @impl true
      def handle_call(:get, _from, order), do: {:reply, order, order}
      def handle_call({:accept, technician}, _from, order), do: reply_transition(order, &WorkOrders.accept(&1, technician))
      def handle_call(:initiate_travel, _from, order), do: reply_transition(order, &WorkOrders.initiate_travel/1)
      def handle_call(:arrive, _from, order), do: reply_transition(order, &WorkOrders.arrive/1)
      def handle_call(:start, _from, order), do: reply_transition(order, &WorkOrders.start/1)
      def handle_call({:complete, details}, _from, order), do: reply_transition(order, &WorkOrders.complete(&1, details))

      defp reply_transition(order, fun) do
        case fun.(order) do
          {:ok, next} -> {:reply, {:ok, next}, next}
          {:error, reason} -> {:reply, {:error, reason}, order}
        end
      end

      defp call(id, message), do: GenServer.call(via(id), message)
      defp via(id), do: {:via, Registry, {#{spec.module}.WorkOrderRegistry, id}}
    end
    """
  end

  defp field_service_webhooks(spec) do
    """
    defmodule #{spec.module}.Webhooks do
      @moduledoc false

      def routes do
        [
          %{method: :post, path: "/api/webhooks/work-orders/completed", event: "work_order.completed"},
          %{method: :post, path: "/api/webhooks/work-orders/status", event: "work_order.status_changed"}
        ]
      end

      def work_order_completed(%{status: :completed} = work_order) do
        {:ok, %{topic: "work_order.completed", work_order_id: work_order.id}}
      end

      def work_order_completed(_work_order), do: {:error, :not_completed}
    end
    """
  end

  defp field_service_web(spec) do
    """
    defmodule #{spec.module}Web do
      @moduledoc false

      def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

      def router do
        quote do
          use Phoenix.Router, helpers: false

          import Plug.Conn
          import Phoenix.Controller
          import Phoenix.LiveView.Router
        end
      end

      def controller do
        quote do
          use Phoenix.Controller, formats: [:html, :json]

          import Plug.Conn
        end
      end

      def live_view do
        quote do
          use Phoenix.LiveView

          import Phoenix.Component
          alias Phoenix.LiveView.JS
        end
      end

      def html do
        quote do
          use Phoenix.Component
        end
      end

      defmacro __using__(which) when is_atom(which) do
        apply(__MODULE__, which, [])
      end
    end
    """
  end

  defp field_service_endpoint(spec) do
    """
    defmodule #{spec.module}Web.Endpoint do
      @moduledoc false

      use Phoenix.Endpoint, otp_app: :#{spec.app}

      @session_options [
        store: :cookie,
        key: "_#{spec.app}_key",
        signing_salt: "opslogic"
      ]

      socket "/live", Phoenix.LiveView.Socket,
        websocket: [connect_info: [session: @session_options]],
        longpoll: [connect_info: [session: @session_options]]

      plug Plug.RequestId
      plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

      plug Plug.Parsers,
        parsers: [:urlencoded, :multipart, :json],
        pass: ["*/*"],
        json_decoder: Phoenix.json_library()

      plug Plug.MethodOverride
      plug Plug.Head
      plug Plug.Session, @session_options
      plug #{spec.module}Web.Router
    end
    """
  end

  defp field_service_persistence(spec) do
    """
    defmodule #{spec.module}.Persistence do
      @moduledoc false

      def postgres_tables do
        [:customers, :field_workers, :work_order_requests, :scheduled_work_orders, :work_order_events]
      end

      def schemas do
        %{
          customers: [:id, :name, :location],
          field_workers: [:id, :skills, :availability],
          work_order_requests: [:id, :customer_id, :required_skill, :instructions],
          scheduled_work_orders: [:id, :request_id, :worker_id, :status, :scheduled_window],
          work_order_events: [:id, :work_order_id, :event_type, :payload, :inserted_at]
        }
      end

      def repo_boundary do
        %{
          adapter: :postgres,
          repo: #{spec.module}.Repo,
          schema: #{spec.module}.WorkOrders.ScheduledWorkOrder,
          migration_path: "priv/repo/migrations",
          durable_state_machine?: true
        }
      end
    end
    """
  end

  defp field_service_web_router(spec) do
    """
    defmodule #{spec.module}Web.Router do
      @moduledoc false

      use #{spec.module}Web, :router

      alias #{spec.module}.Webhooks

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
        plug :fetch_live_flash
        plug :protect_from_forgery
        plug :put_secure_browser_headers
      end

      pipeline :api do
        plug :accepts, ["json"]
      end

      scope "/", #{spec.module}Web do
        pipe_through :browser

        live "/dispatch", DispatcherLive, :index
        live "/worker/work-orders", WorkerLive, :index
      end

      scope "/api", #{spec.module}Web do
        pipe_through :api

        post "/webhooks/work-orders/completed", WebhookController, :work_order_completed
        post "/webhooks/work-orders/status", WebhookController, :work_order_status
      end

      def liveview_routes do
        [
          %{path: "/dispatch", live_view: #{spec.module}Web.DispatcherLive, purpose: :dispatcher_board},
          %{path: "/worker/work-orders", live_view: #{spec.module}Web.WorkerLive, purpose: :worker_flow}
        ]
      end

      def webhook_routes, do: Webhooks.routes()

      def phoenix_router_contract do
        %{
          framework: Phoenix,
          liveview: Phoenix.LiveView,
          routes: liveview_routes() ++ webhook_routes()
        }
      end
    end
    """
  end

  defp field_service_webhook_controller(spec) do
    """
    defmodule #{spec.module}Web.WebhookController do
      @moduledoc false

      use #{spec.module}Web, :controller

      def work_order_completed(conn, params) do
        json(conn, %{accepted: true, event: "work_order.completed", payload: params})
      end

      def work_order_status(conn, params) do
        json(conn, %{accepted: true, event: "work_order.status_changed", payload: params})
      end
    end
    """
  end

  defp field_service_error_json(spec) do
    """
    defmodule #{spec.module}Web.ErrorJSON do
      @moduledoc false

      def render(template, _assigns) do
        %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
      end
    end
    """
  end

  defp field_service_dispatcher_live(spec) do
    """
    defmodule #{spec.module}Web.DispatcherLive do
      @moduledoc false

      use #{spec.module}Web, :live_view

      alias #{spec.module}.Persistence
      alias #{spec.module}.Repo
      alias #{spec.module}.WorkOrders

      @impl true
      def mount(_params, session, socket) do
        {:ok, assign(socket, mount_state(mount_opts(session)))}
      end

      @impl true
      def handle_event("schedule_work_order", params, socket) do
        case dispatch_schedule(params, socket.assigns) do
          {:ok, state} ->
            {:noreply,
             socket
             |> assign(state)
             |> assign(:last_dispatch_event, {:schedule_work_order, params})}

          {:error, reason} ->
            {:noreply, assign(socket, :last_dispatch_error, reason)}
        end
      end

      def handle_event("cancel_work_order", params, socket) do
        {:noreply, assign(socket, :last_dispatch_event, {:cancel_work_order, params})}
      end

      def handle_event("reassign_worker", params, socket) do
        {:noreply, assign(socket, :last_dispatch_event, {:reassign_worker, params})}
      end

      @impl true
      def render(assigns) do
        ~H\"\"\"
        <section id="dispatcher-board">
          <h1>OpsLogic Dispatch</h1>
          <button
            id="schedule-work-order"
            phx-click="schedule_work_order"
            phx-value-id="SWO-LIVEVIEW"
            phx-value-request_id="REQ-LIVEVIEW"
            phx-value-customer_id="CUST-LIVEVIEW"
            phx-value-worker_id="TECH-LIVEVIEW"
            phx-value-scheduled_window="today"
            phx-value-instructions="live dispatch"
          >
            Schedule
          </button>
          <ul id="scheduled-work-orders">
            <li :for={order <- @scheduled_work_orders} id={"scheduled-\#{field(order, :id)}"}>
              <span class="work-order-id"><%= field(order, :id) %></span>
              <span class="work-order-status"><%= field(order, :status) %></span>
            </li>
          </ul>
        </section>
        \"\"\"
      end

      def mount_state(opts \\\\ []) do
        persisted = persisted_state(opts)

        %{
          page: :dispatcher_schedule,
          stream_names: [:customers, :workers, :work_order_requests, :scheduled_work_orders],
          repo: Keyword.get(opts, :repo),
          scheduled_work_orders: persisted.scheduled_work_orders,
          event_log: persisted.event_log,
          tables: Persistence.postgres_tables(),
          domain_boundary: WorkOrders.domain_boundary()
        }
      end

      defp persisted_state(opts) do
        cond do
          Keyword.has_key?(opts, :persisted_state) ->
            Keyword.fetch!(opts, :persisted_state)

          Keyword.has_key?(opts, :repo) ->
            opts |> Keyword.fetch!(:repo) |> WorkOrders.persisted_state()

          true ->
            %{scheduled_work_orders: [], event_log: []}
        end
      end

      def dispatch_schedule(params, %{repo: repo}) when not is_nil(repo) do
        with {:ok, _changes} <- WorkOrders.schedule_from_dispatch(params, repo) do
          {:ok, mount_state(repo: repo)}
        end
      end

      def dispatch_schedule(params, state) do
        order = %{
          id: param(params, "id") || param(params, "scheduled_work_order_id"),
          request_id: param(params, "request_id"),
          customer_id: param(params, "customer_id"),
          worker_id: param(params, "worker_id"),
          status: :accepted,
          scheduled_window: param(params, "scheduled_window"),
          instructions: param(params, "instructions")
        }

        event = %{work_order_id: order.id, event_type: "scheduled"}

        {:ok,
         %{
           scheduled_work_orders: [order | Map.get(state, :scheduled_work_orders, [])],
           event_log: Map.get(state, :event_log, []) ++ [event]
         }}
      end

      def field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

      defp mount_opts(%{"persisted_state" => persisted_state}) do
        [persisted_state: normalize_persisted_state(persisted_state)]
      end

      defp mount_opts(_session) do
        if Application.get_env(:#{spec.app}, :start_repo?, true), do: [repo: Repo], else: []
      end

      defp normalize_persisted_state(state) do
        %{
          scheduled_work_orders: Map.get(state, :scheduled_work_orders) || Map.get(state, "scheduled_work_orders") || [],
          event_log: Map.get(state, :event_log) || Map.get(state, "event_log") || []
        }
      end

      defp param(params, key), do: Map.get(params, key) || Map.get(params, atom_param(key))

      defp atom_param("id"), do: :id
      defp atom_param("scheduled_work_order_id"), do: :scheduled_work_order_id
      defp atom_param("request_id"), do: :request_id
      defp atom_param("customer_id"), do: :customer_id
      defp atom_param("worker_id"), do: :worker_id
      defp atom_param("scheduled_window"), do: :scheduled_window
      defp atom_param("instructions"), do: :instructions
      defp atom_param(_key), do: nil

      def handle_event_contract do
        %{
          "schedule_work_order" => [:customer_id, :worker_id, :request_id, :instructions],
          "cancel_work_order" => [:scheduled_work_order_id],
          "reassign_worker" => [:scheduled_work_order_id, :worker_id]
        }
      end
    end
    """
  end

  defp field_service_worker_live(spec) do
    """
    defmodule #{spec.module}Web.WorkerLive do
      @moduledoc false

      use #{spec.module}Web, :live_view

      alias #{spec.module}.Repo
      alias #{spec.module}.WorkOrders

      @impl true
      def mount(_params, session, socket) do
        {:ok, assign(socket, mount_state(mount_opts(session)))}
      end

      @impl true
      def handle_event(action, params, socket)
          when action in ["accept", "initiate_travel", "arrive", "start", "complete"] do
        case apply_worker_event(action, params, socket.assigns) do
          {:ok, state} ->
            {:noreply,
             socket
             |> assign(state)
             |> assign(:last_worker_event, {action, params})}

          {:error, reason} ->
            {:noreply, assign(socket, :last_worker_error, reason)}
        end
      end

      @impl true
      def render(assigns) do
        ~H\"\"\"
        <section id="worker-work-orders">
          <h1>OpsLogic Worker</h1>
          <article :for={order <- @assigned_work_orders} id={"worker-order-\#{field(order, :id)}"}>
            <span class="work-order-id"><%= field(order, :id) %></span>
            <span class="work-order-status"><%= field(order, :status) %></span>
            <button id={"accept-\#{field(order, :id)}"} phx-click="accept" phx-value-work_order_id={field(order, :id)}>
              Accept
            </button>
            <button id={"travel-\#{field(order, :id)}"} phx-click="initiate_travel" phx-value-work_order_id={field(order, :id)}>
              Travel
            </button>
            <button id={"arrive-\#{field(order, :id)}"} phx-click="arrive" phx-value-work_order_id={field(order, :id)}>
              Arrive
            </button>
            <button id={"start-\#{field(order, :id)}"} phx-click="start" phx-value-work_order_id={field(order, :id)}>
              Start
            </button>
            <button id={"complete-\#{field(order, :id)}"} phx-click="complete" phx-value-work_order_id={field(order, :id)} phx-value-resolution="done">
              Complete
            </button>
          </article>
        </section>
        \"\"\"
      end

      def mount_state(opts \\\\ []) do
        persisted = persisted_state(opts)

        %{
          page: :worker_work_orders,
          actions: [:accept, :initiate_travel, :arrive, :start, :complete],
          tracking: [:status, :worker_location, :event_log],
          repo: Keyword.get(opts, :repo),
          assigned_work_orders: persisted.scheduled_work_orders,
          event_log: persisted.event_log
        }
      end

      defp persisted_state(opts) do
        cond do
          Keyword.has_key?(opts, :persisted_state) ->
            Keyword.fetch!(opts, :persisted_state)

          Keyword.has_key?(opts, :repo) ->
            opts |> Keyword.fetch!(:repo) |> #{spec.module}.WorkOrders.persisted_state()

          true ->
            %{scheduled_work_orders: [], event_log: []}
        end
      end

      def apply_worker_event(action, params, %{repo: repo}) when not is_nil(repo) do
        work_order_id = param(params, "work_order_id")

        with {:ok, _changes} <- WorkOrders.apply_worker_action(work_order_id, action, repo) do
          {:ok, mount_state(repo: repo)}
        end
      end

      def apply_worker_event(action, params, state) do
        work_order_id = param(params, "work_order_id")

        with {:ok, next_status, event_type} <- WorkOrders.transition_status(current_status(state, work_order_id), action) do
          {:ok,
           %{
             assigned_work_orders: update_order_status(Map.get(state, :assigned_work_orders, []), work_order_id, next_status),
             event_log: Map.get(state, :event_log, []) ++ [%{work_order_id: work_order_id, event_type: event_type}]
           }}
        end
      end

      def field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

      defp mount_opts(%{"persisted_state" => persisted_state}) do
        [persisted_state: normalize_persisted_state(persisted_state)]
      end

      defp mount_opts(_session) do
        if Application.get_env(:#{spec.app}, :start_repo?, true), do: [repo: Repo], else: []
      end

      defp normalize_persisted_state(state) do
        %{
          scheduled_work_orders: Map.get(state, :scheduled_work_orders) || Map.get(state, "scheduled_work_orders") || [],
          event_log: Map.get(state, :event_log) || Map.get(state, "event_log") || []
        }
      end

      defp current_status(state, work_order_id) do
        state
        |> Map.get(:assigned_work_orders, [])
        |> Enum.find(&(field(&1, :id) == work_order_id))
        |> case do
          nil -> nil
          order -> field(order, :status)
        end
      end

      defp update_order_status(orders, work_order_id, next_status) do
        Enum.map(orders, fn order ->
          if field(order, :id) == work_order_id do
            Map.put(order, :status, next_status)
          else
            order
          end
        end)
      end

      defp param(params, key), do: Map.get(params, key) || Map.get(params, atom_param(key))

      defp atom_param("work_order_id"), do: :work_order_id
      defp atom_param(_key), do: nil

      def handle_event_contract do
        %{
          "accept" => [:work_order_id],
          "initiate_travel" => [:work_order_id],
          "arrive" => [:work_order_id],
          "start" => [:work_order_id],
          "complete" => [:work_order_id, :resolution]
        }
      end
    end
    """
  end

  defp field_service_migration(_spec) do
    """
    -- Postgres persistence boundary for the OpsLogic field-service state machine.
    CREATE TABLE customers (id text PRIMARY KEY, name text NOT NULL, location jsonb DEFAULT '{}'::jsonb);
    CREATE TABLE field_workers (id text PRIMARY KEY, skills text[] NOT NULL DEFAULT '{}', availability jsonb DEFAULT '{}'::jsonb);
    CREATE TABLE work_order_requests (id text PRIMARY KEY, customer_id text NOT NULL REFERENCES customers(id), required_skill text NOT NULL, instructions text);
    CREATE TABLE scheduled_work_orders (id text PRIMARY KEY, request_id text NOT NULL REFERENCES work_order_requests(id), worker_id text REFERENCES field_workers(id), customer_id text NOT NULL REFERENCES customers(id), status text NOT NULL, scheduled_window text, instructions text, metadata jsonb DEFAULT '{}'::jsonb, inserted_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
    CREATE TABLE work_order_events (id bigserial PRIMARY KEY, work_order_id text NOT NULL REFERENCES scheduled_work_orders(id), event_type text NOT NULL, payload jsonb DEFAULT '{}'::jsonb, inserted_at timestamptz NOT NULL DEFAULT now());
    """
  end

  defp field_service_db_smoke_task(spec) do
    """
    defmodule Mix.Tasks.#{spec.module}.DbSmoke do
      @moduledoc false

      use Mix.Task

      alias #{spec.module}.Repo
      alias #{spec.module}.WorkOrders

      @shortdoc "Runs the OpsLogic Postgres-backed persistence smoke"

      @impl true
      def run(_args) do
        Mix.Task.run("app.config")
        Application.put_env(:#{spec.app}, :start_repo?, true)
        Mix.Task.run("app.start")

        migrate!()

        attrs = %{
          id: "SWO-DB-SMOKE",
          request_id: "REQ-DB-SMOKE",
          customer_id: "CUST-DB-SMOKE",
          worker_id: "TECH-DB-SMOKE",
          status: :accepted,
          scheduled_window: "today",
          instructions: "database smoke"
        }

        seed_dependencies!()
        Repo.query!("DELETE FROM work_order_events WHERE work_order_id = $1", [attrs.id])
        Repo.query!("DELETE FROM scheduled_work_orders WHERE id = $1", [attrs.id])

        case WorkOrders.persist_scheduled_order(attrs, Repo) do
          {:ok, %{scheduled_work_order: order}} ->
            %{rows: [[event_count]]} =
              Repo.query!("SELECT count(*) FROM work_order_events WHERE work_order_id = $1", [order.id])

            if event_count == 1 do
              dispatcher = #{spec.module}Web.DispatcherLive.mount_state(repo: Repo)
              worker = #{spec.module}Web.WorkerLive.mount_state(repo: Repo)

              {:ok, worker_after_travel} =
                #{spec.module}Web.WorkerLive.apply_worker_event("initiate_travel", %{"work_order_id" => order.id}, worker)

              if Enum.any?(dispatcher.scheduled_work_orders, &(&1.id == order.id)) and
                   Enum.any?(worker.event_log, &(&1.work_order_id == order.id and &1.event_type == "scheduled")) and
                   Enum.any?(worker_after_travel.assigned_work_orders, &(&1.id == order.id and &1.status == :traveling)) and
                   Enum.any?(worker_after_travel.event_log, &(&1.work_order_id == order.id and &1.event_type == "travel_started")) do
                Mix.shell().info("opslogic_db_smoke_pass")
              else
                Mix.raise("persisted rows were not visible through generated LiveView state")
              end
            else
              Mix.raise("expected one work_order_events row, got \#{inspect(event_count)}")
            end

          {:error, step, reason, _changes} ->
            Mix.raise("DB smoke failed at \#{inspect(step)}: \#{inspect(reason)}")
        end
      end

      defp seed_dependencies! do
        Repo.query!("INSERT INTO customers (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [
          "CUST-DB-SMOKE",
          "Smoke Customer"
        ])

        Repo.query!(
          "INSERT INTO field_workers (id, skills) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
          ["TECH-DB-SMOKE", ["electrical"]]
        )

        Repo.query!(
          "INSERT INTO work_order_requests (id, customer_id, required_skill, instructions) VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING",
          ["REQ-DB-SMOKE", "CUST-DB-SMOKE", "electrical", "database smoke"]
        )
      end

      defp migrate! do
        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS customers (
          id text PRIMARY KEY,
          name text NOT NULL,
          location jsonb DEFAULT '{}'::jsonb
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS field_workers (
          id text PRIMARY KEY,
          skills text[] NOT NULL DEFAULT '{}',
          availability jsonb DEFAULT '{}'::jsonb
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS work_order_requests (
          id text PRIMARY KEY,
          customer_id text NOT NULL REFERENCES customers(id),
          required_skill text NOT NULL,
          instructions text
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS scheduled_work_orders (
          id text PRIMARY KEY,
          request_id text NOT NULL REFERENCES work_order_requests(id),
          worker_id text REFERENCES field_workers(id),
          customer_id text NOT NULL REFERENCES customers(id),
          status text NOT NULL,
          scheduled_window text,
          instructions text,
          metadata jsonb DEFAULT '{}'::jsonb,
          inserted_at timestamptz NOT NULL DEFAULT now(),
          updated_at timestamptz NOT NULL DEFAULT now()
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS work_order_events (
          id bigserial PRIMARY KEY,
          work_order_id text NOT NULL REFERENCES scheduled_work_orders(id),
          event_type text NOT NULL,
          payload jsonb DEFAULT '{}'::jsonb,
          inserted_at timestamptz NOT NULL DEFAULT now()
        )
        \""")
      end
    end
    """
  end

  defp field_service_browser_smoke_task(spec) do
    """
    defmodule Mix.Tasks.#{spec.module}.BrowserSmoke do
      @moduledoc false

      use Mix.Task

      alias #{spec.module}.Repo

      @shortdoc "Runs the OpsLogic Postgres-backed browser smoke"

      @impl true
      def run(_args) do
        Mix.Task.run("app.config")

        port = browser_port()

        Application.put_env(:#{spec.app}, :start_repo?, true)

        endpoint_config =
          :#{spec.app}
          |> Application.get_env(#{spec.module}Web.Endpoint, [])
          |> Keyword.put(:server, true)
          |> Keyword.put(:http, [ip: {127, 0, 0, 1}, port: port])
          |> Keyword.put_new(:secret_key_base, "ops_logic_browser_smoke_secret_key_base_that_is_long_enough")

        Application.put_env(:#{spec.app}, #{spec.module}Web.Endpoint, endpoint_config)

        Mix.Task.run("app.start")

        migrate!()
        seed_browser_dependencies!()
        reset_browser_rows!()

        node = executable!("node", "Node.js is required for the browser smoke")
        browser = browser_executable!()
        script = Path.join(File.cwd!(), "priv/browser_smoke_runner.js")
        base_url = "http://127.0.0.1:\#{port}"

        {output, status} =
          System.cmd(node, [script, browser, base_url],
            cd: File.cwd!(),
            stderr_to_stdout: true
          )

        if status != 0 do
          Mix.raise("browser smoke failed with status \#{status}: \#{output}")
        end

        verify_browser_state!()
        Mix.shell().info("opslogic_browser_smoke_pass")
      end

      defp browser_port do
        case System.get_env("OPSLOGIC_BROWSER_PORT") do
          nil -> 4103
          "" -> 4103
          value ->
            case Integer.parse(value) do
              {port, ""} when port > 0 -> port
              _other -> Mix.raise("OPSLOGIC_BROWSER_PORT must be a positive integer")
            end
        end
      end

      defp browser_executable! do
        System.get_env("OPSLOGIC_BROWSER_EXECUTABLE") ||
          System.get_env("BROWSER") ||
          System.find_executable("google-chrome") ||
          System.find_executable("chromium") ||
          System.find_executable("chromium-browser") ||
          Mix.raise("Chrome or Chromium is required; set OPSLOGIC_BROWSER_EXECUTABLE")
      end

      defp executable!(name, message) do
        System.find_executable(name) || Mix.raise(message)
      end

      defp verify_browser_state! do
        %{rows: [[status]]} =
          Repo.query!("SELECT status FROM scheduled_work_orders WHERE id = $1", ["SWO-LIVEVIEW"])

        %{rows: [[event_count]]} =
          Repo.query!(
            "SELECT count(*) FROM work_order_events WHERE work_order_id = $1 AND event_type = $2",
            ["SWO-LIVEVIEW", "travel_started"]
          )

        unless status == "traveling" and event_count >= 1 do
          Mix.raise("browser smoke did not persist traveling worker state")
        end
      end

      defp seed_browser_dependencies! do
        Repo.query!("INSERT INTO customers (id, name) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING", [
          "CUST-LIVEVIEW",
          "LiveView Customer"
        ])

        Repo.query!(
          "INSERT INTO field_workers (id, skills) VALUES ($1, $2) ON CONFLICT (id) DO NOTHING",
          ["TECH-LIVEVIEW", ["electrical"]]
        )

        Repo.query!(
          "INSERT INTO work_order_requests (id, customer_id, required_skill, instructions) VALUES ($1, $2, $3, $4) ON CONFLICT (id) DO NOTHING",
          ["REQ-LIVEVIEW", "CUST-LIVEVIEW", "electrical", "browser smoke"]
        )
      end

      defp reset_browser_rows! do
        Repo.query!("DELETE FROM work_order_events WHERE work_order_id = $1", ["SWO-LIVEVIEW"])
        Repo.query!("DELETE FROM scheduled_work_orders WHERE id = $1", ["SWO-LIVEVIEW"])
      end

      defp migrate! do
        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS customers (
          id text PRIMARY KEY,
          name text NOT NULL,
          location jsonb DEFAULT '{}'::jsonb
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS field_workers (
          id text PRIMARY KEY,
          skills text[] NOT NULL DEFAULT '{}',
          availability jsonb DEFAULT '{}'::jsonb
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS work_order_requests (
          id text PRIMARY KEY,
          customer_id text NOT NULL REFERENCES customers(id),
          required_skill text NOT NULL,
          instructions text
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS scheduled_work_orders (
          id text PRIMARY KEY,
          request_id text NOT NULL REFERENCES work_order_requests(id),
          worker_id text REFERENCES field_workers(id),
          customer_id text NOT NULL REFERENCES customers(id),
          status text NOT NULL,
          scheduled_window text,
          instructions text,
          metadata jsonb DEFAULT '{}'::jsonb,
          inserted_at timestamptz NOT NULL DEFAULT now(),
          updated_at timestamptz NOT NULL DEFAULT now()
        )
        \""")

        Repo.query!(\"""
        CREATE TABLE IF NOT EXISTS work_order_events (
          id bigserial PRIMARY KEY,
          work_order_id text NOT NULL REFERENCES scheduled_work_orders(id),
          event_type text NOT NULL,
          payload jsonb DEFAULT '{}'::jsonb,
          inserted_at timestamptz NOT NULL DEFAULT now()
        )
        \""")
      end
    end
    """
  end

  defp field_service_browser_smoke_runner do
    """
    #!/usr/bin/env node

    const fs = require("fs");
    const http = require("http");
    const os = require("os");
    const path = require("path");
    const { spawn } = require("child_process");

    const browser = process.argv[2];
    const baseUrl = process.argv[3];
    const timeoutMs = Number(process.env.OPSLOGIC_BROWSER_TIMEOUT_MS || 30000);

    if (!browser || !baseUrl) {
      console.error("usage: browser_smoke_runner.js BROWSER BASE_URL");
      process.exit(64);
    }

    main().catch((error) => {
      console.error(error && error.stack ? error.stack : String(error));
      process.exit(1);
    });

    async function main() {
      const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), "opslogic-browser-smoke-"));
      const chrome = spawn(browser, [
        "--headless=new",
        "--disable-gpu",
        "--no-sandbox",
        "--disable-background-networking",
        "--disable-sync",
        "--disable-extensions",
        "--remote-debugging-port=0",
        "--window-size=1280,900",
        `--user-data-dir=${profileDir}`,
        "about:blank",
      ]);

      const browserOutput = [];
      chrome.stdout.on("data", (data) => browserOutput.push(data.toString()));
      chrome.stderr.on("data", (data) => browserOutput.push(data.toString()));

      let cdp;

      try {
        const devtools = await waitForDevtools(profileDir, timeoutMs);
        const page = await firstPage(devtools.port);
        cdp = await CDP.connect(page.webSocketDebuggerUrl);

        await cdp.send("Page.enable");
        await cdp.send("Runtime.enable");

        await navigate(cdp, `${baseUrl}/dispatch`);
        await waitForText(cdp, "OpsLogic Dispatch");
        await click(cdp, "#schedule-work-order");
        await waitForText(cdp, "SWO-LIVEVIEW");
        await waitForText(cdp, "accepted");

        await navigate(cdp, `${baseUrl}/worker/work-orders`);
        await waitForText(cdp, "OpsLogic Worker");
        await waitForText(cdp, "SWO-LIVEVIEW");
        await click(cdp, "#travel-SWO-LIVEVIEW");
        await waitForText(cdp, "traveling");

        console.log(JSON.stringify({ status: "ok", base_url: baseUrl }));
      } catch (error) {
        error.message = `${error.message}\\nChrome output:\\n${browserOutput.join("")}`;
        throw error;
      } finally {
        if (cdp) cdp.close();
        chrome.kill("SIGTERM");
        fs.rmSync(profileDir, { recursive: true, force: true });
      }
    }

    async function navigate(cdp, url) {
      await cdp.send("Page.navigate", { url });
      await waitFor(cdp, async () => {
        const state = await evalValue(cdp, "document.readyState");
        return state === "interactive" || state === "complete";
      }, timeoutMs);
      await delay(300);
    }

    async function click(cdp, selector) {
      await waitFor(cdp, async () => {
        return await evalValue(cdp, `(() => !!document.querySelector(${JSON.stringify(selector)}))()`);
      }, timeoutMs);

      await evalValue(cdp, `(() => document.querySelector(${JSON.stringify(selector)}).click())()`);
      await delay(300);
    }

    async function waitForText(cdp, text) {
      await waitFor(cdp, async () => {
        const body = await evalValue(cdp, "document.body ? document.body.innerText : ''");
        return String(body || "").includes(text);
      }, timeoutMs);
    }

    async function waitForDevtools(profileDir, timeoutMs) {
      const activePortPath = path.join(profileDir, "DevToolsActivePort");
      const deadline = Date.now() + timeoutMs;

      while (Date.now() < deadline) {
        if (fs.existsSync(activePortPath)) {
          const [port] = fs.readFileSync(activePortPath, "utf8").trim().split(/\\n/);
          return { port };
        }
        await delay(50);
      }

      throw new Error("timed out waiting for Chrome DevToolsActivePort");
    }

    function firstPage(port) {
      return new Promise((resolve, reject) => {
        http.get({ host: "127.0.0.1", port, path: "/json/list" }, (res) => {
          let body = "";
          res.on("data", (chunk) => (body += chunk));
          res.on("end", () => {
            try {
              const pages = JSON.parse(body);
              const page = pages.find((entry) => entry.type === "page") || pages[0];
              if (!page || !page.webSocketDebuggerUrl) reject(new Error("no debuggable Chrome page found"));
              else resolve(page);
            } catch (error) {
              reject(error);
            }
          });
        }).on("error", reject);
      });
    }

    async function waitFor(cdp, predicate, timeoutMs) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (await predicate()) return true;
        await delay(100);
      }
      throw new Error("wait timed out");
    }

    async function evalValue(cdp, expression) {
      const result = await cdp.send("Runtime.evaluate", {
        expression,
        awaitPromise: true,
        returnByValue: true,
        userGesture: true,
      });

      return result.result && result.result.value;
    }

    function delay(ms) {
      return new Promise((resolve) => setTimeout(resolve, ms));
    }

    class CDP {
      constructor(socket) {
        this.socket = socket;
        this.nextId = 1;
        this.pending = new Map();

        socket.addEventListener("message", (event) => {
          const message = JSON.parse(event.data);
          if (message.id && this.pending.has(message.id)) {
            const { resolve, reject } = this.pending.get(message.id);
            this.pending.delete(message.id);
            if (message.error) reject(new Error(JSON.stringify(message.error)));
            else resolve(message.result || {});
          }
        });
      }

      static connect(url) {
        return new Promise((resolve, reject) => {
          const socket = new WebSocket(url);
          socket.addEventListener("open", () => resolve(new CDP(socket)));
          socket.addEventListener("error", reject);
        });
      }

      send(method, params = {}) {
        const id = this.nextId++;
        this.socket.send(JSON.stringify({ id, method, params }));
        return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
      }

      close() {
        this.socket.close();
      }
    }
    """
  end

  defp field_service_tests(spec) do
    """
    defmodule #{spec.module}.WorkOrdersTest do
      use ExUnit.Case, async: true

      alias #{spec.module}.Customers
      alias #{spec.module}.Persistence
      alias #{spec.module}.WorkOrders.ScheduledWorkOrder
      alias #{spec.module}.Scheduling
      alias #{spec.module}.Webhooks
      alias #{spec.module}.Workers
      alias #{spec.module}.WorkOrders
      alias #{spec.module}Web.DispatcherLive
      alias #{spec.module}Web.Endpoint
      alias #{spec.module}Web.Router
      alias #{spec.module}Web.WorkerLive

      test "moves a work order through the technician lifecycle" do
        customer = Customers.customer("CUST-1", "Acme")
        technician = Workers.technician("TECH-1", [:electrical])
        order = WorkOrders.new("WO-1", customer.id, :electrical)

        assert {:ok, accepted} = WorkOrders.accept(order, technician)
        assert {:ok, traveling} = WorkOrders.initiate_travel(accepted)
        assert {:ok, arrived} = WorkOrders.arrive(traveling)
        assert {:ok, started} = WorkOrders.start(arrived)
        assert {:ok, completed} = WorkOrders.complete(started, %{resolution: "fixed"})

        assert completed.status == :completed
        assert completed.events == [:accepted, :travel_started, :arrived, :started, :completed]
        assert {:ok, %{topic: "work_order.completed"}} = Webhooks.work_order_completed(completed)
      end

      test "schedules work orders with customer and worker constraints" do
        customer = Customers.customer("CUST-4", "Acme")
        technician = Workers.technician("TECH-4", [:hvac])
        order = WorkOrders.new("WO-4", customer.id, :hvac)

        assert {:ok, scheduled} =
                 Scheduling.schedule(order, customer, technician, %{window: "today", instructions: "roof unit"})

        assert scheduled.customer.name == "Acme"
        assert scheduled.technician_id == "TECH-4"
        assert scheduled.schedule.instructions == "roof unit"
      end

      test "exposes Phoenix LiveView, Postgres, and webhook integration contracts" do
        assert :scheduled_work_orders in Persistence.postgres_tables()
        assert Persistence.repo_boundary().adapter == :postgres
        assert Persistence.repo_boundary().repo == #{spec.module}.Repo
        assert Persistence.repo_boundary().schema == ScheduledWorkOrder
        assert WorkOrders.domain_boundary().repo == #{spec.module}.Repo
        assert ScheduledWorkOrder.__schema__(:source) == "scheduled_work_orders"
        assert Enum.any?(Router.liveview_routes(), &(&1.path == "/dispatch"))
        assert Enum.any?(Router.webhook_routes(), &(&1.path == "/api/webhooks/work-orders/completed"))
        assert "schedule_work_order" in Map.keys(DispatcherLive.handle_event_contract())
        assert "complete" in Map.keys(WorkerLive.handle_event_contract())
        assert :complete in WorkerLive.mount_state().actions
        assert Endpoint.config(:pubsub_server) == #{spec.module}.PubSub
      end

      test "LiveView mount states can consume persisted scheduling state" do
        persisted_state = %{
          scheduled_work_orders: [%ScheduledWorkOrder{id: "SWO-LIVE", status: :accepted}],
          event_log: [%{work_order_id: "SWO-LIVE", event_type: "scheduled"}]
        }

        dispatcher = DispatcherLive.mount_state(persisted_state: persisted_state)
        worker = WorkerLive.mount_state(persisted_state: persisted_state)

        assert [%ScheduledWorkOrder{id: "SWO-LIVE"}] = dispatcher.scheduled_work_orders
        assert [%{work_order_id: "SWO-LIVE"}] = dispatcher.event_log
        assert [%ScheduledWorkOrder{id: "SWO-LIVE"}] = worker.assigned_work_orders
        assert [%{event_type: "scheduled"}] = worker.event_log
      end

      test "LiveView event cores advance scheduling and worker state" do
        dispatcher_state = DispatcherLive.mount_state()

        assert {:ok, dispatcher} =
                 DispatcherLive.dispatch_schedule(
                   %{
                     "id" => "SWO-EVENT",
                     "request_id" => "REQ-EVENT",
                     "customer_id" => "CUST-EVENT",
                     "worker_id" => "TECH-EVENT",
                     "scheduled_window" => "today",
                     "instructions" => "event core"
                   },
                   dispatcher_state
                 )

        assert [%{id: "SWO-EVENT", status: :accepted}] = dispatcher.scheduled_work_orders
        assert [%{work_order_id: "SWO-EVENT", event_type: "scheduled"}] = dispatcher.event_log

        worker_state = %{
          assigned_work_orders: dispatcher.scheduled_work_orders,
          event_log: dispatcher.event_log
        }

        assert {:ok, worker} =
                 WorkerLive.apply_worker_event(
                   "initiate_travel",
                   %{"work_order_id" => "SWO-EVENT"},
                   worker_state
                 )

        assert [%{id: "SWO-EVENT", status: :traveling}] = worker.assigned_work_orders
        assert Enum.any?(worker.event_log, &(&1.event_type == "travel_started"))
      end

      test "builds a Postgres persistence multi for scheduled work orders" do
        attrs = %{
          id: "SWO-1",
          request_id: "REQ-1",
          customer_id: "CUST-1",
          worker_id: "TECH-1",
          status: :accepted,
          scheduled_window: "today",
          instructions: "reset panel"
        }

        assert %Ecto.Changeset{valid?: true} = WorkOrders.scheduled_changeset(attrs)
        multi = WorkOrders.persistence_plan(attrs)
        assert [
                 {:scheduled_work_order, {:insert, %Ecto.Changeset{}, []}},
                 {:work_order_event, {:run, event_fun}}
               ] = Ecto.Multi.to_list(multi)

        assert is_function(event_fun, 2)
      end

      test "rejects unavailable or mismatched workers" do
        order = WorkOrders.new("WO-2", "CUST-2", :plumbing)
        technician = Workers.technician("TECH-2", [:electrical], false)

        assert {:error, :no_eligible_worker} = WorkOrders.accept(order, technician)
      end

      test "rejects out-of-order transitions" do
        order = WorkOrders.new("WO-3", "CUST-3", :hvac)

        assert {:error, :invalid_transition} = WorkOrders.start(order)
        assert :accepted in WorkOrders.states()
      end

      test "runtime smoke completes dispatch lifecycle" do
        assert {:ok, %{status: :completed, technician_id: "TECH-1"}} = #{spec.module}.runtime_smoke()
      end
    end
    """
  end

  defp field_service_live_tests(spec) do
    """
    defmodule #{spec.module}Web.OpsLogicLiveTest do
      use ExUnit.Case, async: false

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      alias #{spec.module}Web.DispatcherLive
      alias #{spec.module}Web.Endpoint
      alias #{spec.module}Web.WorkerLive

      @endpoint Endpoint

      test "dispatcher LiveView mounts and records scheduling events" do
        {:ok, view, html} = live_isolated(build_conn(), DispatcherLive)

        assert html =~ "OpsLogic Dispatch"

        html =
          view
          |> element("#schedule-work-order")
          |> render_click()

        assert html =~ "OpsLogic Dispatch"
        assert html =~ "SWO-LIVEVIEW"
        assert html =~ "accepted"
      end

      test "worker LiveView mounts and records worker actions" do
        persisted_state = %{
          "scheduled_work_orders" => [
            %{"id" => "SWO-WORKER-LIVE", "status" => "accepted"}
          ],
          "event_log" => [%{"work_order_id" => "SWO-WORKER-LIVE", "event_type" => "scheduled"}]
        }

        {:ok, view, html} =
          live_isolated(build_conn(), WorkerLive,
            session: %{"persisted_state" => persisted_state}
          )

        assert html =~ "OpsLogic Worker"
        assert html =~ "SWO-WORKER-LIVE"

        html =
          view
          |> element("#travel-SWO-WORKER-LIVE")
          |> render_click()

        assert html =~ "OpsLogic Worker"
        assert html =~ "traveling"
      end
    end
    """
  end

  defp runtime_smoke_expr(%{id: :field_service, module: module}) do
    "IO.inspect(#{inspect(module)}.runtime_smoke())"
  end

  defp runtime_smoke_expr(%{id: :inventory, module: module}) do
    ~s|IO.inspect(#{inspect(module)}.audit_allocation(%{"sku-1" => 2}, "sku-1", 1))|
  end

  defp runtime_smoke_expr(%{id: :billing, module: module}) do
    ~s|invoice = #{inspect(module)}.invoice(#{inspect(module)}.plan(:basic, 100), []); IO.puts(#{inspect(module)}.print_invoice(invoice))|
  end

  defp runtime_smoke_expr(%{id: :clinic, module: module}) do
    "IO.inspect(#{inspect(module)}.waitlist(:patient))"
  end

  defp runtime_smoke_expr(%{id: :workflow, module: module}) do
    "IO.inspect(#{inspect(module)}.execute([#{inspect(module)}.job(:a)]))"
  end

  defp runtime_smoke_expr(%{id: :audit, module: module}) do
    "IO.inspect(#{inspect(module)}.audit_report([]))"
  end

  defp runtime_smoke_expr(%{id: :existing_app, module: module}) do
    "IO.inspect(#{inspect(module)}.integration_smoke())"
  end

  defp runtime_smoke_expr(%{module: module}) do
    "IO.inspect(#{inspect(module)}.runtime_smoke())"
  end

  defp runtime_smoke_expr(%{id: :field_service}, %{module: module}) do
    "IO.inspect(#{module}.runtime_smoke())"
  end

  defp runtime_smoke_expr(profile, _spec), do: runtime_smoke_expr(profile)

  defp tests(%{id: :field_service, module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "assigns WorkOrder to a matching Technician" do
        order = #{inspect(module)}.new_work_order("WO-1", :hvac)
        tech = #{inspect(module)}.technician("T-1", [:hvac])
        assert {:ok, assigned} = #{inspect(module)}.assign(order, [tech])
        assert assigned.technician_id == "T-1"
      end

      test "rejects invalid lifecycle transitions" do
        order = #{inspect(module)}.new_work_order("WO-2", :electrical)
        assert {:error, :invalid_transition} = #{inspect(module)}.transition(order, :complete)
      end

      test "declares runtime supervision components" do
        children = #{inspect(module)}.runtime_children()
        assert inspect(children) =~ "DynamicSupervisor"
        assert inspect(children) =~ "Registry"
      end

      test "runtime smoke completes assignment lifecycle" do
        assert {:ok, %{status: :completed}} = #{inspect(module)}.runtime_smoke()
      end
    end
    """
  end

  defp tests(%{id: :inventory, module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "creates a Reservation when stock is available" do
        assert {:ok, stock, reservation} = #{inspect(module)}.reserve(%{"sku-1" => 5}, "sku-1", 3)
        assert stock["sku-1"] == 2
        assert reservation.kind == :Reservation
      end

      test "rejects over-allocation" do
        assert {:error, :insufficient_stock} = #{inspect(module)}.reserve(%{"sku-1" => 1}, "sku-1", 3)
      end

      test "records Movement adjustments" do
        movement = #{inspect(module)}.movement("sku-1", 2, :cycle_count)
        assert #{inspect(module)}.record_movement(%{}, movement)["sku-1"] == 2
      end

      test "detects reorder thresholds" do
        assert [%{action: :reorder}] = #{inspect(module)}.reorder_decisions(%{"sku-1" => 1}, %{"sku-1" => 2})
      end
    end
    """
  end

  defp tests(%{id: :billing, module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "builds an Invoice with Usage charges" do
        invoice = #{inspect(module)}.invoice(#{inspect(module)}.plan(:pro, 1000), [#{inspect(module)}.usage(:api, 3, 25)])
        assert invoice.kind == :Invoice
        assert invoice.total_cents == 1075
      end

      test "calculates proration with integer cents" do
        assert #{inspect(module)}.proration(3100, 10, 31) == 1000
      end

      test "applies discounts without negative totals" do
        invoice = #{inspect(module)}.invoice(#{inspect(module)}.plan(:trial, 100), [], 500)
        assert invoice.total_cents == 0
      end

      test "prints an invoice smoke" do
        invoice = #{inspect(module)}.invoice(#{inspect(module)}.plan(:basic, 100), [])
        assert #{inspect(module)}.print_invoice(invoice) =~ "Invoice"
      end
    end
    """
  end

  defp tests(%{id: :clinic, module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "schedules non-overlapping Appointment slots" do
        {:ok, starts_at, _} = DateTime.from_iso8601("2026-01-01T09:00:00Z")
        appointment = #{inspect(module)}.appointment(:dr_a, :patient_a, starts_at, 30)
        assert {:ok, [_]} = #{inspect(module)}.schedule([], appointment)
      end

      test "rejects overlap conflicts" do
        {:ok, starts_at, _} = DateTime.from_iso8601("2026-01-01T09:00:00Z")
        first = #{inspect(module)}.appointment(:dr_a, :patient_a, starts_at, 30)
        second = #{inspect(module)}.appointment(:dr_a, :patient_b, DateTime.add(starts_at, 10 * 60, :second), 30)
        assert {:error, :overlap} = #{inspect(module)}.schedule([first], second)
      end

      test "supports cancellation" do
        {:ok, starts_at, _} = DateTime.from_iso8601("2026-01-01T09:00:00Z")
        assert %{status: :cancelled} = #{inspect(module)}.appointment(:dr_a, :p, starts_at, 30) |> #{inspect(module)}.cancel()
      end

      test "models Waitlist requests with Date" do
        assert %{kind: :Waitlist, requested_on: %Date{}} = #{inspect(module)}.waitlist(:patient)
      end
    end
    """
  end

  defp tests(%{id: :workflow, module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "executes jobs with dependency trace events" do
        assert {:ok, result} = #{inspect(module)}.execute([#{inspect(module)}.job(:a), #{inspect(module)}.job(:b, [:a])])
        assert Enum.any?(result.trace, &(&1.dependency == [:a]))
      end

      test "rejects missing dependency as a cycle guard" do
        assert {:error, :cycle} = #{inspect(module)}.execute([#{inspect(module)}.job(:b, [:missing])])
      end

      test "exposes retry policy" do
        assert #{inspect(module)}.retry_failed({:error, :boom}, 1) == :retry
      end

      test "returns successful results without retry" do
        assert #{inspect(module)}.retry_failed({:ok, :done}, 0) == {:ok, :done}
      end
    end
    """
  end

  defp tests(%{id: :audit, module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "records Event data and can replay state" do
        events = [#{inspect(module)}.event(:opened, %{id: "WO-1"}), #{inspect(module)}.event(:assigned, %{technician: "T-1"})]
        assert #{inspect(module)}.replay(events).technician == "T-1"
      end

      test "rejects invalid commands for closed work orders" do
        assert {:error, :invalid_command} = #{inspect(module)}.validate_command(%{status: :closed}, :assign)
      end

      test "exports an Audit report" do
        report = #{inspect(module)}.audit_report([#{inspect(module)}.event(:opened, %{id: "WO-1"})])
        assert report.kind == :Audit
      end

      test "applies closed transitions during replay" do
        state = #{inspect(module)}.replay([#{inspect(module)}.event(:closed, %{})])
        assert state.status == :closed
      end
    end
    """
  end

  defp tests(%{id: :existing_app, module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "creates a bounded domain feature slice" do
        assert %{kind: :FeatureSlice, name: :dispatch_dashboard} =
                 #{inspect(module)}.feature(:dispatch_dashboard, :operations)
      end

      test "adapts to the existing Accounts convention" do
        users = ExistingApp.Accounts.list_users()
        assert [%{feature: :dispatch_dashboard}] =
                 #{inspect(module)}.attach_to_users(users, #{inspect(module)}.feature(:dispatch_dashboard, :operations))
      end

      test "runs an integration smoke" do
        assert {:ok, [%{email: "ada@example.test", feature: :dispatch_dashboard}]} =
                 #{inspect(module)}.integration_smoke()
      end

      test "keeps the feature bounded" do
        feature = #{inspect(module)}.feature(:dispatch_dashboard, :operations, false)
        refute feature.enabled?
      end
    end
    """
  end

  defp tests(%{module: module}, module) do
    """
    defmodule #{inspect(module)}Test do
      use ExUnit.Case, async: true

      test "runtime smoke returns the objective" do
        assert {:ok, objective} = #{inspect(module)}.runtime_smoke()
        assert is_binary(objective)
      end

      test "objective is present" do
        assert #{inspect(module)}.objective() != ""
      end

      test "prototype compiles" do
        assert function_exported?(#{inspect(module)}, :runtime_smoke, 0)
      end

      test "prototype exposes a module" do
        assert inspect(#{inspect(module)}) =~ "Prototype"
      end
    end
    """
  end

  defp contains_any?(text, terms), do: Enum.any?(terms, &contains_term?(text, &1))

  defp contains_term?(text, term) do
    Regex.match?(Regex.compile!(term_pattern(term)), text)
  end

  defp term_pattern(term) do
    "(?<![a-z0-9_])#{Regex.escape(term)}(?![a-z0-9_])"
  end
end
