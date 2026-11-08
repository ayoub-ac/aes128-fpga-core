// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Standalone assertion module for aes_core. Instantiated alongside the DUT in
// aes_core_tb so the testbench can reuse the same protocol checks regardless
// of which simulator runs them.
//
// Properties checked on every rising edge outside reset (5):
//   a_valid_after_req      valid_o is not seen before 11 edges after the most
//                          recent accepted block (10 cycles of rounds)
//   a_data_stable          data_o is stable while valid_o && !ready_i
//   a_valid_hold           valid_o is held until ready_i is seen
//   a_round_bound          the round counter never exceeds 10
//   a_no_ready_when_valid  ready_o is low while valid_o is high
//
// Checked with Verilator 5.053 (--assert). Properties are wrapped in
// `ifndef SYNTHESIS so they are stripped on synthesis flows.

module aes_core_assertions #(
  parameter int MIN_LATENCY = 11   // edges from acceptance to the first edge that sees valid_o (stored key)
) (
  input logic         clk_i,
  input logic         rst_ni,
  input logic         valid_i,
  input logic         ready_o,
  input logic         valid_o,
  input logic         ready_i,
  input logic [127:0] data_o,
  input logic [3:0]   round_q
);
`ifndef SYNTHESIS

  // Cycles since the last accepted command. Resets at every (valid_i && ready_o).
  // Synchronous reset to match the DUT's reset style.
  int unsigned cycles_since_accept;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                       cycles_since_accept <= 0;
    else if (valid_i && ready_o)       cycles_since_accept <= 1;
    else if (cycles_since_accept != 0) cycles_since_accept <= cycles_since_accept + 1;
  end

  // ---------------------------------------------------------------------------
  property p_valid_after_req;
    @(posedge clk_i) disable iff (!rst_ni)
      valid_o |-> (cycles_since_accept >= MIN_LATENCY);
  endproperty
  a_valid_after_req: assert property (p_valid_after_req)
    else $error("aes_core_assertions: valid_o asserted after only %0d cycles (<%0d)",
                cycles_since_accept, MIN_LATENCY);

  // ---------------------------------------------------------------------------
  property p_data_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (valid_o && !ready_i) |=> $stable(data_o);
  endproperty
  a_data_stable: assert property (p_data_stable)
    else $error("aes_core_assertions: data_o changed while back-pressured");

  // ---------------------------------------------------------------------------
  property p_valid_hold;
    @(posedge clk_i) disable iff (!rst_ni)
      (valid_o && !ready_i) |=> valid_o;
  endproperty
  a_valid_hold: assert property (p_valid_hold)
    else $error("aes_core_assertions: valid_o dropped before ready_i was seen");

  // ---------------------------------------------------------------------------
  property p_round_bound;
    @(posedge clk_i) disable iff (!rst_ni) (round_q <= 4'd10);
  endproperty
  a_round_bound: assert property (p_round_bound)
    else $error("aes_core_assertions: round_q exceeded 10 (got %0d)", round_q);

  // ---------------------------------------------------------------------------
  // ready_o and valid_o cannot both be high outside the back-to-back transition
  // (single-block core finishes via ready_i, then becomes ready). Allow either
  // ordering: in cycle N, valid_o && ready_i ; in cycle N+1, ready_o.
  property p_no_ready_when_valid;
    @(posedge clk_i) disable iff (!rst_ni)
      valid_o |-> !ready_o;
  endproperty
  a_no_ready_when_valid: assert property (p_no_ready_when_valid)
    else $error("aes_core_assertions: ready_o high simultaneously with valid_o");

`endif // SYNTHESIS
endmodule
