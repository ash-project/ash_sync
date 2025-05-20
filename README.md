# AshSync

AshSync is a declarative wrapper around `Phoenix.Sync` meant for Ash applications.

## Status

I've laid out some patterns for what this should look like, and set up the typescript code generation process. **I need someone to champion this from here on.**

updating/deleting does not appear to be working due to a client bug that I have not yet figured out.

## Setup

AshSync currently expects an idiomatic front end Phoenix w/ js setup that has the following dependencies added to the `package.json` in `assets`.

- `"@electric-sql/react"`
- `"@tanstack/db"`
- `"@tanstack/db-collections"`
- `"@tanstack/react-db"`
- `"react"`
- `"react-dom"`
- `"uuid"`
- `"zod"`

We generate the following files, which can be used by the js in your front end.

- `assets/js/client/ingest.ts` - used to ingest changes from tanstack db to the sync endpoint
- `assets/js/client/queries.ts` - Functions to directly use shape streams from electricSQL
- `assets/js/client/collections.ts` - Functions to create ElectricCollections which sync back to sync endpoint
- `assets/js/client/schema.ts` - Types for resources being synchronized

To regenerate them, use `mix ash.codegen <name_for_changes>`. Needing to provide a name is inconvenient. We will remove that requirement in the future.

Add the following to your router:

```elixir
scope "/", MyAppWeb do
  pipe_through :browser

  get "/sync", SyncController, :sync
  post "/ingest/mutations", SyncController, :sync_mutate
end
```

And define the controller

```elixir
defmodule MyAppWeb.SyncController do
  use Phoenix.Controller, formats: [:html, :json]

  def sync(conn, params) do
    AshSync.sync_render(:my_app, conn, params)
  end

  def sync_mutate(conn, params) do
    AshSync.sync_mutate(:my_app, conn, params)
  end
end
```

## And then define queries to sync in your domain(s)

```elixir
defmodule MyApp.Blog do
  use Ash.Domain,
    extensions: [AshSync],
    otp_app: :my_app

  sync do
    resource MyApp.Blog.Post do
      query :list_blog_posts, :read do
        on_insert :create
        on_update :update
        on_delete :destroy
      end
    end
  end

  resources do
    resource MyApp.Blog.Post
  end
end
```

## Limitations

ElectricSQL has a lot of limitations around what can be synchronized via shapes.
This project does nothing to enable anything beyond that, so the queries you build will be limited in that way.

A major example is that you cannot `join` in queries that are synchronized. One way to get around this, for example, is to denormalize your data such that all of the information you need to authorize or accomplish a read is on the table itself.
