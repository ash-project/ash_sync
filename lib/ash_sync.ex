defmodule AshSync do
  defmodule Query do
    defstruct [:name, :action]
  end

  defmodule Resource do
    defstruct [:resource, :update_action, :destroy_action, :create_action, queries: []]
  end

  @query %Spark.Dsl.Entity{
    name: :query,
    target: Query,
    schema: [
      name: [
        type: :atom,
        doc: "The name of the query, shows up in `/sync/:name`"
      ],
      action: [
        type: :atom,
        doc: "The action to sync"
      ]
    ]
  }

  @resource %Spark.Dsl.Entity{
    name: :resource,
    target: Resource,
    schema: [
      resource: [
        type: :atom,
        doc: "The resource to sync"
      ]
    ],
    entities: [
      queries: [
        @query
      ]
    ],
    args: [:resource]
  }

  @sync %Spark.Dsl.Section{
    name: :sync,
    describe: "Define available sync actions",
    entities: [
      @resource
    ]
  }

  use Spark.Dsl.Extension, sections: [@sync]

  def codegen(argv) do
    AshSync.Codegen.codegen(argv)
  end

  def sync_render(otp_app, conn, params) do
    actor = Ash.PlugHelpers.get_actor(conn)
    tenant = Ash.PlugHelpers.get_tenant(conn)
    context = Ash.PlugHelpers.get_context(conn) || %{}

    otp_app
    |> Ash.Info.domains()
    |> Enum.flat_map(fn domain ->
      AshSync.Info.sync(domain)
    end)
    |> Enum.find(fn %struct{name: name} ->
      struct == AshSync.Query and to_string(name) == params["query"]
    end)
    |> case do
      nil ->
        raise "not found"

      %{resource: resource, action: action} ->
        resource
        |> Ash.Query.for_read(action, conn.query_params["input"] || %{},
          actor: actor,
          tenant: tenant,
          context: context
        )
        |> Ash.data_layer_query!()
        |> case do
          # todo: we're adding this hook all the time,
          # but we need to not do that.
          # %{
          #   ash_query: %{authorize_results: authorize_results}
          # }
          # when authorize_results == [] ->
          #   raise "Incompatible action, had authorize results"

          %{
            ash_query: %{after_action: after_action}
          }
          when after_action != [] ->
            raise "Incompatible action, had after action"

          %{query: query, ash_query: ash_query} ->
            Phoenix.Sync.Controller.sync_render(
              conn,
              params,
              query
            )
        end
    end
  end
end
