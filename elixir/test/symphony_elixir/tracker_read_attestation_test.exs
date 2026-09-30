defmodule SymphonyElixir.TrackerReadAttestationTest do
  use ExUnit.Case

  alias SymphonyElixir.Tracker
  alias SymphonyElixir.WorkControl.ProviderObservation

  @settings %{
    kind: "plane",
    api_key: "tracker-api-key-for-signing",
    endpoint: "https://api.plane.so",
    provider: %{
      "workspace_slug" => "workspace-1",
      "workspace_id" => "workspace-stable-1",
      "project_id" => "project-1",
      "api_key" => "$PLANE_API_KEY"
    },
    secret_environment_names: ["PLANE_API_KEY"]
  }

  setup do
    previous_signing_key = Application.get_env(:symphony_elixir, :completion_proof_signing_key)
    previous_plane_key = System.get_env("PLANE_API_KEY")
    Application.delete_env(:symphony_elixir, :completion_proof_signing_key)

    on_exit(fn ->
      if is_nil(previous_signing_key) do
        Application.delete_env(:symphony_elixir, :completion_proof_signing_key)
      else
        Application.put_env(:symphony_elixir, :completion_proof_signing_key, previous_signing_key)
      end

      if is_nil(previous_plane_key) do
        System.delete_env("PLANE_API_KEY")
      else
        System.put_env("PLANE_API_KEY", previous_plane_key)
      end
    end)

    :ok
  end

  test "Tracker derives the receipt key from Plane API credentials when configured" do
    assert {:ok, [issue]} = Tracker.fetch_issues_by_ids(["issue-1"], tracker_opts(@settings))
    assert %ProviderObservation{} = observation = issue.tracker_read_observation
    assert String.starts_with?(observation.tracker_read_signature, "sha256:")

    expected_key = :crypto.hash(:sha256, "symphony-tracker-read-v1:" <> @settings.api_key)
    payload = ProviderObservation.tracker_read_payload(observation)
    expected_signature = :crypto.mac(:hmac, :sha256, expected_key, payload)

    supplied_signature =
      observation.tracker_read_signature
      |> String.replace_prefix("sha256:", "")
      |> Base.decode16!(case: :lower)

    assert :crypto.hash_equals(supplied_signature, expected_signature)
  end

  test "ProviderObservation requires a Plane receipt key when verifying a signature" do
    observation = %ProviderObservation{
      tracker_read_signature: "sha256:" <> Base.encode16(<<0::256>>, case: :lower)
    }

    refute ProviderObservation.valid_tracker_read?(observation)
  end

  test "Tracker leaves Plane reads unattested when neither signing key is configured" do
    System.put_env("PLANE_API_KEY", "plane-adapter-key")
    settings = %{@settings | api_key: nil}

    assert {:ok, [issue]} = Tracker.fetch_issues_by_ids(["issue-1"], tracker_opts(settings))
    assert issue.tracker_read_observation == nil
  end

  defp tracker_opts(settings) do
    [
      tracker_settings: settings,
      request_fun: fn _request ->
        {:ok,
         %{
           status: 200,
           body: %{
             "id" => "issue-1",
             "name" => "Work",
             "state" => %{"id" => "state-done", "name" => "Done", "group" => "completed"},
             "project" => "project-1",
             "workspace" => "workspace-stable-1",
             "updated_at" => "2026-09-17T08:09:10Z"
           }
         }}
      end
    ]
  end
end
