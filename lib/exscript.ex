# Copyright 2012 Plataformatec
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
# This file is derived work from Mix.Tasks.Escript.Build for supporting flexible escript generation

defmodule Exscript do
  use Bitwise, only_operators: true

  @shortdoc "Generate escript"
  def escriptize(project, language, escript_opts, force, should_consolidate) do
    script_name  = to_string(escript_opts[:name] || project[:app])
    filename     = escript_opts[:path] || script_name
    main         = escript_opts[:main_module]
    app          = Keyword.get(escript_opts, :app, project[:app])
    files        = project_files()

    escript_mod = String.to_atom(Atom.to_string(app) <> "_escript")

    cond do
      !script_name ->
        Mix.raise "Could not generate escript, no name given, " <>
          "set :name escript option or :app in the project settings"

      !main or !Code.ensure_loaded?(main)->
        Mix.raise "Could not generate escript, please set :main_module " <>
          "in your project configuration (under `:escript` option) to a module that implements main/1"

      force || Mix.Utils.stale?(files, [filename]) ->
        beam_paths =
          [files, deps_files(), core_files(escript_opts, language)]
          |> Stream.concat
          |> prepare_beam_paths

        beam_paths = if should_consolidate do
          Path.wildcard(consolidated_path <> "/*")
          |> prepare_beam_paths(beam_paths)
        else
          beam_paths
        end

        tuples = gen_main(escript_mod, main, app, language) ++
                 read_beams(beam_paths)

        case :zip.create 'mem', tuples, [:memory] do
          {:ok, {'mem', zip}} ->
            shebang  = escript_opts[:shebang] || "#! /usr/bin/env escript\n"
            comment  = build_comment(escript_opts[:comment])
            emu_args = build_emu_args(escript_opts[:emu_args], escript_mod)

            script = IO.iodata_to_binary([shebang, comment, emu_args, zip])
            File.mkdir_p!(Path.dirname(filename))
            File.write!(filename, script)
            set_perms(filename)
          {:error, error} ->
            Mix.raise "Error creating escript: #{error}"
        end

        Mix.shell.info "Generated escript #{filename} with MIX_ENV=#{Mix.env}"
        :ok
      true ->
        :noop
    end
  end

  defp project_files() do
    get_files(Mix.Project.app_path)
  end

  defp get_files(app) do
    Path.wildcard("#{app}/ebin/*.{app,beam}") ++
      (Path.wildcard("#{app}/priv/**/*") |> Enum.filter(&File.regular?/1))
  end

  defp set_perms(filename) do
    stat = File.stat!(filename)
    :ok  = File.chmod(filename, stat.mode ||| 0o111)
  end

  defp deps_files() do
    deps = Mix.Dep.loaded(env: Mix.env) || []
    Enum.flat_map(deps, fn dep -> get_files(dep.opts[:build]) end)
  end

  defp core_files(escript_opts, language) do
    if Keyword.get(escript_opts, :embed_elixir, language == :elixir) do
      Enum.flat_map [:elixir|extra_apps()], &app_files/1
    else
      []
    end
  end

  defp extra_apps() do
    mod = Mix.Project.get!

    extra_apps =
      if function_exported?(mod, :application, 0) do
        mod.application[:applications]
      end

    Enum.filter(extra_apps || [], &(&1 in [:eex, :ex_unit, :mix, :iex, :logger]))
  end

  defp app_files(app) do
    case :code.where_is_file('#{app}.app') do
      :non_existing -> Mix.raise "Could not find application #{app}"
      file -> get_files(Path.dirname(Path.dirname(file)))
    end
  end

  defp prepare_beam_paths(paths, dict \\ HashDict.new) do
    paths
    |> Enum.map(&{Path.basename(&1), &1})
    |> Enum.into(dict)
  end

  defp read_beams(items) do
    items
    |> Enum.map(fn {basename, beam_path} ->
      {String.to_char_list(basename), File.read!(beam_path)}
    end)
  end

  defp consolidated_path, do: Mix.Project.consolidation_path(Mix.Project.config)

  defp build_comment(user_comment) do
    "%% #{user_comment}\n"
  end

  defp build_emu_args(user_args, escript_mod) do
    "%%! -escript main #{escript_mod} #{user_args}\n"
  end

  defp gen_main(name, module, app, language) do
    config =
      if File.regular?("config/config.exs") do
        Mix.Config.read!("config/config.exs")
      else
        []
      end

    module_body = quote do
      @module unquote(module)
      @config unquote(config)
      @app unquote(app)

      @spec main(OptionParser.argv) :: any
      def main(args) do
        unquote(main_body_for(language))
      end

      defp load_config(config) do
        :lists.foreach(fn {app, kw} ->
          :lists.foreach(fn {k, v} ->
            :application.set_env(app, k, v, persistent: true)
          end, kw)
        end, config)
        :ok
      end

      def start_app(nil) do
        :ok
      end

      def start_app(app) do
        case :application.ensure_all_started(app) do
          {:ok, _} -> :ok
          {:error, {app, reason}} ->
            formatted_error = case :code.ensure_loaded(Application) do
              {:module, Application} -> Application.format_error(reason)
              {:error, _} -> :io_lib.format('~p', [reason])
            end
            io_error ["Could not start application ",
                      :erlang.atom_to_binary(app, :utf8),
                      ": ", formatted_error, ?\n]
            :erlang.halt(1)
        end
      end

      defp io_error(message) do
        :io.put_chars(:standard_error, message)
      end
    end

    {:module, ^name, binary, _} = Module.create(name, module_body, Macro.Env.location(__ENV__))
    [{'#{name}.beam', binary}]
  end

  defp main_body_for(:elixir) do
    quote do
      erl_version = :erlang.system_info(:otp_release)
      case :string.to_integer(erl_version) do
        {num, _} when num >= 17 -> nil
        _ ->
          io_error ["Incompatible Erlang/OTP release: ", erl_version,
                    ".\nThis escript requires at least Erlang/OTP 17.0.\n"]
          :erlang.halt(1)
      end

      case :application.ensure_all_started(:elixir) do
        {:ok, _} ->
          load_config(@config)
          args = Enum.map(args, &List.to_string(&1))
          Kernel.CLI.run fn _ -> @module.main(args) end, true
        error ->
          io_error ["Failed to start Elixir.\n", :io_lib.format('error: ~p~n', [error])]
          :erlang.halt(1)
      end
    end
  end

  defp main_body_for(:erlang) do
    quote do
      load_config(@config)
      @module.main(args)
    end
  end
end
