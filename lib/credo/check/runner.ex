defmodule Credo.Check.Runner do
  @moduledoc false

  # This module is responsible for running checks based on the context represented
  # by the current `Credo.Execution`.

  alias Credo.Check.Params
  alias Credo.Check.Runner.Traversal
  alias Credo.CLI.Output.UI
  alias Credo.Execution

  require Credo.Execution.Timing, as: Timing

  @doc """
  Runs all checks on all source files (according to the config).
  """
  def run(source_files, %Execution{} = exec) when is_list(source_files) do
    {all_check_tuples, _, _} = Execution.checks(exec)

    check_tuples_by_starting_phase =
      all_check_tuples
      |> Enum.group_by(fn {check, _params} -> check.starting_phase() end)
      |> Enum.sort_by(fn {key, _check_tuples} -> key end)
      |> Enum.map(fn {_key, check_tuples} -> check_tuples end)

    Enum.each(check_tuples_by_starting_phase, fn check_tuples ->
      run_phase(source_files, exec, check_tuples)
    end)

    :ok
  end

  defp run_phase(source_files, exec, check_tuples) do
    {shared, legacy} =
      Enum.split_with(check_tuples, fn {check, _params} ->
        not exec.config.debug and Traversal.supported?(check)
      end)

    jobs = Enum.map(legacy, &{:legacy, &1})
    jobs = if shared == [], do: jobs, else: [{:shared, shared} | jobs]

    jobs
    |> Task.async_stream(
      fn
        {:legacy, check_tuple} ->
          run_check(exec, check_tuple)

        {:shared, checks} ->
          plans =
            Enum.map(checks, fn {check, params} = tuple ->
              {check, params, source_files_for_check(exec, tuple)}
            end)

          Traversal.run(source_files, exec, plans)
      end,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()
  end

  defp run_check(exec, {check, params}) do
    Timing.span exec, "check", task: exec.private.current_task, check: check do
      do_run_check(exec, {check, params})
    end
  end

  defp do_run_check(exec, {check, params}) do
    source_files = source_files_for_check(exec, {check, params})

    try do
      check.run_on_all_source_files(exec, source_files, params)
    rescue
      error ->
        warn_about_failed_run(check, source_files)

        if exec.config.crash_on_error do
          reraise error, __STACKTRACE__
        else
          []
        end
    end
  end

  defp source_files_for_check(exec, {check, params}) do
    rerun_files_that_changed = Params.get_rerun_files_that_changed(params)

    known_files = exec |> Execution.get_source_files() |> Enum.map(& &1.filename)
    files_included = Params.files_included(params, check, known_files)
    files_excluded = Params.files_excluded(params, check)

    found_relevant_files =
      cond do
        files_included == known_files and files_excluded == [] ->
          []

        exec.config.read_from_stdin ->
          # TODO: I am unhappy with how convoluted this gets
          #       but it is necessary to avoid hitting the filesystem when reading from STDIN
          [%Credo.SourceFile{filename: filename}] = Execution.get_source_files(exec)

          file_included? =
            if files_included != known_files do
              Credo.Sources.filename_matches?(filename, files_included)
            else
              true
            end

          file_excluded? =
            if files_excluded != [] do
              Credo.Sources.filename_matches?(filename, files_excluded)
            else
              false
            end

          if !file_included? || file_excluded? do
            :skip_run
          else
            []
          end

        true ->
          exec
          |> Execution.working_dir()
          |> Credo.Sources.find_in_dir(files_included, files_excluded)
          |> case do
            [] -> :skip_run
            files -> files
          end
      end

    exec
    |> Execution.get_source_files()
    |> filter_source_files(rerun_files_that_changed)
    |> filter_source_files(found_relevant_files)
  end

  defp filter_source_files(_source_files, :skip_run) do
    []
  end

  defp filter_source_files(source_files, []) do
    source_files
  end

  defp filter_source_files(source_files, files_included) do
    files_included = MapSet.new(files_included)

    Enum.filter(source_files, fn source_file ->
      MapSet.member?(files_included, Path.expand(source_file.filename))
    end)
  end

  defp warn_about_failed_run(check, %Credo.SourceFile{} = source_file) do
    UI.warn("Error while running #{check} on #{source_file.filename}")
  end

  defp warn_about_failed_run(check, _) do
    UI.warn("Error while running #{check}")
  end
end
