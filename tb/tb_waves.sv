// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// Waveform scenarios for scripts/plot_waves.py. Each run dumps one VCD.
//   SCEN 0  aes_core: a block with a new key, a block with the same key, an
//           output held by ready_i, then a decryption with the same key.
//   SCEN 1  aes_core: reset in the middle of an encryption, then a block.
//   SCEN 2  aes_core_pipelined: 6 blocks with one key, then 4 blocks with a
//           new key, with ready_i low for a few cycles.
// Expected results are FIPS-197 B / C.1 and the gen_vectors.py stream key;
// the testbench prints FAIL on a mismatch.
`timescale 1ns/1ps
module tb_waves;
  parameter int SCEN = 0;

  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;
  logic [127:0] key_i = '0, data_i = '0, data_o;
  logic encrypt_i = 1, valid_i = 0, ready_i = 0, ready_o, valid_o;
  wire  clk_i = clk;
  logic [3:0] dbg_state;   // aes_core: FSM state; pipelined: {expanding, valid of stages 0, 5, 10}
  int errors = 0;

  generate
    if (SCEN == 2) begin : g_dut
      aes_core_pipelined dut (.clk_i, .rst_ni, .key_i, .data_i, .encrypt_i, .valid_i, .ready_o, .data_o, .valid_o, .ready_i);
      assign dbg_state = {dut.expanding_q, dut.stage_v[0], dut.stage_v[5], dut.stage_v[10]};
    end else begin : g_dut
      aes_core dut (.clk_i, .rst_ni, .key_i, .data_i, .encrypt_i, .valid_i, .ready_o, .data_o, .valid_o, .ready_i);
      assign dbg_state = {2'b00, dut.state_q};
    end
  endgenerate

  localparam logic [127:0] KB = 128'h2b7e151628aed2a6abf7158809cf4f3c, PB = 128'h3243f6a8885a308d313198a2e0370734,
                           CB = 128'h3925841d02dc09fbdc118597196a0b32;
  localparam logic [127:0] KC = 128'h000102030405060708090a0b0c0d0e0f, PC = 128'h00112233445566778899aabbccddeeff,
                           CC = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
  localparam logic [127:0] PB2 = 128'h00000000000000000000000000000000, CB2 = 128'h7df76b0c1ab899b33e42f047b91b546f;

  task automatic op(input logic [127:0] key, input logic [127:0] din, input logic enc,
                    input int hold, input logic [127:0] want);
    @(negedge clk); key_i = key; data_i = din; encrypt_i = enc; valid_i = 1;
    #1; while (!ready_o) begin @(negedge clk); #1; end
    @(negedge clk); valid_i = 0; key_i = '0; data_i = '0;
    #1; while (!valid_o) begin @(negedge clk); #1; end
    repeat (hold) @(negedge clk);
    if (data_o !== want) begin errors++; $display("FAIL got=%h exp=%h", data_o, want); end
    ready_i = 1; @(negedge clk); ready_i = 0;
  endtask

  // Pipelined stream: drive blocks back to back; check the outputs in order.
  localparam int NS = 10;
  logic [127:0] sk [NS], sd [NS], sw [NS];   // stream keys, data, expected ciphertexts
  logic [127:0] exp_q [$];
  task automatic stream_all();
    for (int i = 0; i < NS; i++) begin
      @(negedge clk); key_i = sk[i]; data_i = sd[i]; valid_i = 1;
      #1; while (!ready_o) begin @(negedge clk); #1; end
      exp_q.push_back(sw[i]);
    end
    @(negedge clk); valid_i = 0;
  endtask
  logic [127:0] want;
  always @(negedge clk) begin
    #2;
    if (SCEN == 2 && valid_o && ready_i) begin
      if (exp_q.size() == 0) begin errors++; $display("FAIL output with nothing expected: %h", data_o); end
      else begin
        want = exp_q.pop_front();
        if (data_o !== want) begin errors++; $display("FAIL got=%h exp=%h", data_o, want); end
      end
    end
  end

  initial begin
    $dumpfile($sformatf("scen%0d.vcd", SCEN));
    $dumpvars(1, tb_waves);
    repeat (3) @(negedge clk);
    rst_ni = 1;
    if (SCEN == 0) begin
      ready_i = 0;
      op(KB, PB, 1'b1, 0, CB);     // new key: expansion + rounds
      op(KB, PB2, 1'b1, 3, CB2);   // same key, output held 3 cycles by ready_i
      op(KB, CB, 1'b0, 0, PB);     // decryption, same key
    end else if (SCEN == 1) begin
      @(negedge clk); key_i = KC; data_i = PC; encrypt_i = 1; valid_i = 1;
      @(negedge clk); valid_i = 0;
      repeat (14) @(negedge clk);
      rst_ni = 0; @(negedge clk); rst_ni = 1;
      op(KC, PC, 1'b1, 0, CC);
    end else begin
      for (int i = 0; i < 6; i++) sk[i] = KC;
      for (int i = 6; i < NS; i++) sk[i] = KB;
      sd[0] = PC; sd[1] = PB; sd[2] = PB2; sd[3] = CC; sd[4] = CB; sd[5] = KB;
      sd[6] = PB; sd[7] = PB2; sd[8] = PC; sd[9] = KC;
      sw[0] = CC;
      sw[1] = 128'h89ed5e6a05ca76338135085fe21c40bd; sw[2] = 128'hc6a13b37878f5b826f4f8162a1c8d879;
      sw[3] = 128'h4f638c735f614301567824b1a21a4f6a; sw[4] = 128'ha027f9e2d71ddb246c427651e47147d9;
      sw[5] = 128'h1ab729bb895c3bbacad01c3bdd830dc1;
      sw[6] = CB; sw[7] = CB2;
      sw[8] = 128'h8df4e9aac5c7573a27d8d055d6e4d64b; sw[9] = 128'h50fe67cc996d32b6da0937e99bafec60;
      ready_i = 1;
      fork
        stream_all();
        begin repeat (40) @(negedge clk); ready_i = 0; repeat (4) @(negedge clk); ready_i = 1; end
      join
      repeat (30) @(negedge clk);
    end
    repeat (4) @(negedge clk);
    $display("WAVES scen=%0d errors=%0d", SCEN, errors);
    $finish;
  end
endmodule
