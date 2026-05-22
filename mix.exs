defmodule Scrawly.MixProject do
  use Mix.Project

  def project do
    [
      erlc_options: [:debug_info],
      erlc_paths: ["src"],
      app: :scrawly,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view, :hologram] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      usage_rules: usage_rules()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Scrawly.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  #
  # `lib_mob/` holds the on-device BEAM entry (`Scrawly.MobApp`,
  # `Scrawly.MobScreen`) plus anything else that references the `Mob`
  # library. Excluded from `:prod` because the `:mob` dep — and its
  # Android-only `mob_nif.so` — must not ship in the fly.io release
  # (the NIF's on_load handler crashes BEAM on Linux startup).
  defp elixirc_paths(:test), do: ["lib", "lib_mob", "test/support"]
  defp elixirc_paths(:prod), do: ["lib"]
  defp elixirc_paths(_), do: ["lib", "lib_mob"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:mob_dev, "~> 0.5", only: :dev, runtime: false},
      {:mob, "~> 0.5", only: :dev},
      {:mob_new, path: "/home/ken/mob_new", only: :dev, runtime: false},
      {:exqlite, "~> 0.36", only: :dev, runtime: false},
      {:usage_rules, "~> 1.2", only: [:dev]},
      {:hologram, "~> 0.8"},
      {:picosat_elixir, "~> 0.2"},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:tidewave, "~> 0.5", only: [:dev]},
      {:live_debugger, "~> 0.3", only: [:dev]},
      {:ash_ai, "~> 0.5"},
      {:langchain, "~> 0.3"},
      {:ash_admin, "~> 0.14"},
      {:ash_authentication_phoenix, "~> 2.15"},
      {:ash_authentication, "~> 4.13"},
      {:ash_postgres, "~> 2.8"},
      {:ash_phoenix, "~> 2.3"},
      {:ash, "~> 3.19"},
      {:igniter, "~> 0.7", only: [:dev, :test]},
      {:phoenix, "~> 1.8.0"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      "db.setup": ["ash_postgres.create", "ash_postgres.migrate", "run priv/repo/seeds.exs"],
      "db.reset": ["ash_postgres.drop", "db.setup"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind scrawly", "esbuild scrawly"],
      "assets.deploy": [
        "tailwind scrawly --minify",
        "esbuild scrawly --minify",
        "phx.digest"
      ],
      precommit: ["compile --warning-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  defp usage_rules do
    # Example for those using claude.
    [
      file: "CLAUDE.md",
      # rules to include directly in CLAUDE.md
      # use a regex to match multiple deps, or atoms/strings for specific ones
      # usage_rules: [:ash, ~r/^ash_/],
      # If your CLAUDE.md is getting too big, link instead of inlining:
      usage_rules: [:ash, {~r/^ash_/, link: :markdown}],
      # or use skills
      skills: [
        location: ".claude/skills",
        # build skills that combine multiple usage rules
        build: [
          "ash-framework": [
            # The description tells people how to use this skill.
            description:
              "Use this skill working with Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes.",
            # Include all Ash dependencies
            usage_rules: [:ash, ~r/^ash_/]
          ]
        ]
      ]
    ]
  end
end
