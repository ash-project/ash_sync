defmodule AshSync do
  defmodule Query do
    defstruct [:name, :resource, :action]
  end

  @query %Spark.Dsl.Entity{
    name: :query,
    target: Query,
    schema: [
      name: [
        type: :atom,
        doc: "The name of the query, shows up in `/sync/:name`"
      ],
      resource: [
        type: :atom,
        doc: "The resource to sync"
      ],
      action: [
        type: :atom,
        doc: "The action to sync"
      ]
    ],
    args: [:name, :resource, :action]
  }

  @sync %Spark.Dsl.Section{
    name: :sync,
    description: "Define available sync actions",
    entities: [
      @query
    ]
  }
  use Spark.Dsl.Extension, sections: [@sync]
end
