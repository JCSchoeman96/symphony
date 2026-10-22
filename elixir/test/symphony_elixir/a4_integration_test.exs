defmodule SymphonyElixir.A4IntegrationTest do
  use ExUnit.Case, async: false
  alias SymphonyElixir.Plane.Adapter

  test "safe proof binding uses exact encoded Plane mutation path without credentials" do
    settings = %{provider: %{workspace_slug: "a b", workspace_id: "workspace", project_id: "project"}, api_key: "never-export"}
    envelope = %{work_item_id: "work/1", target_provider_state_id: "state-1"}
    assert {:ok, binding} = Adapter.a4_binding(settings, envelope)
    assert binding.origin_base_url == "https://api.plane.so"
    assert binding.origin_authority == "api.plane.so:443"
    assert binding.method == "PATCH"
    assert binding.path == "/api/v1/workspaces/a%20b/projects/project/work-items/work%2F1/"
    assert binding.body_bytes == byte_size(Jason.encode!(%{"state" => "state-1"}))
    refute inspect(binding) =~ "never-export"
  end
end
