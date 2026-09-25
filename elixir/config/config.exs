import Config

config :logger, :default_formatter,
  metadata: [
    :attempt,
    :backoff_count,
    :duration_ms,
    :edge_count,
    :epoch_id,
    :finished_at,
    :item_count,
    :logical_requests,
    :attempts,
    :peak_concurrency,
    :rate_limit_remaining,
    :rate_limit_reset_at,
    :reason,
    :request_class,
    :retry_after_seconds,
    :scc_pass_count,
    :started_at,
    :throttle_count,
    :total_backoff_ms
  ]

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  config :symphony_elixir,
    workflow_file_path: Path.expand("../test/fixtures/startup_workflow.md", __DIR__)
end
