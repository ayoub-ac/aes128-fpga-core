// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// AES-128 fully unrolled pipelined core (FIPS-197), encrypt only.
//
// Architecture: stage 0 registers data ^ round key 0, stages 1..10 each
// register one round. With a stable key the core accepts one block per cycle
// and valid_o rises 10 cycles after the block is accepted.
//
// Key schedule: the 11 round keys are expanded once per key, over 10 cycles.
// A block with a key that differs from the loaded one is not accepted
// (ready_o low) until the pipeline has drained, so blocks already in flight
// finish with their own key; then the new schedule is expanded and the block
// is accepted. A key change therefore costs the drain time plus 10 cycles.
//
// Handshake: a block is accepted on a rising edge where valid_i && ready_o.
// ready_o depends combinationally on key_i and ready_i.
// data_o is held while valid_o && !ready_i (the whole pipeline stalls).
// encrypt_i is ignored.

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

  logic unused_encrypt;
  assign unused_encrypt = encrypt_i;

  function automatic logic [7:0] rcon_byte (input logic [3:0] r);
    case (r)
      4'd1: rcon_byte = 8'h01; 4'd2: rcon_byte = 8'h02; 4'd3: rcon_byte = 8'h04;
      4'd4: rcon_byte = 8'h08; 4'd5: rcon_byte = 8'h10; 4'd6: rcon_byte = 8'h20;
      4'd7: rcon_byte = 8'h40; 4'd8: rcon_byte = 8'h80; 4'd9: rcon_byte = 8'h1b;
      4'd10: rcon_byte = 8'h36; default: rcon_byte = 8'h00;
    endcase
  endfunction

  // ---------- Round-key schedule --------------------------------------------
  logic [127:0] rk [0:10];
  logic         key_loaded_q;   // rk[0] holds a key accepted since reset
  logic         expanding_q;    // rk[1..10] being computed
  logic [3:0]   expand_q;

  logic [127:0] kx_out;
  aes_key_expand u_kx (
    .round_key_i (rk[expand_q]),
    .rcon_i      (rcon_byte(expand_q + 4'd1)),
    .round_key_o (kx_out)
  );

  // ---------- Pipeline -------------------------------------------------------
  logic [127:0] stage_q [0:10];
  logic         stage_v [0:10];

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

  logic pipe_empty;
  always_comb begin
    pipe_empty = 1'b1;
    for (int i = 0; i <= 10; i++) if (stage_v[i]) pipe_empty = 1'b0;
  end

  logic advance, key_match, start_expand;
  assign advance      = !stage_v[10] || ready_i;
  assign key_match    = key_loaded_q && (key_i == rk[0]);
  assign ready_o      = !expanding_q && key_match && advance;
  assign start_expand = valid_i && !expanding_q && !key_match && pipe_empty;

  assign data_o  = stage_q[10];
  assign valid_o = stage_v[10];

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      key_loaded_q <= 1'b0;
      expanding_q  <= 1'b0;
      expand_q     <= 4'd0;
      for (int i = 0; i <= 10; i++) begin
        rk[i]      <= '0;
        stage_q[i] <= '0;
        stage_v[i] <= 1'b0;
      end
    end else begin
      if (start_expand) begin
        rk[0]        <= key_i;
        key_loaded_q <= 1'b1;
        expanding_q  <= 1'b1;
        expand_q     <= 4'd0;
      end else if (expanding_q) begin
        rk[expand_q + 4'd1] <= kx_out;
        if (expand_q == 4'd9) begin
          expanding_q <= 1'b0;
          expand_q    <= 4'd0;
        end else begin
          expand_q <= expand_q + 4'd1;
        end
      end

      if (advance) begin
        stage_v[0] <= valid_i && ready_o;
        if (valid_i && ready_o) stage_q[0] <= data_i ^ rk[0];
        for (int i = 1; i <= 10; i++) begin
          stage_q[i] <= round_out[i];
          stage_v[i] <= stage_v[i-1];
        end
      end
    end
  end

endmodule
