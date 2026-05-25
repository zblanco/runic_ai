defmodule FieldServiceDispatch do
  @moduledoc false

  @type work_order :: %{id: term(), status: atom(), required_skill: atom(), kind: :WorkOrder}
  @type technician :: %{id: term(), skills: [atom()], available?: boolean(), kind: :Technician}

  def new_work_order(id, required_skill) do
    %{kind: :WorkOrder, id: id, required_skill: required_skill, status: :new}
  end

  def technician(id, skills, available? \\ true) do
    %{kind: :Technician, id: id, skills: skills, available?: available?}
  end

  def assign(%{kind: :WorkOrder, required_skill: skill} = work_order, technicians) do
    case Enum.find(technicians, fn technician ->
           technician.available? and skill in technician.skills
         end) do
      nil ->
        {:error, :no_available_technician}

      technician ->
        {:ok, work_order |> Map.put(:technician_id, technician.id) |> Map.put(:status, :assigned)}
    end
  end

  def transition(%{status: :assigned} = work_order, :start),
    do: {:ok, %{work_order | status: :in_progress}}

  def transition(%{status: :in_progress} = work_order, :complete),
    do: {:ok, %{work_order | status: :completed}}

  def transition(_work_order, _event), do: {:error, :invalid_transition}

  def runtime_children do
    [
      %{
        id: FieldServiceDispatch.Registry,
        start: {Registry, :start_link, [[keys: :unique, name: FieldServiceDispatch.Registry]]}
      },
      %{
        id: FieldServiceDispatch.DynamicSupervisor,
        start:
          {DynamicSupervisor, :start_link,
           [[strategy: :one_for_one, name: FieldServiceDispatch.DynamicSupervisor]]}
      }
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
