defmodule AshSync do
  defmodule Query do
    defstruct [:name, :action]
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
    ],
    args: [:name, :action]
  }

  defmodule Mutation do
    defstruct [:name, :action]
  end

  @mutation %Spark.Dsl.Entity{
    name: :mutation,
    target: Mutation,
    schema: [
      name: [
        type: :atom,
        doc: "The name of the query, shows up in `/sync/:name`"
      ],
      action: [
        type: :atom,
        doc: "The action to sync"
      ]
    ],
    args: [:name, :action]
  }

  defmodule Resource do
    defstruct [:resource, :on_insert, :on_update, :on_delete, queries: [], mutations: []]
  end

  @resource %Spark.Dsl.Entity{
    name: :resource,
    target: Resource,
    describe: "Define available sync actions for a resource",
    schema: [
      resource: [
        type: {:spark, Ash.Resource},
        doc: "The resource being configured"
      ],
      on_insert: [
        type: :atom,
        doc: "The create action to run on insert"
      ],
      on_update: [
        type: :atom,
        doc: "The update action to run on update"
      ],
      on_delete: [
        type: :atom,
        doc: "The destroy action to run on delete"
      ]
    ],
    args: [:resource],
    entities: [
      queries: [@query],
      mutations: [@mutation]
    ]
  }

  @sync %Spark.Dsl.Section{
    name: :sync,
    describe: "Define available sync actions for a resource",
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
    |> Enum.find_value(fn %{resource: resource, queries: queries} ->
      Enum.find_value(queries, fn query ->
        if to_string(query.name) == params["query"] do
          {resource, query}
        end
      end)
    end)
    |> case do
      nil ->
        raise "not found"

      {resource, %{action: action}} ->
        resource
        |> Ash.Query.for_read(action, params["input"] || %{},
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

          %{query: query} ->
            Phoenix.Sync.Controller.sync_render(
              conn,
              params,
              query
            )
        end
    end
  end

  @spec mutate(
          otp_app :: atom,
          conn :: Plug.Con.t(),
          params :: map,
          opts :: Keyword.t()
        ) :: Plug.Conn.t()
  def mutate(otp_app, conn, params, opts \\ []) do
    format = opts[:format] || Phoenix.Sync.Writer.Format.TanstackDB

    actor = Ash.PlugHelpers.get_actor(conn)
    tenant = Ash.PlugHelpers.get_tenant(conn)
    context = Ash.PlugHelpers.get_context(conn) || %{}

    sync_data =
      otp_app
      |> Ash.Info.domains()
      |> Enum.flat_map(fn domain ->
        AshSync.Info.sync(domain)
      end)

    params["_json"]
    # TODO: this index thing is a hack because the `key` from the payload is lost during
    # parsing. It may be that the key is not something to generally rely on in which
    # case this weird hack is fine I guess?
    |> Stream.with_index()
    |> Enum.reduce_while({%{}, []}, fn {mutation, index}, {changesets, mutations} ->
      action_key =
        case mutation["type"] do
          "insert" -> :on_insert
          "delete" -> :on_delete
          "update" -> :on_update
        end

      Enum.find_value(sync_data, fn %{resource: resource, queries: queries} = sync ->
        action = Map.get(sync, action_key)

        if action do
          query =
            Enum.find(queries, fn query ->
              if to_string(query.name) == mutation["query"] do
                query
              end
            end)

          if query do
            {resource, Ash.Resource.Info.action(resource, action), mutation, query}
          end
        end
      end)
      |> case do
        nil ->
          {:halt, {:error, "not found"}}

        {resource, action, mutation, %{action: read_action} = query} ->
          # TODO: handle schema multitenancy here
          # TODO: get actual default from repo?
          schema = AshPostgres.DataLayer.Info.schema(resource) || "public"
          table = AshPostgres.DataLayer.Info.table(resource)

          mutation = put_in(mutation, ["syncMetadata", "relation"], [schema, table])

          case action.type do
            :update ->
              primary_key =
                Map.take(
                  mutation,
                  Enum.map(Ash.Resource.Info.primary_key(resource), &to_string/1)
                )

              {:ok,
               fn ->
                 resource
                 |> Ash.Query.do_filter(primary_key)
                 |> Ash.Query.set_context(query)
                 # TODO: params["input"] doesn't work, we don't get original input
                 # https://github.com/TanStack/db/issues/96
                 |> Ash.Query.for_read(read_action, params["input"] || %{},
                   actor: actor,
                   tenant: tenant,
                   context: context
                 )
                 |> Ash.bulk_update(
                   action,
                   mutation["changes"],
                   notify?: true,
                   actor: actor,
                   tenant: tenant,
                   context: context
                 )
                 |> case do
                   %Ash.BulkResult{status: :success, records: [record]} ->
                     {:ok, record}

                   %Ash.BulkResult{status: :success, records: []} ->
                     {:error, "not found"}

                   %Ash.BulkResult{status: :error, errors: errors} ->
                     IO.inspect(errors)
                     {:error, "something went wrong"}
                 end
               end}

            :destroy ->
              primary_key =
                Map.take(
                  mutation,
                  Enum.map(Ash.Resource.Info.primary_key(resource), &to_string/1)
                )

              {:ok,
               fn ->
                 resource
                 |> Ash.Query.do_filter(primary_key)
                 |> Ash.Query.set_context(query)
                 # TODO: params["input"] doesn't work, we don't get original input
                 # https://github.com/TanStack/db/issues/96
                 |> Ash.Query.for_read(read_action, params["input"] || %{},
                   actor: actor,
                   tenant: tenant,
                   context: context
                 )
                 |> Ash.bulk_destroy(action, %{},
                   notify?: true,
                   actor: actor,
                   tenant: tenant,
                   context: context
                 )
                 |> case do
                   %Ash.BulkResult{status: :success, records: [record]} ->
                     {:ok, record}

                   %Ash.BulkResult{status: :success, records: []} ->
                     {:error, "not found"}

                   %Ash.BulkResult{status: :error, errors: errors} ->
                     IO.inspect(errors)
                     {:error, "something went wrong"}
                 end
               end}

            :create ->
              changeset =
                Ash.Changeset.for_action(resource, action, mutation["changes"],
                  actor: actor,
                  tenant: tenant,
                  context: context,
                  skip_unknown_inputs: :*
                )

              if changeset.valid? do
                if Ash.can?(changeset, actor,
                     pre_flight?: true,
                     return_forbidden_error?: true,
                     maybe_is: false
                   ) do
                  {:cont, {:ok, {Map.put(changesets, index, changeset), [mutation | mutations]}}}
                else
                  {:halt, {:error, Ash.Error.to_error_class(changeset.errors)}}
                end
              else
                {:halt, {:error, Ash.Error.to_error_class(changeset.errors)}}
              end
          end
      end
    end)
    |> case do
      {:ok, {changesets, mutations}} ->
        Process.put(:ash_sync_hacky_count, 0)

        # TODO: handle errors
        # TODO: extract out eager validation of changesets to before the transaction
        # TODO: what??
        {:ok, txid} =
          mutations
          |> Enum.reverse()
          |> Phoenix.Sync.Writer.transact(
            Application.fetch_env!(:phoenix_sync, :repo),
            fn _operation ->
              changeset = changesets[Process.put(:ash_sync_hacky_count, 1)]

              if changeset.action.type == :create do
                case Ash.create(changeset) do
                  {:ok, result} -> {:ok, result}
                  {:error, error} -> {:error, error}
                end
              else
                changeset.()
              end
            end,
            format: format,
            timeout: 60_000
          )

        Plug.Conn.send_resp(conn, 200, Jason.encode!(%{txid: txid}))

      {:error, error} ->
        IO.inspect(error)
        # TODO: Need to figure out error message mapping
        Plug.Conn.send_resp(conn, 500, Jason.encode!(%{"error" => "something went wrong"}))
    end
  end
end
