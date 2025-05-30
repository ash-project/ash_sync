defmodule AshSync.Codegen do
  def codegen(_argv) do
    resources =
      Mix.Project.config()[:app]
      |> Ash.Info.domains()
      |> Enum.flat_map(fn domain ->
        AshSync.Info.sync(domain)
      end)

    File.mkdir_p!("assets/js/client")
    generate_query(resources)
    generate_collections(resources)
    generate_schema(resources)
    generate_ingest(resources)
    # generate_mutations(resources)
  end

  # The idea here is that we can accept arbitrary mutations.
  # Left out of the prototype for now.
  # defp generate_mutations(resources) do
  #   mutations =
  #     resources
  #     |> Enum.flat_map(fn resource ->
  #       Enum.map(resource.mutations, fn mutation ->
  #         {resource.resource, mutation}
  #       end)
  #     end)
  #     |> Enum.map_join("\n", fn {resource, mutation} ->
  #       mutation_name = "#{Macro.camelize(to_string(mutation.name))}"
  #       action = Ash.Resource.Info.action(resource, mutation.action)

  #       action_inputs =
  #         resource
  #         |> Ash.Resource.Info.action_inputs(action.name)
  #         |> Enum.filter(&is_atom/1)
  #         |> Enum.map(fn name ->
  #           Enum.find(action.arguments, &(&1.name == name)) ||
  #             Ash.Resource.Info.attribute(resource, name)
  #         end)

  #       params_name = "#{mutation_name}Params"

  #       has_inputs? = not Enum.empty?(action_inputs)

  #       params =
  #         if has_inputs? do
  #           "{input: input}"
  #         else
  #           "{}"
  #         end

  #       type_definition =
  #         if has_inputs? do
  #           """
  #           type #{params_name} = {
  #             input: {
  #           #{Enum.map_join(action_inputs, ";\n", &"    #{&1.name}: #{to_input_type(&1)}")}
  #             }
  #           };
  #           """
  #         else
  #           """
  #           type #{params_name} = {};
  #           """
  #         end

  #       """
  #       #{type_definition}export function #{mutation_name}(#{params}: #{params_name}) {
  #         fetch(relativeUrl('/mutate/'), {
  #           method: "POST",
  #           body: JSON.stringify(input)
  #         })
  #       }
  #       """
  #     end)

  #   contents = """
  #   const relativeUrl = (path) => (
  #     `${window.location.origin}${path}`
  #   )

  #   #{mutations}
  #   """

  #   File.write!("assets/js/client/mutations.ts", contents)
  # end

  defp generate_ingest(resources) do
    resources =
      Enum.reject(resources, fn resource ->
        Enum.all?(resource.queries, fn query ->
          !query.on_update && !query.on_insert && !query.on_delete
        end)
      end)

    if !Enum.empty?(resources) do
      types_to_import =
        resources
        |> Enum.map(fn %{resource: resource} ->
          resource_type_name(resource)
        end)
        |> case do
          [] ->
            ""

          resources ->
            "\nimport type { #{Enum.join(resources, ", ")} } from './schema';"
        end

      types_union =
        resources
        |> Enum.map(fn %{resource: resource} ->
          resource_type_name(resource)
        end)
        |> case do
          [] ->
            ""

          resources ->
            Enum.join(resources, " | ")
        end

      contents =
        """
        import type {
          Collection,
          MutationFn,
          PendingMutation
        } from '@tanstack/react-db';#{types_to_import}

        import { ElectricCollection } from "@tanstack/db-collections";

        export const ingestMutations: MutationFn = async ({ transaction }) => {
          const payload = transaction.mutations.map(
            (mutation: PendingMutation<#{types_union}>) => {
              const { collection: _, ...rest } = mutation

              return { ...rest, query: mutation.collection.config.id };
            }
          )

          const response = await fetch('/ingest/mutations', {
            method: 'POST',
            headers: {
              'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
          })

          if (!response.ok) {
            throw new Error(`HTTP Error: ${response.status}`)
          }

          const result = await response.json()

          const collection = transaction.mutations[0]!.collection as ElectricCollection;
          await collection.awaitTxId(result.txid);
        }
        """

      File.write!("assets/js/client/ingest.ts", contents)
    end
  end

  defp generate_schema(resources) do
    resource_type_defs =
      resources
      |> Enum.map(& &1.resource)
      |> Enum.uniq()
      |> Enum.map(fn resource ->
        attributes = Ash.Resource.Info.public_attributes(resource)
        resource_type_name = resource_type_name(resource)
        schema_name = "#{lowercase_first(resource_type_name)}Schema"

        """
        export const #{schema_name} = z.object({
        #{Enum.map_join(attributes, ",\n", &"  #{&1.name}: #{to_read_type(&1)}")}
        });

        export type #{resource_type_name} = z.infer<typeof #{schema_name}>;
        """
      end)

    schema_contents =
      """
      import { z } from 'zod';

      #{resource_type_defs}
      """

    File.write!("assets/js/client/schema.ts", schema_contents)
  end

  defp generate_query(resources) do
    types_to_import =
      resources
      |> Enum.reject(&Enum.empty?(&1.queries))
      |> Enum.map(fn %{resource: resource} ->
        resource_type_name(resource)
      end)
      |> case do
        [] ->
          ""

        resources ->
          "\nimport type { #{Enum.join(resources, ", ")} } from './schema';"
      end

    query_defs =
      Enum.map_join(resources, "\n", fn %{resource: resource, queries: queries} ->
        Enum.map_join(queries, "\n", fn %{name: name, action: action} ->
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
              #{Enum.map_join(action_inputs, ";\n", &"    #{&1.name}: #{to_input_type(&1)}")}
                },
                options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
              };
              """
            else
              """
              type #{params_name} = {
                options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
              };
              """
            end

          # typescript
          input_destructure =
            if has_inputs? do
              "inputs, "
            end

          input_params_option =
            if has_inputs? do
              "{query: '#{name}', input: inputs}"
            else
              "{query: '#{name}'}"
            end

          """
          #{type_definition}
          export function #{lowercase_first(query_name)}({ #{input_destructure}options }: #{params_name} = {}): Shape<#{resource_type_name}> {
            const stream = new ShapeStream<#{resource_type_name}>({
              ...options,
              params: #{input_params_option},
              url: relativeUrl(`/sync/`),
            });

            return new Shape(stream);
          }
          """
        end)
      end)

    queries_content =
      """
      import { Shape, ShapeStream, ShapeStreamOptions } from "@electric-sql/client";#{types_to_import}
      const relativeUrl = (path) => (
        `${window.location.origin}${path}`
      )
      #{query_defs}
      """

    File.write!("assets/js/client/queries.ts", queries_content)
  end

  defp generate_collections(resources) do
    types_to_import =
      resources
      |> Enum.reject(&Enum.empty?(&1.queries))
      |> Enum.map(fn %{resource: resource} ->
        resource_type_name(resource)
      end)
      |> case do
        [] ->
          ""

        resources ->
          "\nimport type { #{Enum.join(resources, ", ")} } from './schema';" <>
            "\nimport { #{Enum.map_join(resources, ", ", &"#{lowercase_first(&1)}Schema")} } from './schema';"
      end

    collection_defs =
      Enum.map_join(resources, "\n", fn %{resource: resource, queries: queries} ->
        Enum.map_join(queries, "\n", fn %{name: name, action: action} ->
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
              #{Enum.map_join(action_inputs, ";\n", &"    #{&1.name}: #{to_input_type(&1)}")}
                },
                options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
              };
              """
            else
              """
              type #{params_name} = {
                options?: Omit<ShapeStreamOptions<#{resource_type_name}>, #{ignored_opts}>
              };
              """
            end

          input_destructure =
            if has_inputs? do
              "inputs, "
            end

          input_params_option =
            if has_inputs? do
              "{input: inputs}"
            else
              "{query: '#{name}'}"
            end

          primary_key =
            Enum.map_join(Ash.Resource.Info.primary_key(resource), ", ", &"'#{&1}'")

          """
          #{type_definition}
          export function #{lowercase_first(query_name)}({ #{input_destructure}options }: #{params_name} = {}): ElectricCollection<#{resource_type_name}> {
            return createElectricCollection<#{resource_type_name}>({
              id: '#{name}',
              streamOptions: {
                ...options,
                params: #{input_params_option},
                url: relativeUrl('/sync/')
              },
              primaryKey: [#{primary_key}],
              schema: #{lowercase_first(resource_type_name)}Schema
            })
          };
          """
        end)
      end)

    collections_content =
      """
      import { ElectricCollection, createElectricCollection } from "@tanstack/db-collections";
      import { ShapeStreamOptions } from "@electric-sql/client";#{types_to_import}
      const relativeUrl = (path) => (
        `${window.location.origin}${path}`
      )
      #{collection_defs}
      """

    File.write!("assets/js/client/collections.ts", collections_content)
  end

  defp lowercase_first(string) do
    {first, rest} = String.split_at(string, 1)
    String.downcase(first) <> rest
  end

  # TODO make configurable
  defp resource_type_name(resource) do
    resource
    |> Module.split()
    |> Enum.reverse()
    |> Enum.take(2)
    |> Enum.reverse()
    |> Enum.join("")
  end

  # TODO: handle defaults, emit (probably statefully with an agent or somethign)
  # additional things that must be imported into the types file for this to work
  # for instance, uuids will need to import a function to create uuids
  defp to_read_type(%{type: Ash.Type.String}), do: "z.string()"
  defp to_read_type(%{type: Ash.Type.UUID}), do: "z.string().uuid()"

  defp to_read_type(%{type: Ash.Type.DateTime, constraints: [precision: :microsecond]}),
    do: "z.string().datetime({ precision: 3})"

  defp to_read_type(%{type: type, constraints: constraints} = attr) do
    if Ash.Type.NewType.new_type?(type) do
      sub_type_constraints = Ash.Type.NewType.constraints(type, constraints)
      subtype = Ash.Type.NewType.subtype_of(type)

      to_read_type(%{attr | type: subtype, constraints: sub_type_constraints})
    else
      raise "unsupported type #{inspect(type)}"
    end
  end

  defp to_input_type(%{type: Ash.Type.String}), do: "z.string()"
  defp to_input_type(%{type: Ash.Type.UUID}), do: "z.string().uuid()"

  defp to_input_type(%{type: Ash.Type.DateTime, constraints: [precision: :microsecond]}),
    do: "z.string().datetime()"

  defp to_input_type(%{type: type, constraints: constraints} = attr) do
    if Ash.Type.NewType.new_type?(type) do
      sub_type_constraints = Ash.Type.NewType.constraints(type, constraints)
      subtype = Ash.Type.NewType.subtype_of(type)

      to_input_type(%{attr | type: subtype, constraints: sub_type_constraints})
    else
      raise "unsupported type #{inspect(type)}"
    end
  end
end
