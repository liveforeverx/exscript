defmodule Exscript.Mixfile do
  use Mix.Project
  @vsn "0.1.0"
  @github "https://github.com/liveforeverx/exscript"

  def project do
    [app: :exscript,
     version: @vsn,
     elixir: "~> 1.2",
     deps: deps,
     description: description,
     package: package]
  end

  defp description do
    """
    Escript generator
    """
  end

  defp package do
    [maintainers: ["Dmitry Russ(Aleksandrov)"],
     licenses: ["Apache 2.0"],
     links: %{"GitHub" => @github}]
   end

  # Configuration for the OTP application
  #
  # Type `mix help compile.app` for more information
  def application do
    [applications: [:logger]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:mydep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:mydep, git: "https://github.com/elixir-lang/mydep.git", tag: "0.1.0"}
  #
  # Type `mix help deps` for more examples and options
  defp deps do
    []
  end
end
