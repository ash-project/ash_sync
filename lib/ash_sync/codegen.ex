defmodule AshSync.Codegen do
  def codegen(argv) do
    prelude = """
    import { Shape, ShapeStream, ShapeStreamOptions } from "@electric-sql/client";
    """

    queries =
      Mix.Project.config()[:app]
      |> Ash.Info.domains()
      |> Enum.flat_map(fn domain ->
        AshSync.Info.sync(domain)
      end)
      |> Enum.filter(&(&1.__struct__ == AshSync.Query))

    resource_type_defs =
      queries
      |> Enum.map(& &1.resource)
      |> Enum.uniq()
      |> Enum.map(fn resource ->
        # TODO: make configurable
        attributes = Ash.Resource.Info.public_attributes(resource)

        """
        export type #{resource_type_name(resource)} = {
        #{Enum.map_join(attributes, ",\n", &"  #{&1.name}: #{to_read_type(&1)}")}
        }
        """
      end)

    query_defs =
      Enum.map_join(queries, "\n", fn %{name: name, resource: resource, action: action} ->
        action = Ash.Resource.Info.action(resource, action)

        action_inputs =
          resource
          |> Ash.Resource.Info.action_inputs(action.name)
          |> Enum.filter(&is_atom/1)
          |> Enum.map(fn name ->
            Enum.find(action.arguments, &(&1.name == name)) ||
              Ash.Resource.Info.attribute(resource, name)
          end)

        query_name = "#{Macro.camelize(to_string(name))}"

        params_name = "#{query_name}Params"
        resource_type_name = resource_type_name(resource)

        has_inputs? = not Enum.empty?(action_inputs)

        # not actually sure why I *had* to remove `parser`, but we probably don't want it anyway?
        ignored_opts = Enum.map_join(["url", "params", "parser"], " | ", &"'#{&1}'")

        type_definition =
          if has_inputs? do
            """
            type #{params_name} = {
              input: {
            #{Enum.map_join(action_inputs, ",\n", &"    #{&1.name}: #{to_input_type(&1)}")}
              },
              options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
            }
            """
          else
            """
            type #{params_name} = {
              options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
            }
            """
          end

        # typescript
        input_destructure =
          if has_inputs? do
            "inputs, "
          end

        input_params_option =
          if has_inputs? do
            "params: {input: inputs}, "
          end

        """
        #{type_definition}
        export function #{lowercase_first(query_name)}({ #{input_destructure}options }: #{params_name} = {}): Shape<#{resource_type_name}> {
          const stream = new ShapeStream<#{resource_type_name}>({
            ...options,
            #{input_params_option}url: `http://localhost:4000/sync/#{name}`,
          });

          return new Shape(stream);
        }
        """
      end)

    contents =
      """
      #{prelude}
      #{resource_type_defs}
      #{query_defs}
      """

    File.write!("assets/js/shapes.ts", contents)
  end

  defp lowercase_first(string) do
    {first, rest} = String.split_at(string, 1)
    String.downcase(first) <> rest
  end

  # TODO make configurable naturally
  defp resource_type_name(resource) do
    resource
    |> Module.split()
    |> Enum.reverse()
    |> Enum.take(2)
    |> Enum.reverse()
    |> Enum.join("")
  end

  defp to_read_type(%{type: Ash.Type.String}), do: "string"
  defp to_read_type(%{type: Ash.Type.UUID}), do: "string"

  defp to_input_type(%{type: Ash.Type.String}), do: "string"
  defp to_input_type(%{type: Ash.Type.UUID}), do: "string"
end
