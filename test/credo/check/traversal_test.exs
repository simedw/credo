defmodule Credo.Check.TraversalTest do
  use Credo.Test.Case, async: false

  alias Credo.Check.Runner.Traversal
  alias Credo.Execution
  alias Credo.SourceFile

  defmodule Observer do
    use Credo.Check, category: :warning
    use Credo.Check.Traversal, on: [:all, :def, :all]

    def run(source_file, params) do
      source_file
      |> Credo.Code.prewalk(&walk/2, init_traversal(source_file, params))
      |> finish_traversal()
    end

    def init_traversal(source_file, _params), do: %{source_file: source_file, visited: []}

    def finish_traversal(context) do
      [
        %Credo.Issue{
          check: __MODULE__,
          filename: context.source_file.filename,
          meta: [visited: Enum.reverse(context.visited)]
        }
      ]
    end

    defp walk(node, context), do: {node, %{context | visited: [node | context.visited]}}
  end

  defmodule Rewriter do
    use Credo.Check, category: :warning
    use Credo.Check.Traversal, on: [:all]

    def run(source_file, params) do
      source_file
      |> Credo.Code.prewalk(&walk/2, init_traversal(source_file, params))
      |> finish_traversal()
    end

    def init_traversal(source_file, params) do
      if params[:fail] == :init, do: raise("initialization failed")
      %{source_file: source_file, visited: [], fail: params[:fail]}
    end

    def finish_traversal(context) do
      if context.fail == :finish, do: raise("finalization failed")

      [
        %Credo.Issue{
          check: __MODULE__,
          filename: context.source_file.filename,
          meta: [visited: Enum.reverse(context.visited)]
        }
      ]
    end

    defp walk({:bad, _, _}, %{fail: :visit}), do: raise("visit failed")
    defp walk({:bad, _, _}, %{fail: :bad_return}), do: :invalid
    defp walk({:bad, _, _}, %{fail: :bad_tree} = context), do: {{:broken, [], 123}, context}

    defp walk(node, context) do
      replacement =
        case node do
          {:skip, _, _} -> nil
          {:replace, _, _} -> {:inserted, [], [30, {40, 50}]}
          1 -> {:new, [], [10, 11]}
          _ -> node
        end

      {replacement, %{context | visited: [node | context.visited]}}
    end
  end

  defmodule Sparse do
    use Credo.Check, category: :warning
    use Credo.Check.Traversal, on: [:def, :def, :remote, {:remote, :IO, :inspect}]

    def run(source_file, params) do
      source_file
      |> Credo.Code.prewalk(&walk/2, init_traversal(source_file, params))
      |> finish_traversal()
    end

    def init_traversal(source_file, _params), do: %{source_file: source_file, visited: []}

    def finish_traversal(context) do
      [
        %Credo.Issue{
          check: __MODULE__,
          filename: context.source_file.filename,
          meta: [visited: Enum.reverse(context.visited)]
        }
      ]
    end

    defp walk({:def, _, _} = node, context), do: record(node, context)
    defp walk({{:., _, _}, _, _} = node, context), do: record(node, context)
    defp walk(node, context), do: {node, context}
    defp record(node, context), do: {node, %{context | visited: [node | context.visited]}}
  end

  defmodule Precise do
    use Credo.Check, category: :warning

    use Credo.Check.Traversal,
      on: [
        {:remote, [:IO], :inspect},
        {:remote, [:"Elixir", :IO], :inspect},
        {:remote, :os, :cmd}
      ]

    def run(source_file, params) do
      source_file
      |> Credo.Code.prewalk(&walk/2, init_traversal(source_file, params))
      |> finish_traversal()
    end

    def init_traversal(source_file, _params), do: %{source_file: source_file, visited: []}

    def finish_traversal(context) do
      [
        %Credo.Issue{
          check: __MODULE__,
          filename: context.source_file.filename,
          meta: [visited: Enum.reverse(context.visited)]
        }
      ]
    end

    defp walk({{:., _, [{:__aliases__, _, parts}, :inspect]}, _, _} = node, context)
         when parts in [[:IO], [:"Elixir", :IO]] do
      {node, %{context | visited: [node | context.visited]}}
    end

    defp walk({{:., _, [:os, :cmd]}, _, _} = node, context),
      do: {node, %{context | visited: [node | context.visited]}}

    defp walk(node, context), do: {node, context}
  end

  test "independent pruning and replacement match standalone walks" do
    source = SourceFile.parse("[1, skip(2), replace(3), keep(4), {5, 6}]", "rewrite.ex")
    checks = [{Rewriter, []}, {Observer, []}, {Sparse, []}]
    expected = standalone(source, checks)
    actual = shared([source], checks)
    assert actual == expected

    rewriter = Enum.find(actual, &(&1.check == Rewriter))
    observer = Enum.find(actual, &(&1.check == Observer))
    assert 10 in rewriter.meta[:visited]
    refute 2 in rewriter.meta[:visited]
    refute 3 in rewriter.meta[:visited]
    assert 2 in observer.meta[:visited]
    assert 3 in observer.meta[:visited]
    refute 10 in observer.meta[:visited]
    refute {:inserted, [], [30, {40, 50}]} in rewriter.meta[:visited]
  end

  test "node subscriptions avoid irrelevant callbacks and overlapping subscriptions run once" do
    source = SourceFile.parse("def foo(x), do: IO.inspect(x + 1)", "sparse.ex")
    [issue] = shared([source], [{Sparse, []}])
    assert issue == hd(Sparse.run(source, []))
    assert length(issue.meta[:visited]) == 2
  end

  test "precise dispatch distinguishes aliases, qualified aliases and Erlang atoms" do
    source =
      SourceFile.parse(
        "[IO.inspect(1), Elixir.IO.inspect(2), :os.cmd('true'), IO.puts(3), Other.IO.inspect(4), :other.cmd(5)]",
        "remote.ex"
      )

    [issue] = shared([source], [{Precise, []}])
    assert issue == hd(Precise.run(source, []))
    assert length(issue.meta[:visited]) == 3
  end

  test "each file and duplicate check configuration has independent state" do
    sources = [SourceFile.parse("[1, keep(2)]", "one.ex"), SourceFile.parse("[3]", "two.ex")]
    checks = [{Observer, []}, {Rewriter, []}, {Observer, []}]
    expected = sources |> Enum.flat_map(&standalone(&1, checks)) |> Enum.sort()
    assert shared(sources, checks) == expected
  end

  test "initialization, visitor and finalization failures leave other checks intact" do
    source = SourceFile.parse("[keep(1), bad(2)]", "failure.ex")

    for phase <- [:init, :visit, :finish, :bad_return, :bad_tree] do
      assert shared([source], [{Observer, []}, {Rewriter, [fail: phase]}]) ==
               standalone(source, [{Observer, []}])
    end
  end

  test "crash-on-error propagates failures from every phase" do
    source = SourceFile.parse("bad(2)", "failure.ex")
    {:ok, supervisor} = Task.Supervisor.start_link()

    ExUnit.CaptureLog.capture_log(fn ->
      for phase <- [:init, :visit, :finish] do
        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            shared([source], [{Rewriter, [fail: phase]}], true)
          end)

        assert {:exit, {%RuntimeError{}, _stack}} = Task.yield(task, 5_000)
      end
    end)
  end

  test "a missing per-check selection does not execute that check" do
    source = SourceFile.parse("[1]", "selection.ex")
    exec = Execution.build()
    assert :ok = Traversal.run([source], exec, [{Observer, [], []}])
    assert Execution.get_issues(exec) == []
  end

  test "a missing cached AST follows the soft-failure policy" do
    source = %SourceFile{filename: "missing.ex", hash: "missing", status: :valid}
    assert shared([source], [{Observer, []}, {Rewriter, []}]) == []
  end

  test "visitor discovery loads a check that is present on the code path" do
    module = Module.concat(__MODULE__, "AutoloadFixture")
    dir = Path.join(System.tmp_dir!(), "credo-visitor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    {:module, ^module, beam, _} =
      Module.create(
        module,
        quote do
          use Credo.Check, category: :warning
          use Credo.Check.Traversal, on: [:def]
          def run(_source_file, _params), do: []
          defp walk(node, context), do: {node, context}
        end,
        Macro.Env.location(__ENV__)
      )

    File.write!(Path.join(dir, Atom.to_string(module) <> ".beam"), beam)
    Code.prepend_path(dir)

    try do
      :code.purge(module)
      :code.delete(module)
      refute function_exported?(module, :traversal_events, 0)
      assert Traversal.supported?(module)
    after
      :code.purge(module)
      :code.delete(module)
      Code.delete_path(dir)
      File.rm_rf!(dir)
    end
  end

  defp standalone(source, checks) do
    checks |> Enum.flat_map(fn {check, params} -> check.run(source, params) end) |> Enum.sort()
  end

  defp shared(sources, checks, crash_on_error \\ false) do
    exec = Execution.build()
    exec = %{exec | config: %{exec.config | crash_on_error: crash_on_error}}
    plans = Enum.map(checks, fn {check, params} -> {check, params, sources} end)
    assert :ok = Traversal.run(sources, exec, plans)
    exec |> Execution.get_issues() |> Enum.sort()
  end
end
