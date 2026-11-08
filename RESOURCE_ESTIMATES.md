# Resources and timing

All numbers below were measured with the OSS CAD Suite 2026-11-01 build
(Yosys 0.70, nextpnr 0.11) on the v1.1.0 RTL. Synthesis counts are flattened
and taken before place and route. Vivado, Quartus and Diamond were not run.

## Synthesis (Yosys)

| Core | Target | LUT | MUX cells | FF | Block RAM |
|---|---|---|---|---|---|
| `aes_core` | iCE40 (`synth_ice40`) | 7902 SB_LUT4 | - | 1674 | 32 SB_RAM40_4K |
| `aes_core` | ECP5 (`synth_ecp5 -abc9`) | 25086 LUT4 | 12313 PFUMX / L6MUX21 | 1930 | 0 |
| `aes_core` | Xilinx 7-series (`synth_xilinx -flatten`) | 5437 LUT1-6 | 537 MUXF7 / MUXF8 | 1930 | 0 |
| `aes_core_secure` | Xilinx 7-series | 7055 LUT1-6 | 274 MUXF7 / MUXF8 | 1805 | 0 |
| `aes_core_pipelined` | Xilinx 7-series | 11538 LUT1-6 | 2490 MUXF7 / MUXF8 | 4757 | 0 |

Reproduce with `make synth_report` (basic core, writes `SYNTH_REPORT.md`),
`make synth-secure` and `make synth-pipelined`.

ABC, the logic optimiser inside Yosys, gives results that move by a few
percent with small RTL changes: an earlier revision of the same branch
synthesised `aes_core` to 24113 LUT4 on ECP5 and 7534 on iCE40.

## Device fit

| Device | Capacity | `aes_core` |
|---|---|---|
| iCE40 UP5K | 5280 LUT4, 30 RAM blocks | does not fit |
| iCE40 HX8K | 7680 LUT4, 32 RAM blocks | does not fit (103 % of the LUTs) |
| ECP5 LFE5U-25F | 24288 LUT4 | does not fit (103 %); an earlier revision placed at 99 % |
| ECP5 LFE5U-45F | 43848 LUT4 | places at 57 % |
| Artix-7 xc7a35t | 20800 LUT6 | not placed (Yosys count 5437 LUT) |

## Place and route (nextpnr-ecp5)

`aes_core`, LFE5U-45F, CABGA381 package, out of context, 50 MHz target,
seeds 1 to 3:

| Seed | Fmax |
|---|---|
| 1 | 34.57 MHz |
| 2 | 33.52 MHz |
| 3 | 32.21 MHz |

The 50 MHz target is not met. In the nextpnr critical-path report (seed 1)
the path starts at the round counter and the state register, runs through
the round-key selection and the S-boxes of `aes_round`, and ends at the
state and output registers.
iCE40 and Xilinx were not placed and routed. The 391 I/O bits of the core
are left unplaced (`--out-of-context`); a real design adds its own I/O.

## Throughput

Cycle counts are measured in simulation; the Mbit/s figures are computed
from them and from the ECP5 Fmax above, not measured on hardware.

| Core | Cycles per block, back to back | At 33 MHz |
|---|---|---|
| `aes_core`, one key | 12 | about 350 Mbit/s |
| `aes_core`, a new key every block | 22 | about 190 Mbit/s |
| `aes_core_secure` | 22 | about 190 Mbit/s |
| `aes_core_pipelined`, one key | 1 | not placed |

## What dominates the area

- 36 table S-boxes: 16 forward and 16 inverse in the shared round, and 4 in
  the key expansion. Each is a 256-entry `case` table. On iCE40 Yosys puts
  the 32 round S-boxes in the 32 block RAMs; everywhere else they become
  LUTs.
- The 11 x 128-bit round-key store (1408 flip-flops) and the 11:1 selection
  of the round key.
- MixColumns and InvMixColumns, written as `xtime` chains.

Ways to make it smaller, none of which is implemented: one S-box set shared
by encryption and decryption (a GF(2^8) inverter with the forward and inverse
affine maps), a column-serial datapath, or expanding round keys on the fly
for encryption only.

## Power

Not characterised.
