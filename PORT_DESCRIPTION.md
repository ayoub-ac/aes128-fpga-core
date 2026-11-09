# Port description

This document is the contract for `aes_core` and its two variants: bit
widths, polarity, timing and the handshake. Every timing statement below is
checked in simulation by `make test`, `make test-vectors` or `make waves`.

## Module declaration

```systemverilog
module aes_core (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [127:0] key_i,
  input  logic [127:0] data_i,
  input  logic         encrypt_i,
  input  logic         valid_i,
  output logic         ready_o,
  output logic [127:0] data_o,
  output logic         valid_o,
  input  logic         ready_i
);
```

## Pin-by-pin

| Signal      | Dir | Width | Description |
|-------------|-----|-------|-------------|
| `clk_i`     | in  | 1     | System clock. Every flop in the core samples on the rising edge. |
| `rst_ni`    | in  | 1     | Synchronous, active-low reset. One rising edge with `rst_ni` low resets the core; `ready_o` is low while `rst_ni` is low. |
| `key_i`     | in  | 128   | AES-128 key, sampled on the accepting edge. Bit 127 is the most significant bit of byte 0, as in FIPS-197. |
| `data_i`    | in  | 128   | Plaintext (`encrypt_i = 1`) or ciphertext (`encrypt_i = 0`). Same byte order as `key_i`. |
| `encrypt_i` | in  | 1     | 1 = encrypt, 0 = decrypt. Sampled with `valid_i`. |
| `valid_i`   | in  | 1     | A block is offered. It may be raised while `ready_o` is low; the transfer completes on the first rising edge where `ready_o` is also high. |
| `ready_o`   | out | 1     | The core accepts a block on this edge. |
| `data_o`    | out | 128   | Result. Held while `valid_o && !ready_i`. Not meaningful while `valid_o` is low. |
| `valid_o`   | out | 1     | A result is available and stays available until it is taken. |
| `ready_i`   | in  | 1     | The consumer takes the result on a rising edge where `valid_o && ready_i`. |

## Handshake

Both sides use the valid/ready rule of AXI-Stream: a transfer happens on a
rising edge where the sender's `valid` and the receiver's `ready` are both
high.

```
clk        _|‾|_|‾|_|‾|_|‾|_|‾|_
valid_i     0   1   1   0          block offered
ready_o     1   1   0   0          accepted on the 2nd edge, then busy
            ...
valid_o     0   0   1   1   0      result available
ready_i     0   0   0   1   0      taken on the 4th edge
data_o      -   -   D   D   -
```

The plots in [`docs/waves`](docs/waves) show the real waveforms, including
the cycle counts.

## Timing

`aes_core` (the iterative core):

- `valid_o` rises 10 cycles after the accepting edge when `key_i` equals the
  stored key, and 20 cycles after it otherwise (10 cycles of key expansion
  first). The result can be taken on the 11th (21st) edge.
- `ready_o` rises on the cycle after the result is taken, so back-to-back
  blocks with one key take 12 cycles each, and 22 cycles each when every
  block has a new key.
- The first block after a reset always expands its key.
- The cycle count depends only on whether the key changed, never on the key
  or data values.

`aes_core_secure` expands the key for every block: `valid_o` 20 cycles after
the accepting edge, 22 cycles per block back to back.

`aes_core_pipelined` (encrypt only, `encrypt_i` ignored):

- With the loaded key it accepts one block per cycle; `valid_o` for a block
  rises 10 cycles after its accepting edge.
- When `valid_o && !ready_i`, the whole pipeline holds and `ready_o` is low.
- A block with a different key is not accepted (`ready_o` low) until the
  blocks already in the pipeline have been taken; then the new key is
  expanded in 10 cycles and the block is accepted. Blocks never mix keys.
- `ready_o` depends combinationally on `key_i` and `ready_i`.

## Reset

- `rst_ni` is synchronous and active low. One rising edge with `rst_ni` low
  returns the core to idle; holding it longer is harmless.
- `ready_o` is low as long as `rst_ni` is low, in all three cores, so no
  block is accepted during reset. `valid_o` is low from the first rising
  edge with `rst_ni` low.
- A reset discards the block in progress and the stored key schedule.

## Byte order

A 128-bit AES block is written as 16 bytes from left to right. Byte 0 (the
leftmost byte of the usual hex string) is in bits `[127:120]` and byte 15 in
bits `[7:0]`, as in FIPS-197.

```
plaintext  = 0x6bc1bee22e409f96e93d7e117393172a      (SP 800-38A F.1.1 #1)
               ^^ byte 0 -> [127:120]        ^^ byte 15 -> [7:0]
```

Swap the bytes before `data_i` if your bus is little-endian.

## Clock domain

One clock domain: `clk_i` clocks every flop. In a multi-clock system, put the
core in its own domain and cross with a CDC FIFO.

## Synthesis

The only vendor attributes are in `aes_core_secure`: `keep`, `dont_touch`
and `preserve` on the fault-detection registers, so that synthesis does not
merge or remove them (see [`SECURITY.md`](SECURITY.md)). Yosys 0.70
synthesises all three cores for iCE40, ECP5 and Xilinx 7-series
(`make synth_report`, `make synth-secure`, `make synth-pipelined`); Quartus
Prime Lite and Vivado place and route them out of context
(`scripts/quartus_compile.tcl`, `scripts/vivado_compile.tcl`). The S-boxes
are `case` tables, which every tool maps to LUTs. Numbers are in
[`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md) and
[`README.md`](README.md#measured-numbers).
