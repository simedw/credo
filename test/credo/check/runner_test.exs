defmodule Credo.Check.RunnerTest do
  use Credo.Test.Case, async: false

  alias Credo.Check.Runner
  alias Credo.Execution
  alias Credo.SourceFile

  defmodule RecordingCheck do
    use Credo.Check, category: :warning

    def run(source_file, params) do
      send(params[:owner], {:checked, source_file.filename})
      []
    end
  end

  defmodule SharedRecordingCheck do
    use Credo.Check, category: :warning
    use Credo.Check.Traversal, on: [:def]

    def run(source_file, params) do
      send(params[:owner], {:mode, :legacy})
      send(params[:owner], {:checked, source_file.filename})
      []
    end

    def init_traversal(source_file, params) do
      send(params[:owner], {:mode, :shared})
      send(params[:owner], {:checked, source_file.filename})
      super(source_file, params)
    end

    defp walk(node, context), do: {node, context}
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "credo-runner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    sources =
      for name <- ["a.ex", "b.ex", "c.ex"] do
        path = Path.join(dir, name)
        File.write!(path, "value = 1\n")
        SourceFile.parse("value = 1\n", path)
      end

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, sources: sources}
  end

  test "runs on every source without a file filter", %{sources: sources} do
    for check <- [RecordingCheck, SharedRecordingCheck] do
      assert checked_files(sources, [], check) == Enum.sort(Enum.map(sources, & &1.filename))
    end
  end

  test "intersects included and excluded files", %{dir: dir, sources: [a, _b, c] = sources} do
    params = [files: %{included: [Path.join(dir, "*.ex")], excluded: [Path.join(dir, "b.ex")]}]

    for check <- [RecordingCheck, SharedRecordingCheck] do
      assert checked_files(sources, params, check) == Enum.sort([a.filename, c.filename])
    end
  end

  test "does not run when included patterns match no files", %{dir: dir, sources: sources} do
    for check <- [RecordingCheck, SharedRecordingCheck] do
      assert checked_files(sources, [files: %{included: [Path.join(dir, "missing.ex")]}], check) ==
               []
    end
  end

  test "intersects a rerun with the check's file filter", %{
    dir: dir,
    sources: [a, b, _c] = sources
  } do
    params = [
      files: %{included: [Path.join(dir, "*.ex")], excluded: [Path.join(dir, "b.ex")]},
      __rerun_files_that_changed__: Enum.map([a, b], &Path.expand(&1.filename))
    ]

    for check <- [RecordingCheck, SharedRecordingCheck] do
      assert checked_files(sources, params, check) == [a.filename]
    end
  end

  test "debug analysis uses the original per-check runner", %{sources: [source | _]} do
    assert checked_files([source], [], SharedRecordingCheck, false) == [source.filename]
    assert_received {:mode, :shared}
    refute_received {:mode, :legacy}

    assert checked_files([source], [], SharedRecordingCheck, true) == [source.filename]
    assert_received {:mode, :legacy}
    refute_received {:mode, :shared}
  end

  test "a mixed run retains legacy checks alongside shared checks", %{sources: [source | _]} do
    exec = Execution.build() |> Execution.put_source_files([source])
    params = [owner: self()]

    exec = %{
      exec
      | config: %{
          exec.config
          | checks: %{
              enabled: [{RecordingCheck, params}, {SharedRecordingCheck, params}],
              disabled: []
            }
        }
    }

    assert Runner.run([source], exec) == :ok
    assert receive_files([]) == [source.filename, source.filename]
  end

  test "stdin checks honor inclusion and exclusion without reading a source path" do
    source = SourceFile.parse("def virtual, do: :ok", "virtual_stdin.ex")
    refute File.exists?(source.filename)

    for excluded <- [[], [~r/virtual_stdin/]] do
      params = [owner: self(), files: %{included: [~r/virtual_stdin/], excluded: excluded}]
      exec = Execution.build() |> Execution.put_source_files([source])

      exec = %{
        exec
        | config: %{
            exec.config
            | read_from_stdin: true,
              checks: %{enabled: [{SharedRecordingCheck, params}], disabled: []}
          }
      }

      assert Runner.run([source], exec) == :ok
      expected = if excluded == [], do: [source.filename], else: []
      assert receive_files([]) == expected
    end
  end

  defp checked_files(sources, params, check, debug \\ false) do
    exec = Execution.build() |> Execution.put_source_files(sources)

    exec = %{
      exec
      | cli_options: %Credo.CLI.Options{path: File.cwd!()},
        config: %{
          exec.config
          | debug: debug,
            checks: %{enabled: [{check, Keyword.put(params, :owner, self())}], disabled: []}
        }
    }

    assert Runner.run(sources, exec) == :ok
    receive_files([]) |> Enum.sort()
  end

  defp receive_files(files) do
    receive do
      {:checked, filename} -> receive_files([filename | files])
    after
      0 -> files
    end
  end
end
