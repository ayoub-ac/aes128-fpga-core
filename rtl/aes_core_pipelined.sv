// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// AES-128 fully unrolled pipelined core (FIPS-197).
//
// Architecture: 11-stage pipeline (1 stage per round + initial AddRoundKey).
//   Steady-state throughput: one block per cycle.
//   Latency: 11 cycles (initial ARK + 10 rounds) plus 1 cycle for input register.
//   The key schedule is precomputed once when key changes; while the schedule is
//   being built, valid_i is held back via ready_o.
//
// Trade-off: ~10x area vs the iterative core, ~10x throughput.
//
// Limitation in this build: encrypt-only. Decrypt uses the iterative core.
// (The pipelined decrypt path is symmetric but doubles the area again.)
//
// Same I/O contract as aes_core, except:
//   * encrypt_i is ignored (always encrypt). Provided to keep the port wide-compatible.
//   * latency is 11 cycles when key is stable; +10 cycles only on key change.

module aes_core_pipelined (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [127:0] key_i,
  input  logic [127:0] data_i,
  input  logic         encrypt_i,   // ignored, always encrypt
  input  logic         valid_i,
  output logic         ready_o,
  output logic [127:0] data_o,
  output logic         valid_o,
  input  logic         ready_i
);

  // unused — silence linter
  logic                unused_encrypt;
  assign unused_encrypt = encrypt_i;

  // ---------- Round-key schedule (precomputed) -----------------------------
  // 11 round keys. When key_i changes (detected by compare to last accepted),
  // we expand all 10 keys over 10 cycles and stall valid_i.
  logic [127:0] rk [0:10];
  logic [127:0] last_key_q;
  logic         schedule_ready_q;
  logic [3:0]   expand_q;
  logic [127:0] expand_rcon;

  // Same rcon table as iterative core
  function automatic logic [7:0] rcon_byte (input logic [3:0] r);
    case (r)
      4'd1: rcon_byte = 8'h01; 4'd2: rcon_byte = 8'h02; 4'd3: rcon_byte = 8'h04;
      4'd4: rcon_byte = 8'h08; 4'd5: rcon_byte = 8'h10; 4'd6: rcon_byte = 8'h20;
      4'd7: rcon_byte = 8'h40; 4'd8: rcon_byte = 8'h80; 4'd9: rcon_byte = 8'h1b;
      4'd10: rcon_byte = 8'h36; default: rcon_byte = 8'h00;
    endcase
  endfunction

  logic [127:0] kx_in, kx_out;
  assign kx_in = rk[expand_q];
  aes_key_expand u_kx (
    .round_key_i (kx_in),
    .rcon_i      (rcon_byte(expand_q + 4'd1)),
    .round_key_o (kx_out)
  );

  // ---------- Pipeline registers --------------------------------------------
  // stage 0: input + AddRoundKey with rk[0] (registered)
  // stages 1..10: full round (registered output)
  logic [127:0] stage_q [0:10];
  logic         stage_v [0:10];

  // Combinational round outputs for stages 1..10
  logic [127:0] round_out [1:10];
  genvar gs;
  generate
    for (gs = 1; gs <= 10; gs++) begin : g_round
      aes_round u_r (
        .state_i       (stage_q[gs-1]),
        .round_key_i   (rk[gs]),
        .encrypt_i     (1'b1),
        .final_round_i (gs == 10),
        .state_o       (round_out[gs])
      );
    end
  endgenerate

  // ---------- Output ---------------------------------------------------------
  assign data_o  = stage_q[10];
  assign valid_o = stage_v[10];
  assign ready_o = schedule_ready_q & (~stage_v[10] | ready_i);

  // ---------- Sequential -----------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      schedule_ready_q <= 1'b0;
      expand_q         <= 4'd0;
      last_key_q       <= '0;
      for (int i = 0; i <= 10; i++) begin
        rk[i]      <= '0;
        stage_q[i] <= '0;
        stage_v[i] <= 1'b0;
      end
    end else begin
      // Key schedule machine: when key changes, restart expansion.
      if (valid_i && (key_i != last_key_q) && (expand_q == 4'd0) && schedule_ready_q) begin
        rk[0]            <= key_i;
        last_key_q       <= key_i;
        schedule_ready_q <= 1'b0;
        expand_q         <= 4'd0;
      end else if (!schedule_ready_q) begin
        rk[expand_q + 4'd1] <= kx_out;
        if (expand_q == 4'd9) begin
          schedule_ready_q <= 1'b1;
          expand_q         <= 4'd0;
        end else begin
          expand_q <= expand_q + 4'd1;
        end
      end else if (valid_i && (last_key_q == '0) && (rk[0] == '0)) begin
        // Cold-start: first key ever
        rk[0]      <= key_i;
        last_key_q <= key_i;
        schedule_ready_q <= 1'b0;
        expand_q   <= 4'd0;
      end

      // Pipeline advance — only when downstream can accept (ready_i high or stage 10 empty).
      if (~stage_v[10] | ready_i) begin
        // stage 0
        if (valid_i && schedule_ready_q && (key_i == last_key_q)) begin
          stage_q[0] <= data_i ^ rk[0];
          stage_v[0] <= 1'b1;
        end else begin
          stage_v[0] <= 1'b0;
        end
        // stages 1..10
        for (int i = 1; i <= 10; i++) begin
          stage_q[i] <= round_out[i];
          stage_v[i] <= stage_v[i-1];
        end
      end
    end
  end

endmodule
