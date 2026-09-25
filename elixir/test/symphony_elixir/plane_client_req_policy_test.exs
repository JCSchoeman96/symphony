defmodule SymphonyElixir.PlaneClientReqPolicyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Plane.{Client, ReadScheduler}

  @config %{
    base_url: "https://api.plane.so",
    workspace_slug: "workspace-1",
    workspace_id: "workspace-id-1",
    project_id: "project-1",
    api_key: "secret"
  }

  setup do
    defaults = Req.default_options()
    on_exit(fn -> Req.default_options(defaults) end)
    :ok
  end

  test "uses an explicit raw, bounded and non-redirecting Req policy" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:request, request})

        response =
          Req.Response.new(
            status: 200,
            headers: [{"content-type", "application/json"}],
            body: ~s({"id":"project-1"})
          )

        {request, response}
      end
    )

    assert {:ok, %{"id" => "project-1"}} = Client.get_project(@config)
    assert_receive {:request, request}
    assert request.method == :get
    assert request.options[:compressed] == false
    assert request.options[:raw] == true
    assert request.options[:retry] == false
    assert request.options[:redirect] == false
    assert is_function(request.into, 2)
  end

  test "retries a transient provider failure once with Req retries disabled" do
    parent = self()
    {:ok, scheduler} = ReadScheduler.start_link(backoff_base_ms: 1, max_backoff_ms: 10)

    request_fun = fn request ->
      send(parent, {:request, request})
      {:ok, %{status: 503, headers: %{}, body: %{}}}
    end

    assert {:error, :provider_unavailable} =
             Client.get_project(@config, request_fun: request_fun, scheduler: scheduler)

    assert_receive {:request, _request}
    assert_receive {:request, _request}
    refute_receive {:request, _request}
  end

  test "does not retry a raw Req failure when the shared scheduler is bypassed" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:request, request})
        {request, Req.Response.new(status: 503, body: "{}")}
      end
    )

    assert {:error, :provider_unavailable} = Client.get_project(@config, scheduler: nil)
    assert_receive {:request, request}
    assert request.options[:retry] == false
    refute_receive {:request, _request}
  end

  test "does not follow provider redirects" do
    parent = self()

    Req.default_options(
      adapter: fn request ->
        send(parent, {:request, request})

        response =
          Req.Response.new(
            status: 302,
            headers: [{"location", "https://attacker.invalid"}],
            body: "{}"
          )

        {request, response}
      end
    )

    assert {:error, :provider_malformed} = Client.get_project(@config)
    assert_receive {:request, request}
    refute_receive {:request, _request}
    assert request.options[:redirect] == false
  end

  test "retains the bounded response accumulator with the real Req adapter" do
    Req.default_options(
      adapter: fn request ->
        response = Req.Response.new(status: 200, body: String.duplicate("x", 4_000_001))
        {request, response}
      end
    )

    assert {:error, :provider_response_too_large} = Client.get_project(@config)
  end
end
