# Changelog

## 1.1.1 (2026-11-09)

### Fixed

- `aes_core_secure`: the duplicated round counter was an identical copy of
  `round_q`. Quartus Prime merged the two registers, reported `fault_o` as
  stuck at GND and removed the fault detector from the netlist; simulation
  was not affected, which is why `make test-secure` passed. The copy is now
  stored inverted with its own decrement logic, and both counters and
  `fault_q` carry `keep`, `dont_touch` and `preserve` attributes. Quartus
  Prime Lite 25.1 and Vivado 2025.2 keep all three, and Quartus no longer
  reports `fault_o` as stuck. Quartus warns that it does not recognise
  `dont_touch`, which is meant for Vivado.

### Added

- `scripts/quartus_compile.tcl` and `scripts/vivado_compile.tcl`:
  out-of-context Quartus Prime and Vivado compiles of one core.
  `RESOURCE_ESTIMATES.md` lists the Cyclone V and Artix-7 area and Fmax of
  the three cores.

### Documentation

- `README.md` listed the v1.1.0 Yosys count of `aes_core_secure`; it now
  gives the v1.1.1 count (7284 LUT6, 311 MUXF7/8).
- `PORT_DESCRIPTION.md` said the RTL uses no vendor attributes; the secure
  core has used them since this release.

## 1.1.0 (2026-11-08)

A check of v1.0.0 against an independent reference found the basic and
secure cores functionally correct and the defects below.

### Fixed

- `aes_core_pipelined`: `ready_o` was high while a block with a new key
  arrived, but the block was not captured. The first block after every key
  change was dropped, every later result was paired with the wrong block, and
  a stream with a new key per block produced no output at all. A key change
  now waits for the pipeline to drain, so blocks never mix keys, and the
  all-zero key no longer re-expands the schedule on every block.
- All three cores: `ready_o` could be high during reset, so a block offered
  then looked accepted and was discarded. `ready_o` is now low while `rst_ni`
  is low.
- `make lint`, `make test` and `make test-secure` did not build on Verilator
  5.05x (multi-driven coverage flags, `VlWide` ports in the C++ harnesses).
- `make synth_report` wrote 0 LUT / 0 FF with current Yosys and counted only
  the top level on Xilinx; `make clean` deleted the committed
  `SYNTH_REPORT.md`.

### Changed

- `aes_core` reuses the stored key schedule when a block has the same key
  as the previous one: `valid_o` rises 10 cycles after the accepting edge
  instead of 20, and back-to-back blocks take 12 cycles instead of 22. A new
  key, and the first block after reset, still take 20 cycles.

### Added

- `make test-vectors`: an independent regression of all three cores against
  2516 vectors from the Python `cryptography` package (FIPS-197 B and C.1,
  VarTxt, VarKey, 2000 random), with back-pressure, key changes and resets.
- `make waves`: checked waveform scenarios rendered as zoomed timing plots
  (`docs/waves`).
- GitHub Actions CI running lint, the three test suites, the waveform
  scenarios and a check that `make synth_report` reproduces
  `SYNTH_REPORT.md`.

### Documentation

- Measured Yosys and nextpnr numbers replace the earlier figures. The basic
  core does not fit an iCE40 UP5K, as the documentation claimed, nor an
  HX8K; on ECP5 it needs a LFE5U-45F and runs at 32 - 35 MHz.
- The latency is stated exactly; the old texts said about 12 and 22 cycles.
- `aes_core_secure`: its per-block mask gives no power or EM protection, and
  the idle dummy operations it described do not exist. `SECURITY.md` and the
  RTL header now describe what it does: a fault-detecting round counter.
- The VHDL wrapper is only analysed with GHDL; it is not co-simulated.
- One reset cycle is enough; the four-cycle requirement is removed.

## 1.0.0

Initial release.
