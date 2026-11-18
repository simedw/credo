defmodule Credo.Check.Runner.Traversal do
  @moduledoc false

  import Bitwise

  alias Credo.CLI.Output.UI
  alias Credo.Execution.ExecutionIssues
  alias Credo.SourceFile

  def supported?(check) do
    Code.ensure_loaded?(check) and function_exported?(check, :traversal_events, 0)
  end

  def run(source_files, exec, plans) do
    checks =
      plans |> Enum.map(fn {check, params, _files} -> {check, params} end) |> List.to_tuple()

    selections =
      plans
      |> Enum.with_index()
      |> Enum.map(fn {{_check, _params, files}, id} -> {id, MapSet.new(files)} end)

    index =
      plans
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{check, _params, _files}, id}, index ->
        check.traversal_events()
        |> normalize_events()
        |> Enum.reduce(index, fn event, index ->
          event = if event in [:all, :remote], do: {:kind, event}, else: event
          Map.update(index, event, [{id, check, 1 <<< id}], &[{id, check, 1 <<< id} | &1])
        end)
      end)

    # Resolve file selection before spawning workers. Capturing every selection
    # set in a per-file task would copy the whole project repeatedly.
    source_files
    |> Stream.map(fn source_file ->
      ids = for {id, files} <- selections, MapSet.member?(files, source_file), do: id
      {source_file, ids}
    end)
    |> Stream.reject(fn {_source, ids} -> ids == [] end)
    |> Task.async_stream(
      fn {source_file, ids} -> run_file(source_file, ids, checks, index, exec) end,
      max_concurrency: exec.private.max_concurrent_check_runs,
      ordered: false,
      timeout: :infinity
    )
    |> Stream.run()

    :ok
  end

  defp normalize_events(events) do
    cond do
      :all in events -> [:all]
      :remote in events -> Enum.reject(Enum.uniq(events), &match?({:remote, _, _}, &1))
      true -> Enum.uniq(events)
    end
  end

  defp run_file(source_file, ids, checks, index, exec) do
    values =
      Enum.reduce(ids, Tuple.duplicate(:inactive, tuple_size(checks)), fn id, values ->
        {check, params} = elem(checks, id)
        put_elem(values, id, initialize(check, source_file, params, exec))
      end)

    env = %{
      source_file: source_file,
      checks: checks,
      index: index,
      exec: exec,
      all: Map.get(index, {:kind, :all}, []),
      remote: Map.get(index, {:kind, :remote}, [])
    }

    values =
      case load_ast(source_file, ids, values, env) do
        {:ok, ast} -> walk(ast, values, 0, env)
        :failed -> Tuple.duplicate(:failed, tuple_size(values))
      end

    issues =
      Enum.flat_map(ids, fn id ->
        case elem(values, id) do
          {:ok, context} ->
            {check, _params} = elem(checks, id)
            finalize(check, context, env)

          :failed ->
            []
        end
      end)

    ExecutionIssues.append(exec, issues)
  end

  defp walk(node, values, blocked, env) do
    {values, blocked} = dispatch(node, values, blocked, env)
    walk_children(node, values, blocked, env)
  end

  defp dispatch(node, values, blocked, %{all: []} = env) do
    dispatch_shape(node, values, blocked, env)
  end

  defp dispatch(node, values, blocked, env) do
    {values, blocked} = visit(env.all, node, values, blocked, env)
    dispatch_shape(node, values, blocked, env)
  end

  defp dispatch_shape(
         {{:., _, [{:__aliases__, _, parts}, function]}, _, _} = node,
         values,
         blocked,
         env
       ) do
    {values, blocked} = visit(env.remote, node, values, blocked, env)
    visit(Map.get(env.index, {:remote, parts, function}, []), node, values, blocked, env)
  end

  defp dispatch_shape({{:., _, [module, function]}, _, _} = node, values, blocked, env)
       when is_atom(module) and is_atom(function) do
    {values, blocked} = visit(env.remote, node, values, blocked, env)
    visit(Map.get(env.index, {:remote, module, function}, []), node, values, blocked, env)
  end

  defp dispatch_shape({{:., _, _}, _, _} = node, values, blocked, env) do
    visit(env.remote, node, values, blocked, env)
  end

  defp dispatch_shape({form, _, _} = node, values, blocked, env) when is_atom(form) do
    visit(Map.get(env.index, form, []), node, values, blocked, env)
  end

  defp dispatch_shape(_node, values, blocked, _env), do: {values, blocked}

  defp visit([], _node, values, blocked, _env), do: {values, blocked}

  defp visit([{id, check, mask} | rest], node, values, blocked, env) do
    {values, blocked} =
      case elem(values, id) do
        {:ok, context} when (blocked &&& mask) == 0 ->
          case visit_node(check, node, context, env) do
            {:ok, {replacement, context}} ->
              values = put_elem(values, id, {:ok, context})

              if replacement === node do
                {values, blocked}
              else
                # Traverse replacement children for this check alone. The other
                # checks still see the original tree, with their own state.
                values = walk_replacement(replacement, values, id, check, mask, env)
                {values, blocked ||| mask}
              end

            :failed ->
              {put_elem(values, id, :failed), blocked}
          end

        _ ->
          {values, blocked}
      end

    visit(rest, node, values, blocked, env)
  end

  defp walk_replacement(node, values, _id, _check, mask, %{exec: %{crash_on_error: true}} = env) do
    walk_children(node, values, bnot(mask), env)
  end

  defp walk_replacement(node, values, id, check, mask, env) do
    walk_children(node, values, bnot(mask), env)
  rescue
    error ->
      failed(check, env.source_file, env.exec, error, __STACKTRACE__)
      put_elem(values, id, :failed)
  end

  defp load_ast(source_file, ids, values, env) do
    {:ok, SourceFile.ast(source_file)}
  rescue
    error ->
      Enum.each(ids, fn id ->
        case elem(values, id) do
          {:ok, _context} ->
            {check, _params} = elem(env.checks, id)
            failed(check, source_file, env.exec, error, __STACKTRACE__)

          :failed ->
            :ok
        end
      end)

      :failed
  end

  defp walk_children({form, _meta, args}, values, blocked, env) when is_atom(form) do
    walk_args(args, values, blocked, env)
  end

  defp walk_children({form, _meta, args}, values, blocked, env) do
    values = walk(form, values, blocked, env)
    walk_args(args, values, blocked, env)
  end

  defp walk_children({left, right}, values, blocked, env) do
    values = walk(left, values, blocked, env)
    walk(right, values, blocked, env)
  end

  defp walk_children(list, values, blocked, env) when is_list(list) do
    walk_args(list, values, blocked, env)
  end

  defp walk_children(_node, values, _blocked, _env), do: values

  defp walk_args(args, values, _blocked, _env) when is_atom(args), do: values

  defp walk_args(args, values, blocked, env) when is_list(args) do
    Enum.reduce(args, values, &walk(&1, &2, blocked, env))
  end

  defp initialize(check, source_file, params, exec) do
    {:ok, check.init_traversal(source_file, params)}
  rescue
    error -> failed(check, source_file, exec, error, __STACKTRACE__)
  end

  defp visit_node(check, node, context, env) do
    {replacement, context} = check.traverse_node(node, context)
    {:ok, {replacement, context}}
  rescue
    error -> failed(check, env.source_file, env.exec, error, __STACKTRACE__)
  end

  defp finalize(check, context, env) do
    check.finish_traversal(context)
  rescue
    error ->
      failed(check, env.source_file, env.exec, error, __STACKTRACE__)
      []
  end

  defp failed(check, source_file, exec, error, stacktrace) do
    UI.warn("Error while running #{check} on #{source_file.filename}")
    if exec.config.crash_on_error, do: reraise(error, stacktrace)
    :failed
  end
end
