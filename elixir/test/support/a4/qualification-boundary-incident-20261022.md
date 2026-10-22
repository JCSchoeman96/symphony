# A4 qualification boundary incident

## Known evidence

- On 2026-10-22, the local dormant capture was run twice at the timeout case. The approximate local time window was 19:35 SAST. The capture did not record a per-request timestamp.
- The broken call had duplicate `request_fun` entries. The first was `nil`; the second was the intended local callback. `Keyword.get/2` selected the first value, so `Client` used its normal Req transport.
- The configured base URL was `https://api.plane.so`.
- The synthetic work item ID was `work-1`. The synthetic workspace slug was `workspace`, and the project ID was `project`.
- The fixture config set `api_key: "local-fixture"`. `Client` constructs the outgoing header as `X-API-Key: local-fixture`.
- One run returned `{:error, :not_found}`. `Client.normalize_mutation_response/1` maps HTTP status 404 to that result. The response body was not preserved in the output, so body receipt and contents are unknown.
- The earlier run failed while waiting for the intended callback and did not print the client result. The duplicate-option code path was the same. Local evidence cannot establish whether that run received a provider response.
- Provider logging and provider state are unknown. This record contains no evidence that a provider state changed.

## Root-cause trace

The original fixture passed `request_fun: nil` before `request_fun: fn request -> ... end`. `Client` reads the option with `Keyword.get/2`, which returns the first matching entry. A `nil` value selects `perform_mutation_request/3`, which built a PATCH for `/api/v1/workspaces/workspace/projects/project/work-items/work-1/` and used the normal Req transport.

The regression test preserves the duplicate option shape and verifies that qualification mode rejects it before transport selection. It uses a loopback URL so the red test cannot contact Plane.

## Disposition

The A4 qualification run is invalidated. No provider-side investigation or follow-up HTTP request is part of this remediation. Qualification must restart at Q1 against a new clean candidate after the local guard and regression pass.
