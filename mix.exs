defmodule Probnik.MixProject do
  use Mix.Project

  def project do
    [
      app: :probnik,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  defp releases do
    [
      android: [
        include_executables_for: [],
        include_erts: false,
        steps: [:assemble],
        rel_templates_path: "rel/android"
      ]
    ]
  end

  def application do
    [
      mod: {Probnik.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:scenic, "~> 0.11"},
      {:scenic_driver_local, "~> 0.11"},
      {:recon, "~> 2.5"}
    ]
  end
end
