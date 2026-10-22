# Run this same capture against the authorized baseline and the A4 candidate.
alias SymphonyElixir.Plane.Client
config = %{base_url: "https://api.plane.so", workspace_slug: "workspace", workspace_id: "workspace-id", project_id: "project", api_key: "local-fixture"}
parent = self()

result =
  Client.update_work_item_state(config, "work-1", "state-1",
    request_fun: fn request ->
      send(parent, {:captured, request})
      {:ok, %{status: 204}}
    end
  )

receive do
  {:captured, request} ->
    # Only fixture values are recorded. This script never sends a network request.
    IO.puts(Jason.encode!(%{result: inspect(result), method: request.method, path: request.path, body: request.body, headers: Enum.map(request.headers, fn {key, value} -> [key, value] end)}))
after
  1000 -> raise "normal request was not observed"
end

if Process.whereis(SymphonyElixir.H100TransportProofFinch), do: raise("dormant proof Finch started")
