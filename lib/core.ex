defmodule TelemetryMetricsPrometheus.Core do
  @moduledoc """
  Prometheus Reporter for [`Telemetry.Metrics`](https://github.com/beam-telemetry/telemetry_metrics) definitions.

  Provide a list of metric definitions to the `init/2` function. It's recommended to
  initialize the reporter during application startup.

      def start(_type, _args) do
        TelemetryMetricsPrometheus.Core.init([
          counter("http.request.count"),
          sum("http.request.payload_size", unit: :byte),
          last_value("vm.memory.total", unit: :byte)
        ])

        # List all child processes to be supervised
        children = [
        ...
        ]

        opts = [strategy: :one_for_one, name: ExampleApp.Supervisor]
        Supervisor.start_link(children, opts)
      end

  Note that aggregations for distributions (histogram) only occur at scrape time.
  These aggregations only have to process events that have occurred since the last
  scrape, so it's recommended at this time to keep an eye on scrape durations if
  you're reporting a large number of disributions or you have a high tag cardinality.

  ## Telemetry.Metrics to Prometheus Equivalents

  Metric types:
    * Counter - Counter
    * Distribution - Histogram
    * LastValue - Gauge
    * Sum - Counter
    * Summary - Summary (Not supported)

  ### Units

  Prometheus recommends the usage of base units for compatibility - [Base Units](https://prometheus.io/docs/practices/naming/#base-units).
  This is simple to do with `:telemetry` and `Telemetry.Metrics` as all memory
  related measurements in the BEAM are reported in bytes and Metrics provides
  automatic time unit conversions.

  Note that measurement unit should used as part of the reported name in the case of
  histograms and gauges to Prometheus. As such, it is important to explicitly define
  the unit of measure for these types when the unit is time or memory related.

  It is suggested to not mix units, e.g. seconds with milliseconds.

  It is required to define your buckets according to the end unit translation
  since this measurements are converted at the time of handling the event, prior
  to bucketing.

  #### Memory

  Report memory as `:byte`.

  #### Time

  Report durations as `:second`. The BEAM and `:telemetry` events use `:native` time
  units. Converting to seconds is as simple as adding the conversion tuple for
  the unit - `{:native, :second}`

  ### Naming

  `Telemetry.Metrics` definition names do not translate easily to Prometheus naming
  conventions. By default, the name provided when creating your definition uses parts
  of the provided name to determine what event to listen to and which event measurement
  to use.

  For example, `"http.request.duration"` results in listening for  `[:http, :request]`
  events and use `:duration` from the event measurements. Prometheus would recommend
  a name of `http_request_duration_seconds` as a good name.

  It is therefore recommended to use the name in your definition to reflect the name
  you wish to see reported, e.g. `http.request.duration.seconds` or `[:http, :request, :duration, :seconds]` and use the `:event_name` override and `:measurement` options in your definition.

  Example:

      Metrics.distribution(
        "http.request.duration.seconds",
        buckets: [0.01, 0.025, 0.05, 0.1, 0.2, 0.5, 1],
        event_name: [:http, :request, :complete],
        measurement: :duration,
        unit: {:native, :second}
      )

  The exporter sanitizes names to Prometheus' requirements ([Metric Naming](https://prometheus.io/docs/instrumenting/writing_exporters/#naming)) and joins the event name parts with an underscore.

  ### Labels

  Labels in Prometheus are referred to as `:tags` in `Telemetry.Metrics` - see the docs
  for more information on tag usage.

  **Important: Each tag + value results in a separate time series. For distributions, this
  is further complicated as a time series is created for each bucket plus one for measurements
  exceeding the limit of the last bucket - `+Inf`.**

  It is recommended, but not required, to abide by Prometheus' best practices regarding labels -
  [Label Best Practices](https://prometheus.io/docs/practices/naming/#labels)

  """

  alias Telemetry.Metrics
  alias TelemetryMetricsPrometheus.Core.{Aggregator, Exporter, Registry, Router}

  require Logger

  @type metric ::
          Metrics.Counter.t()
          | Metrics.Distribution.t()
          | Metrics.LastValue.t()
          | Metrics.Sum.t()
          | Metrics.Summary.t()

  @type metrics :: [metric()]

  @type prometheus_options :: [prometheus_option()]

  @type prometheus_option ::
          {:name, atom()}
          | {:monitor_reporter, bool()}
          | {:validations, Registry.validation_opts() | false}

  @doc """
  Initializes a reporter instance with the provided `Telemetry.Metrics` definitions.

  Available options:
  * `:name` - name of the reporter instance. Defaults to `:prometheus_metrics`
  * `:monitor_reporter` - collects metrics on the reporter's ETS table usage. Defaults to `false`
  * `:validations` - Keyword options list to control validations. All validations can be disabled by setting `validations: false`.
    * `:consistent_units` - logs a warning when mixed time units are found in your definitions. Defaults to `true`
    * `:require_seconds` - logs a warning if units other than seconds are found in your definitions. Defaults to `true`
  """
  @spec init(metrics(), prometheus_options()) :: :ok
  def init(metrics, options \\ []) when is_list(metrics) and is_list(options) do
    with opts <- ensure_options(options),
         {:ok, _registry} <- init_registry(opts),
         :ok <- register_metrics(internal_metrics(), opts[:name], opts[:validations]),
         :ok <- register_metrics(metrics, opts[:name], opts[:validations]),
         config <- Registry.config(opts[:name]) do
      if opts[:monitor_reporter] do
        {:ok, _poller_id} =
          Registry.monitor_tables([config.aggregates_table_id, config.dist_table_id], opts[:name])
      end

      :ok
    end
  end

  @doc false
  def stop(_name) do
    # Stop everything for now. This can be refined later.
    DynamicSupervisor.which_children(__MODULE__.DynamicSupervisor)
    |> Enum.map(fn {:undefined, pid, _, _} ->
      DynamicSupervisor.terminate_child(__MODULE__.DynamicSupervisor, pid)
    end)
  end

  @doc """
  Returns a metrics scrape in Prometheus exposition format for the given reporter
  name - defaults to `:prometheus_metrics`.
  """
  @spec scrape(name :: atom()) :: String.t()
  def scrape(name \\ :prometheus_metrics) do
    config = Registry.config(name)
    metrics = Registry.metrics(name)

    :ok = Aggregator.aggregate(metrics, config.aggregates_table_id, config.dist_table_id)

    Aggregator.get_time_series(config.aggregates_table_id)
    |> Exporter.export(metrics)
  end

  @spec ensure_options(prometheus_options()) :: prometheus_options()
  defp ensure_options(options) do
    validation_opts = ensure_validation_options(Keyword.get(options, :validations, []))

    Keyword.merge(default_options(), options)
    |> Keyword.put(:validations, validation_opts)
  end

  @spec default_options() :: prometheus_options()
  defp default_options() do
    [
      name: :prometheus_metrics,
      monitor_reporter: false,
      validations: default_validation_options()
    ]
  end

  @spec ensure_validation_options(bool() | Registry.validation_opts()) ::
          Registry.validation_opts()
  defp ensure_validation_options(false), do: default_validation_options(false)

  defp ensure_validation_options(opts) do
    Keyword.merge(default_validation_options(), opts)
  end

  @spec default_validation_options(bool()) :: Registry.validation_opts()
  defp default_validation_options(on \\ true),
    do: [
      consistent_units: on,
      require_seconds: on
    ]

  @spec init_registry(keyword()) :: DynamicSupervisor.on_start_child()
  defp init_registry(opts) do
    DynamicSupervisor.start_child(__MODULE__.DynamicSupervisor, %{
      id: opts[:name],
      start: {Registry, :start_link, [opts]}
    })
  end

  @spec register_metrics(metrics(), atom(), Registry.validation_opts()) :: :ok
  defp register_metrics(metrics, name, validations) do
    metrics
    |> Registry.validate_units(validations)
    |> Enum.each(fn metric ->
      case Registry.register(metric, name) do
        :ok ->
          metric

        {:error, :already_exists, metric_name} ->
          Logger.warn(
            "Metric name already exists. Dropping measure. metric_name:=#{inspect(metric_name)}"
          )

        {:error, :unsupported_metric_type, metric_type} ->
          Logger.warn(
            "Metric type #{metric_type} is unsupported. Dropping measure. metric_name:=#{
              inspect(metric.name)
            }"
          )
      end
    end)
  end

  @spec internal_metrics() :: metrics()
  defp internal_metrics(),
    do: [
      Metrics.distribution("prometheus_metrics.scrape.duration.seconds",
        buckets: [0.05, 0.1, 0.2, 0.5, 1],
        description: "A histogram of the request duration for prometheus metrics scrape.",
        event_name: [:prometheus_metrics, :plug, :stop],
        measurement: :duration,
        tags: [:name],
        tag_values: fn %{conn: conn} ->
          %{name: conn.private[:prometheus_metrics_name]}
        end,
        unit: {:native, :second}
      ),
      Metrics.distribution("prometheus_metrics.aggregation.duration.seconds",
        buckets: [0.05, 0.1, 0.2, 0.5, 1.0],
        description: "A histogram of the duration for prometheus metrics aggregation",
        event_name: [:prometheus_metrics, :aggregation, :stop],
        measurement: :duration,
        tags: [:name],
        unit: {:native, :second}
      ),
      Metrics.last_value("prometheus_metrics.table.memory.bytes",
        description: "A gauge of the memory size of a prometheus metrics aggregation table",
        event_name: [:telemetry_metrics_prometheus, :table, :status],
        measurement: :memory,
        tags: [:name],
        unit: :byte
      ),
      Metrics.last_value("prometheus_metrics.table.size.total",
        description: "A gauge of the key count of a prometheus metrics aggregation table",
        event_name: [:telemetry_metrics_prometheus, :table, :status],
        measurement: :size,
        tags: [:name],
        unit: :byte
      )
    ]
end
