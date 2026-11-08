// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
// Independent testbench for aes_core (VARIANT 0), aes_core_secure (1) and
// aes_core_pipelined (2, encrypt only).
// Inputs are driven after the falling edge and DUT outputs are sampled 1 ns
// later; a transfer happens on the next rising edge if valid && ready were high.
//
// vectors.hex layout (scripts/gen_vectors.py), entries of {key, pt, ct}:
//   0..1 FIPS-197 B and C.1, 2..257 one key (C.1) with random blocks,
//   258..385 VarTxt (key 0), 386..513 VarKey, 514 zeros, 515 ones, 516.. random.
`timescale 1ns/1ps
module tb_vectors;
  parameter int VARIANT = 0;
  localparam int MAXV = 4096;
  localparam int FIXED_KEY_FIRST = 2, FIXED_KEY_LAST = 257;
  localparam int VARTXT_FIRST = 258, VARTXT_LAST = 385, RANDOM_FIRST = 516;

  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;
  longint cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  logic [127:0] key_i = '0, data_i = '0, random_i = '0, data_o;
  logic encrypt_i = 1, valid_i = 0, ready_i = 0, ready_o, valid_o, fault_o;
  wire clk_i = clk;

  generate
    if (VARIANT == 0) begin : g_dut
      aes_core dut (.clk_i, .rst_ni, .key_i, .data_i, .encrypt_i, .valid_i, .ready_o, .data_o, .valid_o, .ready_i);
      assign fault_o = 1'b0;
    end else if (VARIANT == 1) begin : g_dut
      aes_core_secure dut (.clk_i, .rst_ni, .key_i, .data_i, .encrypt_i, .valid_i, .random_i, .ready_o, .data_o,
                           .valid_o, .fault_o, .ready_i);
    end else begin : g_dut
      aes_core_pipelined dut (.clk_i, .rst_ni, .key_i, .data_i, .encrypt_i, .valid_i, .ready_o, .data_o, .valid_o, .ready_i);
      assign fault_o = 1'b0;
    end
  endgenerate

  logic [127:0] vec [0:3*MAXV-1];
  int nvec = 0, errors = 0, checks = 0;
  int lat_min [2] = '{1000, 1000};
  int lat_max [2] = '{0, 0};

  function automatic logic [127:0] rnd128();
    return {$urandom, $urandom, $urandom, $urandom};
  endfunction

  task automatic fail(input string what);
    errors++;
    if (errors <= 15) $display("FAIL %0s", what);
  endtask

  // valid_i is driven at random during reset: ready_o must stay low.
  task automatic reset(input int cycles);
    @(negedge clk); rst_ni = 0; ready_i = 0;
    #1;
    if (ready_o) fail("ready_o high in the cycle reset was asserted");
    repeat (cycles) begin
      valid_i = 1'($urandom_range(0, 1)); key_i = rnd128(); data_i = rnd128();
      @(negedge clk); #1;
      if (ready_o) fail("ready_o high during reset");
    end
    valid_i = 0;
    rst_ni = 1;
  endtask

  // ---------------- Iterative cores ----------------
  task automatic op(input logic [127:0] key, input logic [127:0] din, input logic enc,
                    output logic [127:0] dout);
    longint t0;
    logic [127:0] held;
    dout = 'x;
    repeat ($urandom_range(0, 2)) @(negedge clk);
    key_i = key; data_i = din; encrypt_i = enc; random_i = rnd128(); valid_i = 1;
    #1;
    while (!ready_o) begin @(negedge clk); #1; end
    @(posedge clk); t0 = cycle;
    @(negedge clk);
    valid_i = 0; key_i = rnd128(); data_i = rnd128(); encrypt_i = 1'($urandom_range(0, 1));
    #1;
    while (!valid_o) begin
      if (cycle - t0 > 200) begin fail("timeout waiting for valid_o"); return; end
      @(negedge clk); #1;
    end
    // cycles from the accepting edge to the edge that raised valid_o
    if (cycle - t0 - 1 < lat_min[enc]) lat_min[enc] = int'(cycle - t0 - 1);
    if (cycle - t0 - 1 > lat_max[enc]) lat_max[enc] = int'(cycle - t0 - 1);
    held = data_o;
    repeat ($urandom_range(0, 3)) begin
      @(negedge clk); #1;
      if (!valid_o || data_o !== held) fail("data_o/valid_o changed under back-pressure");
    end
    ready_i = 1;
    @(negedge clk);
    ready_i = 0;
    #1;
    if (valid_o) fail("valid_o still high after the output was consumed");
    if (fault_o) fail("fault_o set without a fault");
    dout = held;
  endtask

  task automatic run_iterative();
    logic [127:0] got;
    for (int i = 0; i < nvec; i++) begin
      op(vec[3*i], vec[3*i+1], 1'b1, got); checks++;
      if (got !== vec[3*i+2]) fail($sformatf("enc #%0d key=%h pt=%h got=%h exp=%h", i, vec[3*i], vec[3*i+1], got, vec[3*i+2]));
      op(vec[3*i], vec[3*i+2], 1'b0, got); checks++;
      if (got !== vec[3*i+1]) fail($sformatf("dec #%0d key=%h ct=%h got=%h exp=%h", i, vec[3*i], vec[3*i+2], got, vec[3*i+1]));
    end
    // Decrypt first (new key), then encrypt with the same key.
    for (int i = nvec - 1; i >= 0; i -= 3) begin
      op(vec[3*i], vec[3*i+2], 1'b0, got); checks++;
      if (got !== vec[3*i+1]) fail($sformatf("dec-first #%0d got=%h exp=%h", i, got, vec[3*i+1]));
      op(vec[3*i], vec[3*i+1], 1'b1, got); checks++;
      if (got !== vec[3*i+2]) fail($sformatf("enc-after-dec #%0d got=%h exp=%h", i, got, vec[3*i+2]));
    end
    for (int r = 0; r < 64; r++) begin
      int k = $urandom_range(0, nvec - 1);
      int rc = (r % 4) + 1;
      @(negedge clk); key_i = vec[3*k]; data_i = vec[3*k+1]; encrypt_i = r[0]; valid_i = 1;
      #1; while (!ready_o) begin @(negedge clk); #1; end
      @(negedge clk); valid_i = 0;
      repeat ($urandom_range(0, 24)) @(negedge clk);
      reset(rc);
      #1;
      if (valid_o) fail("valid_o high after reset");
      if (!ready_o) fail("ready_o low after reset");
      op(vec[3*k], vec[3*k+1], 1'b1, got); checks++;
      if (got !== vec[3*k+2]) fail($sformatf("enc after a %0d-cycle mid-op reset got=%h exp=%h", rc, got, vec[3*k+2]));
    end
  endtask

  // ---------------- Pipelined core ----------------
  // Streams vector indices first..last (cycling), with random gaps and back-pressure.
  task automatic stream(input string name, input int first, input int last, input int blocks,
                        input int bp_percent, input int gap_percent);
    int qi [$];
    int accepted = 0, consumed = 0, idx, bad = 0;
    longint t0 = cycle;
    logic s_ready, s_valid; logic [127:0] s_data, want;
    idx = first;
    while (consumed < blocks) begin
      @(negedge clk);
      valid_i = (accepted < blocks) && ($urandom_range(0, 99) >= gap_percent);
      key_i = vec[3*idx]; data_i = vec[3*idx+1]; encrypt_i = 1'b1;
      ready_i = ($urandom_range(0, 99) >= bp_percent);
      #1;
      s_ready = ready_o; s_valid = valid_o; s_data = data_o;
      if (valid_i && s_ready) begin
        qi.push_back(idx); accepted++;
        idx = (idx == last) ? first : idx + 1;
      end
      if (s_valid && ready_i) begin
        consumed++; checks++;
        if (qi.size() == 0) begin fail($sformatf("%0s: output with no accepted input", name)); bad++; end
        else begin
          want = vec[3*qi.pop_front()+2];
          if (s_data !== want) begin
            bad++;
            fail($sformatf("%0s: block %0d got=%h exp=%h", name, consumed, s_data, want));
          end
        end
      end
      if (cycle - t0 > 64 * blocks + 2000) begin fail($sformatf("%0s: timeout (%0d/%0d)", name, consumed, blocks)); break; end
    end
    @(negedge clk); valid_i = 0; ready_i = 0;
    $display("STREAM %0s: %0d blocks, %0d wrong, %0d cycles", name, consumed, bad, cycle - t0);
  endtask

  task automatic run_pipelined();
    stream("one key, no back-pressure", FIXED_KEY_FIRST, FIXED_KEY_LAST, 512, 0, 0);
    stream("one key, gaps and back-pressure", FIXED_KEY_FIRST, FIXED_KEY_LAST, 512, 30, 30);
    stream("zero key (VarTxt)", VARTXT_FIRST, VARTXT_LAST, 128, 0, 0);
    stream("new key every block", RANDOM_FIRST, RANDOM_FIRST + 255, 256, 0, 0);
    stream("new key every block, back-pressure", RANDOM_FIRST, RANDOM_FIRST + 255, 256, 30, 30);
    // Reset with a full pipeline and valid_i high, then stream again: no stale
    // output may appear and the next blocks must be correct.
    for (int r = 0; r < 8; r++) begin
      @(negedge clk); ready_i = 1;
      repeat (12 + r) begin
        valid_i = 1; key_i = vec[3*FIXED_KEY_FIRST]; data_i = rnd128();
        @(negedge clk);
      end
      reset((r % 3) + 1);
      #1;
      if (valid_o) fail("pipelined: valid_o high after reset");
      stream($sformatf("after reset %0d", r), FIXED_KEY_FIRST, FIXED_KEY_LAST, 32, 20, 20);
    end
  endtask

  initial begin
    $readmemh("vectors.hex", vec);
    for (int i = 0; i < MAXV; i++) begin
      if ($isunknown(vec[3*i]) || (vec[3*i] == 0 && vec[3*i+1] == 0 && vec[3*i+2] == 0)) break;
      nvec = i + 1;
    end
    $display("VARIANT=%0d vectors=%0d", VARIANT, nvec);
    reset(4);
    if (VARIANT == 2) run_pipelined(); else run_iterative();
    if (VARIANT == 2)
      $display("RESULT variant=%0d checks=%0d errors=%0d ", VARIANT, checks, errors);
    else
      $display("RESULT variant=%0d checks=%0d errors=%0d valid_o_after_enc=%0d..%0d valid_o_after_dec=%0d..%0d",
               VARIANT, checks, errors, lat_min[1], lat_max[1], lat_min[0], lat_max[0]);
    $finish;
  end
endmodule
