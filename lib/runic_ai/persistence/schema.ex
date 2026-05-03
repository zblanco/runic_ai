defmodule RunicAI.Persistence.Schema do
  @moduledoc false

  import Ecto.Changeset

  alias RunicAI.Persistence.JSON

  @spec put_new_id(Ecto.Changeset.t(), atom(), String.t()) :: Ecto.Changeset.t()
  def put_new_id(changeset, field \\ :id, prefix) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, "#{prefix}:#{Ecto.UUID.generate()}")
      _value -> changeset
    end
  end

  @spec put_json_defaults(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def put_json_defaults(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      value = get_field(acc, field)

      cond do
        is_nil(value) -> put_change(acc, field, %{})
        is_map(value) -> put_change(acc, field, JSON.safe(value))
        true -> put_change(acc, field, %{"value" => JSON.safe(value)})
      end
    end)
  end

  @spec atom_to_string(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def atom_to_string(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      value when is_atom(value) -> put_change(changeset, field, Atom.to_string(value))
      _value -> changeset
    end
  end

  @spec normalize_strings(Ecto.Changeset.t(), [atom()]) :: Ecto.Changeset.t()
  def normalize_strings(changeset, fields) do
    Enum.reduce(fields, changeset, &atom_to_string(&2, &1))
  end

  @spec validate_status(Ecto.Changeset.t(), [atom() | String.t()]) :: Ecto.Changeset.t()
  def validate_status(changeset, statuses) do
    valid = Enum.map(statuses, &to_string/1)
    validate_inclusion(changeset, :status, valid)
  end

  @spec stringify_attr_values(map(), [atom()]) :: map()
  def stringify_attr_values(attrs, fields) when is_map(attrs) do
    Enum.reduce(fields, attrs, fn field, acc ->
      stringify_attr_value(acc, field)
    end)
  end

  defp stringify_attr_value(attrs, field) do
    string_field = Atom.to_string(field)

    cond do
      is_atom(Map.get(attrs, field)) and not is_nil(Map.get(attrs, field)) ->
        Map.put(attrs, field, Atom.to_string(Map.fetch!(attrs, field)))

      is_atom(Map.get(attrs, string_field)) and not is_nil(Map.get(attrs, string_field)) ->
        Map.put(attrs, string_field, Atom.to_string(Map.fetch!(attrs, string_field)))

      true ->
        attrs
    end
  end
end
