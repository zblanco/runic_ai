defmodule RunicAI.Recipes.EvaluationHarness do
  @moduledoc """
  Workflow-native evaluation recipe built on the Phase 7 harness and metrics substrate.
  """

  require Runic

  alias Runic.Workflow
  alias RunicAI.Evaluation.Case
  alias RunicAI.Evaluation.Metric
  alias RunicAI.Evaluation.Result
  alias RunicAI.Evaluation.Run
  alias RunicAI.Harness.Integrated
  alias RunicAI.Harness.Policy
  alias RunicAI.Harness.TurnProcessor

  @spec new(keyword()) :: Workflow.t()
  def new(opts) when is_list(opts) do
    metrics = Keyword.get(opts, :metrics, Metric.defaults())
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())

    normalize_case_step =
      Runic.step(
        fn input -> Case.from_input!(input) end,
        name: :normalize_evaluation_case
      )

    cases_accumulator =
      Runic.accumulator(
        [],
        fn %Case{} = evaluation_case, acc -> acc ++ [evaluation_case] end,
        name: :evaluation_cases
      )

    run_case_step =
      Runic.step(
        fn %Case{} = evaluation_case -> run_case!(evaluation_case, opts) end,
        name: :run_evaluation_case
      )

    results_accumulator =
      Runic.accumulator(
        [],
        fn %Result{} = result, acc -> acc ++ [result] end,
        name: :evaluation_results
      )

    aggregate_accumulator =
      Runic.accumulator(
        Metric.init_all(metrics),
        fn %Result{} = result, aggregate -> Metric.accumulate_all(metrics, aggregate, result) end,
        name: :evaluation_aggregate
      )

    run_snapshot_step =
      Runic.step(
        fn cases, results, aggregate ->
          Run.new!(
            recipe: Keyword.fetch!(opts, :recipe),
            policy: static_policy(opts),
            cases: cases,
            results: results,
            aggregate: Metric.finalize_all(metrics, aggregate),
            started_at: started_at,
            completed_at: DateTime.utc_now(),
            metadata: %{aggregate_state: aggregate}
          )
        end,
        name: :evaluation_run_snapshot
      )

    Workflow.new(name: Keyword.get(opts, :name, :evaluation_harness))
    |> Workflow.add(normalize_case_step)
    |> Workflow.add(cases_accumulator, to: :normalize_evaluation_case)
    |> Workflow.add(run_case_step, to: :normalize_evaluation_case)
    |> Workflow.add(results_accumulator, to: :run_evaluation_case)
    |> Workflow.add(aggregate_accumulator, to: :run_evaluation_case)
    |> Workflow.add(run_snapshot_step,
      to: [:evaluation_cases, :evaluation_results, :evaluation_aggregate]
    )
  end

  @spec run_case!(Case.t() | map() | keyword(), keyword()) :: Result.t()
  def run_case!(case_input, opts) when is_list(opts) do
    evaluation_case = Case.from_input!(case_input)
    recipe = Keyword.fetch!(opts, :recipe)
    policy = case_policy(evaluation_case, opts)
    recipe_opts = case_recipe_opts(evaluation_case, opts)
    driver = resolve_driver(Keyword.get(opts, :driver), recipe)

    session =
      driver.new_session(recipe,
        recipe_opts: recipe_opts,
        policy: policy,
        metadata: %{case_id: evaluation_case.id}
      )

    session =
      case_inputs(evaluation_case.input)
      |> Enum.reduce(session, fn input, acc ->
        acc
        |> driver.submit(input)
        |> driver.drain(policy)
      end)

    Result.from_session(evaluation_case, session, metadata: %{recipe: recipe})
  end

  @spec run_workflow([Case.t() | map() | keyword()], keyword()) :: Workflow.t()
  def run_workflow(cases, opts) when is_list(cases) and is_list(opts) do
    Enum.reduce(cases, new(opts), fn evaluation_case, workflow ->
      Workflow.react_until_satisfied(workflow, evaluation_case)
    end)
  end

  @spec run([Case.t() | map() | keyword()], keyword()) :: Run.t()
  def run(cases, opts) when is_list(cases) and is_list(opts) do
    workflow = run_workflow(cases, opts)

    latest_run(workflow) ||
      Run.new!(
        recipe: Keyword.fetch!(opts, :recipe),
        policy: static_policy(opts),
        cases: latest_cases(workflow),
        results: latest_results(workflow),
        aggregate: latest_aggregate(workflow, Keyword.get(opts, :metrics, Metric.defaults())),
        completed_at: DateTime.utc_now()
      )
  end

  @spec latest_cases(Workflow.t()) :: [Case.t()]
  def latest_cases(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions(:evaluation_cases)
    |> Enum.filter(&is_list/1)
    |> Enum.max_by(&length/1, fn -> [] end)
  end

  @spec latest_results(Workflow.t()) :: [Result.t()]
  def latest_results(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions(:evaluation_results)
    |> Enum.filter(&is_list/1)
    |> Enum.max_by(&length/1, fn -> [] end)
  end

  @spec latest_aggregate_state(Workflow.t()) :: map()
  def latest_aggregate_state(%Workflow{} = workflow) do
    case latest_run(workflow) do
      %Run{metadata: %{aggregate_state: aggregate_state}} when is_map(aggregate_state) ->
        aggregate_state

      _ ->
        workflow
        |> Workflow.raw_productions(:evaluation_aggregate)
        |> Enum.filter(&is_map/1)
        |> Enum.max_by(&map_size/1, fn -> %{} end)
    end
  end

  @spec latest_aggregate(Workflow.t(), [Metric.t()]) :: map()
  def latest_aggregate(%Workflow{} = workflow, metrics \\ Metric.defaults()) do
    Metric.finalize_all(metrics, latest_aggregate_state(workflow))
  end

  @spec latest_run(Workflow.t()) :: Run.t() | nil
  def latest_run(%Workflow{} = workflow) do
    workflow
    |> Workflow.raw_productions(:evaluation_run_snapshot)
    |> Enum.filter(&match?(%Run{}, &1))
    |> Enum.max_by(
      fn %Run{} = run ->
        {
          length(run.results),
          length(run.cases),
          if(run.completed_at, do: DateTime.to_unix(run.completed_at, :microsecond), else: 0)
        }
      end,
      fn -> nil end
    )
  end

  defp resolve_driver(nil, recipe) do
    cond do
      function_exported?(recipe, :initial_runtime, 1) -> Integrated
      function_exported?(recipe, :runtime_state, 1) -> Integrated
      true -> TurnProcessor
    end
  end

  defp resolve_driver(:turn_processor, _recipe), do: TurnProcessor
  defp resolve_driver(:integrated, _recipe), do: Integrated
  defp resolve_driver(driver, _recipe) when is_atom(driver), do: driver

  defp case_policy(%Case{} = evaluation_case, opts) do
    case Keyword.get(opts, :policy) do
      nil -> Policy.new!()
      policy when is_function(policy, 1) -> Policy.from_input!(policy.(evaluation_case))
      policy -> Policy.from_input!(policy)
    end
  end

  defp case_recipe_opts(%Case{} = evaluation_case, opts) do
    case Keyword.get(opts, :recipe_opts, []) do
      recipe_opts when is_function(recipe_opts, 1) -> recipe_opts.(evaluation_case)
      recipe_opts -> recipe_opts
    end
  end

  defp case_inputs(inputs) when is_list(inputs), do: inputs
  defp case_inputs(input), do: [input]

  defp static_policy(opts) do
    case Keyword.get(opts, :policy) do
      policy when is_function(policy, 1) -> nil
      policy -> policy
    end
  end
end
