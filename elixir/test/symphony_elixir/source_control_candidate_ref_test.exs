defmodule SymphonyElixir.SourceControl.CandidateRefTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.SourceControl.CandidateRef

  @sha_a String.duplicate("a", 40)
  @sha_b String.duplicate("b", 40)

  test "accepts a valid five-field candidate ref" do
    assert {:ok, ref} =
             CandidateRef.new(%{
               repository_identity: "github:repository:1368436395",
               base_sha: @sha_a,
               candidate_sha: @sha_b,
               pr_identity: "15",
               observed_pr_head_sha: @sha_b
             })

    assert ref.candidate_sha == ref.observed_pr_head_sha
    assert is_binary(CandidateRef.fingerprint(ref))
  end

  test "rejects malformed shas and repository identity" do
    assert {:error, :invalid_sha} =
             CandidateRef.new(%{
               repository_identity: "github:repository:1368436395",
               base_sha: "short",
               candidate_sha: @sha_b,
               pr_identity: "15",
               observed_pr_head_sha: @sha_b
             })

    assert {:error, :invalid_repository_identity} =
             CandidateRef.new(%{
               repository_identity: "symphony",
               base_sha: @sha_a,
               candidate_sha: @sha_b,
               pr_identity: "15",
               observed_pr_head_sha: @sha_b
             })
  end

  test "fingerprints and equality compare all five fields" do
    {:ok, left} =
      CandidateRef.new(%{
        repository_identity: "github:repository:1368436395",
        base_sha: @sha_a,
        candidate_sha: @sha_b,
        pr_identity: "15",
        observed_pr_head_sha: @sha_b
      })

    {:ok, right} = CandidateRef.new(Map.from_struct(left))
    assert CandidateRef.equal?(left, right)
    assert CandidateRef.fingerprint(left) == CandidateRef.fingerprint(right)
    assert CandidateRef.github_repository_identity(1_368_436_395) == "github:repository:1368436395"
  end

  test "accepts integer pr identity and normalizes sha casing" do
    assert {:ok, ref} =
             CandidateRef.new(%{
               repository_identity: "github:repository:1368436395",
               base_sha: String.upcase(@sha_a),
               candidate_sha: String.upcase(@sha_b),
               pr_identity: 15,
               observed_pr_head_sha: @sha_b
             })

    assert ref.pr_identity == "15"
    assert ref.base_sha == @sha_a
  end

  test "rejects invalid pr identity" do
    assert {:error, :invalid_pr_identity} =
             CandidateRef.new(%{
               repository_identity: "github:repository:1368436395",
               base_sha: @sha_a,
               candidate_sha: @sha_b,
               pr_identity: "not-a-number",
               observed_pr_head_sha: @sha_b
             })
  end

  test "rejects candidate and observed head mismatch" do
    assert {:error, :candidate_head_mismatch} =
             CandidateRef.new(%{
               repository_identity: "github:repository:1368436395",
               base_sha: @sha_a,
               candidate_sha: @sha_b,
               pr_identity: "15",
               observed_pr_head_sha: @sha_a
             })
  end
end
