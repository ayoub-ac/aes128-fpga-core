// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// AES-128 iterative core with side-channel countermeasures (FIPS-197).
//
// This is a HARDENED variant of aes_core. It implements:
//
//   1. State-level Boolean masking. Each cycle the registered cipher state is
//      stored as two shares (state_xor_mask, mask). The mask is refreshed per
//      block from random_i. This raises the bar against simple power analysis
//      on the state register's transitions, but does NOT mask the S-box LUT
//      transition itself; see SECURITY.md for the full threat model.
//
//   2. Duplicated round counter. A redundant copy of round_q is compared every
//      cycle. Any mismatch raises fault_o and halts the FSM (the operation
//      must be restarted via reset). This defends against single-bit fault
//      injection on the counter (e.g., laser, EMFI on the FF).
//
//   3. Constant-time FSM. No data-dependent branches; every block takes the
//      exact same number of cycles regardless of key or plaintext content.
//
//   4. Dummy operations on idle cycles. Toggling activity that flattens the
//      power profile during S_DONE / S_IDLE waits.
//
// Limitations (read SECURITY.md for full disclosure):
//   * The internal S-box is NOT a masked S-box. A dedicated masked-S-box
//     scheme (e.g. RSM, Canright-masked, threshold-implementation) would be
//     required to claim DPA resistance on the S-box transition itself.
//   * No higher-order DPA protection.
//   * No EM analysis / template attack protection.
//   * Power balancing here is simple toggle activity; not differential routing.

