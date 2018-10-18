defmodule Formex.Ecto.Changeset do
  import Ecto.Changeset
  import Ecto.Query
  alias Formex.Form
  alias Formex.FormCollection
  alias Formex.FormNested
  @repo Application.get_env(:formex, :repo)

  import Ecto.DateTime, only: [utc: 0]
  import Ecto.Queryable, only: [to_query: 1]

  defp schema_fields(%{from: {_source, schema}}) when schema != nil, do: schema.__schema__(:fields)

  defp field_exists?(queryable, column) do
    query = to_query(queryable)
    fields = schema_fields(query)

    Enum.member?(fields, column)
  end

  @spec create_changeset(form :: Form.t()) :: Form.t()
  def create_changeset(form) do
    form.struct
    |> cast(form.mapped_params, get_fields_to_cast(form))
    |> cast_multiple_selects(form)
    |> cast_embedded_forms(form)
    |> form.type.modify_changeset(form)
  end

  @spec create_changeset_for_validation(form :: Form.t()) :: Form.t()
  def create_changeset_for_validation(form) do
    form.struct
    |> cast(form.mapped_params, get_fields_to_cast(form))
    |> cast_multiple_selects(form)
  end

  #

  @spec get_fields_to_cast(form :: Form.t()) :: List.t()
  defp get_fields_to_cast(form) do
    fields_casted_manually = form.type.fields_casted_manually(form)

    form
    |> Form.get_fields()
    |> filter_normal_fields(form)
    |> Enum.filter(fn field -> field.name not in fields_casted_manually end)
    |> Enum.map(& &1.struct_name)
  end

  # It will find only many_to_many and one_to_many associations (not many_to_one),
  # because the names (field.name) of many_to_one assocs ends with "_id". This is ok
  defp filter_normal_fields(items, form) do
    items
    |> Enum.filter(fn field ->
      form.struct_module.__schema__(:association, field.name) == nil
    end)
  end

  defp cast_multiple_selects(changeset, form) do
    form
    |> Form.get_fields()
    |> Enum.filter(&(&1.type == :multiple_select))
    |> Enum.reduce(changeset, fn field, changeset ->
      case form.struct_module.__schema__(:association, field.name) do
        nil ->
          changeset

        module ->
          ids = form.mapped_params[to_string(field.name)] || []

          associated =
            module.related
            |> where([c], c.id in ^ids)
            |> @repo.all
            |> Enum.map(&Ecto.Changeset.change/1)

          changeset
          |> put_assoc(field.name, associated)
      end
    end)
  end

  defp cast_embedded_forms(changeset, form) do
    form
    |> Form.get_subforms()
    |> Enum.reduce(changeset, fn item, changeset ->
      cast_func =
        if Form.is_assoc(form, item.name) do
          &cast_assoc/3
        else
          &cast_embed/3
        end

      case item do
        %FormNested{} ->
          changeset
          |> cast_func.(
            item.name,
            with: fn _substruct, _params ->
              subform = item.form
              create_changeset(subform)
            end
          )

        %FormCollection{} ->
          changeset
          |> cast_func.(
            item.name,
            with: fn substruct, params ->
              substruct =
                if substruct.id do
                  substruct
                else
                  Map.put(substruct, :formex_id, params["formex_id"])
                end

              item
              |> FormCollection.get_subform_by_struct(substruct)
              |> case do
                nil ->
                  cast(substruct, %{}, [])

                nested_form ->
                  subform = nested_form.form

                  changeset =
                    subform
                    |> create_changeset()
                    |> cast(subform.mapped_params, [item.delete_field])

                  if get_change(changeset, item.delete_field) do
                    if field_exists?(item.struct_module, :deleted_at) do
                      change(changeset, %{deleted_at: utc()})
                    else
                      %{changeset | action: :delete}
                    end
                  else
                    changeset
                  end
              end
            end
          )
      end
    end)
  end
end
