defmodule FieldServiceDispatchTest do
  use ExUnit.Case, async: true

  test "assigns WorkOrder to a matching Technician" do
    order = FieldServiceDispatch.new_work_order("WO-1", :hvac)
    tech = FieldServiceDispatch.technician("T-1", [:hvac])
    assert {:ok, assigned} = FieldServiceDispatch.assign(order, [tech])
    assert assigned.technician_id == "T-1"
  end

  test "rejects invalid lifecycle transitions" do
    order = FieldServiceDispatch.new_work_order("WO-2", :electrical)
    assert {:error, :invalid_transition} = FieldServiceDispatch.transition(order, :complete)
  end

  test "declares runtime supervision components" do
    children = FieldServiceDispatch.runtime_children()
    assert inspect(children) =~ "DynamicSupervisor"
    assert inspect(children) =~ "Registry"
  end

  test "runtime smoke completes assignment lifecycle" do
    assert {:ok, %{status: :completed}} = FieldServiceDispatch.runtime_smoke()
  end
end
