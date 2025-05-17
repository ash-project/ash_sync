defmodule AshSync.Writer do
  use Phoenix.Controller, formats: [:json]

  alias Phoenix.Sync.Writer
  alias Phoenix.Sync.Writer.Format

  def mutate(otp_app, conn, %{"transaction" => transaction} = _params) do
    user_id = conn.assigns.user_id

    mutations =
      otp_app
      |> Ash.Info.domains()
      |> Enum.flat_map(fn domain ->
        AshSync.Info.sync(domain)
      end)
      |> Enum.filter(&(&1.__struct__ == AshSync.Mutation))

    {:ok, txid, _changes} =
      mutations
      # need to handle multiple resources
      # with the same table here
      |> Enum.group_by(& &1.resource)
      |> Enum.reduce(Phoenix.Sync.Writer.new(), fn {resource, mutations}, writer ->
        Phoenix.Sync.Writer.allow(
          Projects.Project,
          check: fn %Phoenix.Sync.Writer.Operation{changes: changes} = operation ->
            nil

            # defstruct [:index, :operation, :relation, :data, :changes]
          end
        )
      end)

      # |> Phoenix.Sync.Writer.allow(
      #   Projects.Project,
      #   check: reject_invalid_params/2,
      #   load: &Projects.load_for_user(&1, user_id),
      #   validate: &Projects.Project.changeset/2
      # )
      # |> Phoenix.Sync.Writer.allow(
      #   Projects.Issue,
      #   # Use the sensible defaults:
      #   # validate: Projects.Issue.changeset/2
      #   # etc.
      # )
      |> Phoenix.Sync.Writer.apply(
        transaction,
        Repo,
        format: Format.TanstackDB
      )

    render(conn, :mutations, txid: txid)
  end
end
