Code.require_file("../support/a4/loopback_probe.exs", __DIR__)

defmodule SymphonyElixir.A4LoopbackTest do
  use ExUnit.Case, async: false

  test "the governed child cannot connect to the active proof helper" do
    evidence = SymphonyElixir.A4LoopbackProbe.run!()
    refute evidence.child_loopback_relay_reachable
    assert evidence.helper_connect_count == 0
    assert evidence.helper_terminated
  end
end
