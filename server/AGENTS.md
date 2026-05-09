This is the zonia server, a Phoenix application using Channels, Presence,
and Ecto on SQLite.

## Project guidelines

- Use `mix precommit` alias when you are done with all changes and fix any
  pending issues. Precommit runs `compile --warnings-as-errors`,
  `deps.unlock --unused`, `format`, and `test` — all four must be clean.
- Use the already included and available `:req` (`Req`) library for HTTP
  requests.
- New deps need a justification. We deliberately do **not** use `argon2_elixir`
  (see decisions in `../AGENTS.md`).

## Channel & socket conventions

- The third arg to `connect/3` in tests is a **keyword list**, not a map, in
  Phoenix 1.8 — pass `connect(UserSocket, %{"key" => key})`, no third arg.
- New channel topics that require auth must pattern-match on
  `%{assigns: %{authenticated: true}}` in their `join/3` head and return
  `{:error, %{reason: "unauthenticated"}}` otherwise.
- Use `push(socket, event, payload)` for pushes that go only to the joiner
  (e.g., the initial `presence_state`). Use `broadcast!/3` for room-wide
  fan-out. Don't accidentally `broadcast` what should be a `push`.
- Server-side timestamps in payloads use `System.system_time(:second)`. The
  client renders local time from that.

## Test conventions

- Use `Zonia.DataCase` for context tests, `ZoniaWeb.ChannelCase` for
  socket/channel tests. Both wire up `Ecto.Adapters.SQL.Sandbox`.
- Channel tests that use `Phoenix.Presence` must be `async: false` —
  Presence shares state across processes for a given topic, so concurrent
  tests joining the same topic see each other's diffs. Context tests are
  `async: true`.
- For broadcasts: `subscribe_and_join` then `assert_broadcast "event", payload`.
  For server-pushes-to-joiner: `assert_push "event", payload`.
- Don't sleep. Use `assert_receive` / `assert_push` / `assert_broadcast`
  with the default timeout. If you need to wait for a process to handle
  prior messages, use `:sys.get_state/1`.

## Elixir guidelines

- Elixir lists **do not support index based access via the access syntax**

  **Never do this (invalid)**:

      i = 0
      mylist = ["blue", "green"]
      mylist[i]

  Instead, **always** use `Enum.at`, pattern matching, or `List` for index based list access, ie:

      i = 0
      mylist = ["blue", "green"]
      Enum.at(mylist, i)

- Elixir variables are immutable, but can be rebound, so for block expressions like `if`, `case`, `cond`, etc
  you *must* bind the result of the expression to a variable if you want to use it and you CANNOT rebind the result inside the expression, ie:

      # INVALID: we are rebinding inside the `if` and the result never gets assigned
      if connected?(socket) do
        socket = assign(socket, :val, val)
      end

      # VALID: we rebind the result of the `if` to a new variable
      socket =
        if connected?(socket) do
          assign(socket, :val, val)
        end

- **Never** nest multiple modules in the same file as it can cause cyclic dependencies and compilation errors
- **Never** use map access syntax (`changeset[:field]`) on structs as they do not implement the Access behaviour by default. For regular structs, you **must** access the fields directly, such as `my_struct.field` or use higher level APIs that are available on the struct if they exist, `Ecto.Changeset.get_field/2` for changesets
- Elixir's standard library has everything necessary for date and time manipulation. Familiarize yourself with the common `Time`, `Date`, `DateTime`, and `Calendar` interfaces by accessing their documentation as necessary. **Never** install additional dependencies unless asked or for date/time parsing (which you can use the `date_time_parser` package)
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Predicate function names should not start with `is_` and should end in a question mark. Names like `is_thing` should be reserved for guards
- Elixir's builtin OTP primitives like `DynamicSupervisor` and `Registry`, require names in the child spec, such as `{DynamicSupervisor, name: MyApp.MyDynamicSup}`, then you can use `DynamicSupervisor.start_child(MyApp.MyDynamicSup, child_spec)`
- Use `Task.async_stream(collection, callback, options)` for concurrent enumeration with back-pressure. The majority of times you will want to pass `timeout: :infinity` as option

## Mix guidelines

- Read the docs and options before using tasks (by using `mix help task_name`)
- To debug test failures, run tests in a specific file with `mix test test/my_test.exs` or run all previously failed tests with `mix test --failed`

## Test guidelines

- **Always use `start_supervised!/1`** to start processes in tests as it guarantees cleanup between tests
- **Avoid** `Process.sleep/1` and `Process.alive?/1` in tests
  - Instead of sleeping to wait for a process to finish, **always** use `Process.monitor/1` and assert on the DOWN message:

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

   - Instead of sleeping to synchronize before the next call, **always** use `_ = :sys.get_state/1` to ensure the process has handled prior messages

## Ecto Guidelines

- **Always** preload Ecto associations in queries when they'll be accessed in templates, ie a message that needs to reference the `message.user.email`
- Remember `import Ecto.Query` and other supporting modules when you write `seeds.exs`
- `Ecto.Schema` fields always use the `:string` type, even for `:text`, columns, ie: `field :name, :string`
- `Ecto.Changeset.validate_number/2` **DOES NOT SUPPORT the `:allow_nil` option**. By default, Ecto validations only run if a change for the given field exists and the change value is not nil, so such as option is never needed
- You **must** use `Ecto.Changeset.get_field(changeset, :field)` to access changeset fields
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls or similar for security purposes. Instead they must be explicitly set when creating the struct
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when generating migration files, so the correct timestamp and conventions are applied
