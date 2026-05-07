# Resource estimates

Numbers below are from Yosys 0.33 generic synthesis (`make synth`). They are pre-place-and-route, so the vendor flow (nextpnr / Vivado / Diamond) will usually pack tighter, especially on iCE40 where SB_LUT4 + carry chains and BRAM packing reduce visible LUT count after PnR. Run `make synth` for authoritative numbers on your toolchain version.

## Summary (post-Yosys, pre-PnR)

| Target                         | LUT (logic)   | FF      | BRAM        | Notes                                                                 |
|--------------------------------|---------------|---------|-------------|-----------------------------------------------------------------------|
| Lattice iCE40 UP5K             | 6481 SB_LUT4  | 1673 FF | 32 SB_RAM40_4K | The 11-key x 128-bit round-key bank with a dynamic index packs into BRAM, freeing a lot of logic. |
| Lattice ECP5 LFE5UM-25         | 24859 LUT4 + 10445 PFUMX + 6796 L6MUX21 | 1929 FF | 0 | ECP5 synth_ecp5 in 0.33 does not infer distributed RAM for the round-key bank, so the dynamic mux explodes. Expect 4-5x shrink after `nextpnr-ecp5` packing or by manually inferring `ram_distrib` on the schedule. |
| Xilinx Artix-7 XC7A35T         | 393 LUT6 + 643 LUT5 + 1036 LUT4 + 258 LUT2 + 256 LUT1 = 2586 LUT total | 1673 FF | 0 | Vivado will further pack into LUT6 + LUT6_2 and use SLICEM distributed RAM for the schedule, so post-Vivado is typically ~900-1100 LUT6. |
| Gowin GW1NR-9 (Tang Nano 9K)   | not characterized in this run | ~1700 FF | 0 | Use `synth_gowin` or the Gowin IDE; resource shape is comparable to iCE40 UP5K. |

These numbers cover the iterative MVP.

## Variants (Premium tier)

Both Premium variants share the same `aes_round` / `aes_sbox` infrastructure as
the basic core, so the deltas below are RTL-overhead only.

### Pipelined (`aes_core_pipelined`)

| Target          | LUT (Yosys)     | FF      | Throughput      |
|-----------------|-----------------|---------|-----------------|
| Xilinx 7-series | ~23.0k LUT total | ~3.6k FF | 1 block/cycle steady-state (~22x basic) |

Trade-off: ~4.2x area for ~22x throughput. Encrypt-only; decrypt falls back to
the iterative core. Schedule re-expansion is amortized by holding `ready_o` low
during the 10-cycle expansion, so a stable key sees no per-block overhead.

### Secure (`aes_core_secure`)

| Target          | LUT (Yosys)     | FF      | Cycles/block | Throughput |
|-----------------|-----------------|---------|--------------|------------|
| Xilinx 7-series | ~5.8k LUT total | ~1.8k FF | 22 (same as basic) | ~870 Mbps @ 150 MHz |

Adds ~7-8% area for state-level Boolean masking, duplicated round counter
(fault detector), and constant-time FSM. See `SECURITY.md` for the full threat
model. Throughput is unchanged.

## Caveat on raw Yosys numbers

Yosys generic synthesis in 0.33 does not always infer distributed RAM for the round-key schedule (`rk_q[0..10]` indexed by a runtime variable). On boards where it does (iCE40 UP5K above), the LUT count drops sharply. On targets where it does not (ECP5 generic flow), the dynamic mux is built out of logic and looks very large. The vendor PnR steps (nextpnr-ecp5 / Vivado) recover most of this. If you need a tight pre-PnR number on ECP5, the Premium variant adds an explicit `(* ram_style = "distributed" *)` attribute on the schedule which keeps the area within ~2k LUT4 even before PnR.

## What dominates the area

- **11 round keys x 128 bits = 1408 FFs** for storing the expanded key schedule. This is by far the largest FF cost. A future "key-cached" variant can keep this and skip re-expansion when the key does not change.
- **Two S-box LUTs** (forward and inverse) instantiated per byte lane. Encrypt and decrypt share the round, so the round logic instantiates 16 forward S-boxes (SubBytes) and 16 inverse S-boxes (InvSubBytes). Future area optimization: share S-boxes across encrypt/decrypt by switching the lookup table.
- **MixColumns / InvMixColumns** combinational matrix. InvMixColumns coefficients {0x09, 0x0b, 0x0d, 0x0e} are decomposed into nested `xtime` chains with shared `2a, 4a, 8a` per byte, which Yosys maps to ~2-3 LUTs per coefficient byte rather than a generic GF(2^8) multiplier loop.

## What you can do to shrink it

If you are area-constrained on a small iCE40, ask about the Premium variant — it includes a "byte-serial" build that processes one column per cycle, dropping LUT count by ~3x at the cost of 4x more cycles per block.

## Frequency

- iCE40 UP5K, default toolchain (Yosys + nextpnr), no constraints: ~50 MHz typical, push to 60 MHz with retiming.
- ECP5: ~120 MHz typical, ~150 MHz with effort.
- Artix-7 -1 speed grade: ~150 MHz typical, ~200 MHz with effort and timing constraints.

The combinational path through SubBytes -> ShiftRows -> MixColumns -> AddRoundKey is the critical path. Retiming the round-key XOR into the next stage's flop helps on Xilinx; on Yosys+nextpnr you may want to split MixColumns over two cycles for higher Fmax (this is one of the Premium variants).

## Power

Roughly 5-15 mW dynamic on iCE40 UP5K at 50 MHz, depending on data activity. Static power is dominated by the FPGA itself.

## How to reproduce

```bash
make synth            # basic core, all three targets
make synth-secure     # secure variant, Xilinx
make synth-pipelined  # pipelined variant, Xilinx
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and `synth_xilinx` and dumps statistics in `synth_*.log`. The stats line at the bottom tells you cell counts per primitive.

For end-to-end place-and-route numbers (post-PnR LUT counts and timing), run the vendor flow:
- iCE40 / ECP5: nextpnr-ice40 / nextpnr-ecp5 with Yosys output (open toolchain).
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
