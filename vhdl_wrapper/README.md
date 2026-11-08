# VHDL wrapper

`aes_core_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `aes_core` module under a VHDL-friendly interface. Use it from a
VHDL design that does not want to touch SystemVerilog directly.

## Status

**Wrapper only.** The cipher datapath (SubBytes, ShiftRows, MixColumns, key
schedule, FSM) lives in `rtl/*.sv` and is instantiated as a SystemVerilog
black-box, so the toolchain must support mixed-language elaboration. The
wrapper is analysed with GHDL (`make vhdl-test`); it has not been simulated
or synthesised together with the core. There is no VHDL implementation of
the cipher itself.

## Usage

### Vivado / Quartus / Diamond

Add both the SystemVerilog files and `aes_core_vhdl.vhd` to the same project
library (`work` is fine). The toolchain resolves the SV component
automatically:

```tcl
# Vivado
read_verilog -sv {rtl/aes_sbox.sv rtl/aes_inv_sbox.sv rtl/aes_key_expand.sv \
                  rtl/aes_round.sv rtl/aes_core.sv}
read_vhdl -vhdl2008 vhdl_wrapper/aes_core_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/aes_sbox.sv rtl/aes_inv_sbox.sv rtl/aes_key_expand.sv \
        rtl/aes_round.sv rtl/aes_core.sv
vcom -2008 vhdl_wrapper/aes_core_vhdl.vhd
```

### GHDL + Verilator (open source, analysis only)

`make vhdl-test` analyses the wrapper with GHDL and lints the SystemVerilog
core with Verilator. It does not run a mixed-language simulation; that needs
a simulator with mixed VHDL / SystemVerilog support.

```
make vhdl-test
```

The target is skipped with a notice if `ghdl` is not on `$PATH`.

## Instantiation example

```vhdl
library ieee;
  use ieee.std_logic_1164.all;

entity my_design is end entity;
architecture rtl of my_design is
  signal clk, rstn, valid_i, ready_o, valid_o, ready_i, encrypt_i : std_logic;
  signal key_i, data_i, data_o : std_logic_vector(127 downto 0);
begin
  u_aes : entity work.aes_core_vhdl
    port map (
      clk_i     => clk,
      rst_ni    => rstn,
      key_i     => key_i,
      data_i    => data_i,
      encrypt_i => encrypt_i,
      valid_i   => valid_i,
      ready_o   => ready_o,
      data_o    => data_o,
      valid_o   => valid_o,
      ready_i   => ready_i
    );
end architecture;
```

## What this wrapper does NOT change

* Latency, throughput, area: the wrapper adds no logic or pipeline stage;
  the behaviour is that of `aes_core.sv`.
* Endianness: bit 127 is byte 0, MSB-first, exactly as documented in
  `PORT_DESCRIPTION.md`.
* Reset polarity: still active-low synchronous (`rst_ni`).
