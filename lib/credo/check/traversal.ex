defmodule Credo.Check.Traversal do
  @moduledoc """
  Opts a check into the shared, file-oriented AST traversal.

  Declare the node shapes for which the check's `walk/2` callback can change its
  accumulator or replace a node. Atom events match the first element of an AST
  triple. `:remote` matches remote calls, `{:remote, module, function}` matches
  calls using the given module alias parts (a list) or Erlang module atom, and `:all` matches every node.

      use Credo.Check.Traversal, on: [:def, :defp, {:remote, [:IO], :inspect}]

  The default callbacks build a `Credo.Check.Context`, delegate to `walk/2`, and
  return `context.issues`. Override initialization or finalization for checks
  with additional state or result processing. Keep `run/2` as the standalone
  implementation. Nodes outside the declared events must be no-ops in `walk/2`.

  Keep per-check state in the accumulator: a file worker's process is shared
  by its visitors, so process identity and process-dictionary state are not
  isolated per check.

  Each check has its own accumulator. Replacements and pruning affect only that
  check. Checks with arbitrary file-wide runners can continue using the existing
  check interface. Debug analysis uses the existing runner to preserve timings.
  """

  @callback traversal_events() :: [atom() | {:remote, atom() | [atom()], atom()}]
  @callback init_traversal(Credo.SourceFile.t(), Keyword.t()) :: term()
  @callback traverse_node(Macro.t(), term()) :: {Macro.t(), term()}
  @callback finish_traversal(term()) :: [Credo.Issue.t()]

  defmacro __using__(opts) do
    events = Keyword.fetch!(opts, :on)

    quote do
      @behaviour Credo.Check.Traversal
      @traversal_events unquote(events)

      @doc false
      @impl Credo.Check.Traversal
      def traversal_events, do: @traversal_events

      @doc false
      @impl Credo.Check.Traversal
      def init_traversal(source_file, params) do
        Credo.Check.Context.build(source_file, params, __MODULE__)
      end

      @doc false
      @impl Credo.Check.Traversal
      def traverse_node(node, context), do: walk(node, context)

      @doc false
      @impl Credo.Check.Traversal
      def finish_traversal(context), do: context.issues

      defoverridable init_traversal: 2, traverse_node: 2, finish_traversal: 1
    end
  end
end
