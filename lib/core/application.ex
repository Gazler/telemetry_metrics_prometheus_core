defmodule TelemetryMetricsPrometheus.Core.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {DynamicSupervisor,
       strategy: :one_for_one, name: TelemetryMetricsPrometheus.Core.DynamicSupervisor}
    ]

    opts = [strategy: :one_for_one, name: TelemetryMetricsPrometheus.Core.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