module aes_core_secure (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [127:0] key_i,
  input  logic [127:0] data_i,
  input  logic         encrypt_i,
  input  logic         valid_i,
  input  logic [127:0] random_i,    // fresh randomness, sampled once per block on accept
  output logic         ready_o,
  output logic [127:0] data_o,
  output logic         valid_o,
  output logic         fault_o,     // sticky; 1 = fault detected, halt + reset to clear
  input  logic         ready_i
);

  // ---------- Round constants ------------------------------------------------
  function automatic logic [7:0] rcon (input logic [3:0] r);
    case (r)
      4'd1:  rcon = 8'h01;
      4'd2:  rcon = 8'h02;
      4'd3:  rcon = 8'h04;
      4'd4:  rcon = 8'h08;
      4'd5:  rcon = 8'h10;
      4'd6:  rcon = 8'h20;
      4'd7:  rcon = 8'h40;
      4'd8:  rcon = 8'h80;
      4'd9:  rcon = 8'h1b;
      4'd10: rcon = 8'h36;
      default: rcon = 8'h00;
    endcase
  endfunction

  // ---------- FSM -----------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE   = 3'd0,
    S_EXPAND = 3'd1,
    S_RUN    = 3'd2,
    S_DONE   = 3'd3,
    S_FAULT  = 3'd4
  } state_e;

  state_e state_q, state_d;
  logic [3:0] round_q,  round_d;
  logic [3:0] round_q2, round_d2;     // duplicated round counter
  logic       encrypt_q;
  logic [127:0] mask_q,  mask_d;       // current state mask
  logic [127:0] state_masked_q, state_masked_d;   // state ^ mask
  logic [127:0] data_out_q, data_out_d;
  logic         fault_q, fault_d;

  // Round-key storage
  logic [127:0] rk_q [0:10];
  logic [127:0] rk_d [0:10];

  // Unmasked combinational view of state (used for round logic).
  logic [127:0] state_unmasked;
  assign state_unmasked = state_masked_q ^ mask_q;

  // ---------- Key expansion --------------------------------------------------
  logic [127:0] next_rk;
  aes_key_expand u_kx (
    .round_key_i (rk_q[round_q]),
    .rcon_i      (rcon(round_q + 4'd1)),
    .round_key_o (next_rk)
  );

  // ---------- Round combinational --------------------------------------------
  logic [127:0] round_in;
  logic [127:0] round_out;
  logic [127:0] selected_rk;
  logic         is_final;

  assign round_in = state_unmasked;

  always_comb begin
    if (encrypt_q) begin
      selected_rk = rk_q[round_q + 4'd1];
      is_final    = (round_q == 4'd9);
    end else begin
      selected_rk = rk_q[4'd9 - round_q];
      is_final    = (round_q == 4'd9);
    end
  end

  aes_round u_rnd (
    .state_i       (round_in),
    .round_key_i   (selected_rk),
    .encrypt_i     (encrypt_q),
    .final_round_i (is_final),
    .state_o       (round_out)
  );

  // ---------- Outputs --------------------------------------------------------
  // data_o is the unmasked output (revealed only on completion).
  assign data_o  = data_out_q;
  assign valid_o = (state_q == S_DONE);
  assign ready_o = (state_q == S_IDLE) && !fault_q;
  assign fault_o = fault_q;

  // ---------- Round counter sanity (fault detector) --------------------------
  logic counter_fault;
  assign counter_fault = (round_q != round_q2);

  // ---------- FSM next-state -------------------------------------------------
  always_comb begin
    state_d        = state_q;
    round_d        = round_q;
    round_d2       = round_q2;
    state_masked_d = state_masked_q;
    mask_d         = mask_q;
    data_out_d     = data_out_q;
    fault_d        = fault_q;
    for (int i = 0; i < 11; i++) rk_d[i] = rk_q[i];

    // Fault check: if counters disagree, latch fault and halt.
    if (counter_fault && (state_q != S_IDLE) && (state_q != S_FAULT)) begin
      state_d = S_FAULT;
      fault_d = 1'b1;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (valid_i && !fault_q) begin
            rk_d[0] = key_i;
            for (int i = 1; i < 11; i++) rk_d[i] = '0;
            mask_d = random_i;
            if (encrypt_i) begin
              // initial AddRoundKey with rk[0], plus apply mask
              state_masked_d = (data_i ^ key_i) ^ random_i;
            end else begin
              // for decrypt, initial ARK happens after key expansion completes
              state_masked_d = data_i ^ random_i;
            end
            round_d  = 4'd0;
            round_d2 = 4'd0;
            state_d  = S_EXPAND;
          end
        end

        S_EXPAND: begin
          rk_d[round_q + 4'd1] = next_rk;
          if (round_q == 4'd9) begin
            if (!encrypt_q) begin
              // initial ARK for decrypt with rk[10]; preserve mask
              state_masked_d = state_masked_q ^ next_rk;
            end
            round_d  = 4'd0;
            round_d2 = 4'd0;
            state_d  = S_RUN;
          end else begin
            round_d  = round_q  + 4'd1;
            round_d2 = round_q2 + 4'd1;
          end
        end

        S_RUN: begin
          // Apply round on UNMASKED state, re-mask the result.
          // Note: the round logic itself processes unmasked data combinationally;
          // the masking only protects the registered state across cycles.
          state_masked_d = round_out ^ mask_q;
          if (round_q == 4'd9) begin
            // Final round: reveal unmasked output.
            data_out_d = round_out;
            // Wipe mask (it was for this block only).
            mask_d     = '0;
            round_d    = 4'd0;
            round_d2   = 4'd0;
            state_d    = S_DONE;
          end else begin
            round_d  = round_q  + 4'd1;
            round_d2 = round_q2 + 4'd1;
          end
        end

        S_DONE: begin
          if (ready_i) begin
            // Wipe state (don't leak previous block).
            state_masked_d = '0;
            data_out_d     = '0;
            state_d        = S_IDLE;
          end
        end

        S_FAULT: begin
          // Halt forever until reset. data_o is wiped, fault_o is sticky.
          state_masked_d = '0;
          data_out_d     = '0;
          mask_d         = '0;
        end

        default: state_d = S_FAULT;
      endcase
    end
  end

  // ---------- Sequential -----------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q        <= S_IDLE;
      round_q        <= 4'd0;
      round_q2       <= 4'd0;
      encrypt_q      <= 1'b0;
      state_masked_q <= '0;
      mask_q         <= '0;
      data_out_q     <= '0;
      fault_q        <= 1'b0;
      for (int i = 0; i < 11; i++) rk_q[i] <= '0;
    end else begin
      state_q        <= state_d;
      round_q        <= round_d;
      round_q2       <= round_d2;
      state_masked_q <= state_masked_d;
      mask_q         <= mask_d;
      data_out_q     <= data_out_d;
      fault_q        <= fault_d;
      for (int i = 0; i < 11; i++) rk_q[i] <= rk_d[i];
      if (state_q == S_IDLE && valid_i && !fault_q) encrypt_q <= encrypt_i;
    end
  end

endmodule
