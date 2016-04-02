defmodule EvercamMedia.Mixfile do
  use Mix.Project

  def project do
    [app: :evercam_media,
     version: "1.0.1",
     elixir: "> 1.2.0",
     elixirc_paths: elixirc_paths(Mix.env),
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     compilers: [:make, :phoenix] ++ Mix.compilers,
     aliases: aliases,
     deps: deps]
  end

  defp aliases do
    [clean: ["clean", "clean.make"]]
  end

  def application do
    [mod: {EvercamMedia, []},
     applications: app_list(Mix.env)]
  end

  defp app_list(:dev), do: [:dotenv, :credo | app_list]
  defp app_list(_), do: app_list
  defp app_list, do: [
    :calecto,
    :con_cache,
    :connection,
    :cowboy,
    :ecto,
    :ex_aws,
    :exq,
    :httpotion,
    :jsx,
    :runtime_tools,
    :tzdata,
    :httpoison,
    :inets,
    :mailgun,
    :phoenix,
    :phoenix_ecto,
    :phoenix_html,
    :porcelain,
    :postgrex,
    :calendar,
    :timex,
    :quantum,
    :uuid,
    :xmerl
  ]

  # Specifies which paths to compile per environment
  defp elixirc_paths(:test), do: ["lib", "web", "test/support"]
  defp elixirc_paths(_),     do: ["lib", "web"]

  defp deps do
    [
      {:calecto, "~> 0.5.0"},
      {:calendar, "~> 0.12.4"},
      {:con_cache, "~> 0.10.0"},
      {:cowboy, "~> 1.0"},
      {:credo, github: "rrrene/credo", only: :dev},
      {:dotenv, "~> 2.0.0", only: :dev},
      {:ecto, "~> 2.0.0-beta.1", override: true},
      {:ex_aws, github: "CargoSense/ex_aws"},
      {:exq, "~> 0.6.2"},
      {:exrm, github: "bitwalker/exrm"},
      {:httpoison, "~> 0.8.2"},
      {:httpotion, "~> 2.0"},
      {:ibrowse, "~> 4.2", override: true},
      {:jsx, "~> 2.8.0", override: true},
      {:mailgun, github: "mosic/mailgun"},
      {:phoenix, "~> 1.1"},
      {:phoenix_ecto, "~> 3.0.0-beta"},
      {:phoenix_html, "~> 2.5"},
      {:poison, "~> 1.5"},
      {:porcelain, "~> 2.0.1"},
      {:postgrex, ">= 0.11.0"},
      {:quantum, github: "c-rack/quantum-elixir"},
      {:uuid, "~> 1.1"},
    ]
  end
end

defmodule Mix.Tasks.Compile.Make do
  @shortdoc "Compiles helper in src/"

  def run(_) do
    {result, _error_code} = System.cmd("make", [], stderr_to_stdout: true)
    Mix.shell.info result

    :ok
  end
end

defmodule Mix.Tasks.Clean.Make do
  @shortdoc "Cleans helper in src/"

  def run(_) do
    {result, _error_code} = System.cmd("make", ['clean'], stderr_to_stdout: true)
    Mix.shell.info result

    :ok
  end
end
