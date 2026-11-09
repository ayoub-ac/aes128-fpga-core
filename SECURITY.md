# Security model

This document states what the cores do and do not protect. In short:
**none of the three cores is protected against side-channel analysis**.
`aes_core_secure` adds fault detection on its round counter and nothing
else of security value. If your threat model includes power, EM or fault
attacks, this core is not enough.

## Functional correctness

All three cores match the FIPS-197 algorithm in simulation: FIPS-197
Appendix B and C.1, SP 800-38A F.1.1, the VarTxt and VarKey sweeps and
2000 random vectors from OpenSSL (through the Python `cryptography`
package), in both directions for the iterative cores (`make test`,
`make test-secure`, `make test-vectors`). This is not a NIST CAVP
validation, and nothing has been run on hardware.

## aes_core_secure

### Duplicated round counter (what it provides)

The round counter exists twice: `round_q`, and `round_n_q`, which holds the
inverted count and is decremented by its own logic. Outside `S_IDLE` the two
are compared every cycle; a mismatch moves the FSM to `S_FAULT`, sets the
sticky `fault_o`, clears `data_o` and the state, and holds `ready_o` low until
reset. `make test-secure` flips a bit of `round_n_q` in the middle of an
operation and checks `fault_o`, the halt and the recovery after reset.

The two copies must survive synthesis. In v1.1.0 the copy was identical to
`round_q`; Quartus Prime merged the duplicate registers and reported
`fault_o` stuck at GND, so the detector did not exist in the netlist. Since
v1.1.1 the copy is encoded differently and both counters and `fault_q` carry
`keep`, `dont_touch` and `preserve` attributes. Quartus Prime Lite 25.1
(Cyclone V) now keeps `round_q`, `round_n_q` and `fault_q` and no longer
reports `fault_o` as stuck. Vivado 2025.2 (Artix-7) keeps them as well: four
flip-flops for each of the two counters, plus `fault_q`, which drives
`fault_o`. If you use another tool,
check its report for removed or merged registers before relying on
`fault_o`.

It detects a fault that changes one counter copy. It does not detect the
same fault on both copies, or faults on the state register, the key store or
the FSM state, which are not duplicated; differential fault attacks on the
rounds remain possible.

### Masked state register (what it does not provide)

The state register holds `state ^ mask`, with the mask taken from `random_i`
when the block is accepted. The same mask is used for all ten rounds, and the
round logic works on the unmasked state (`state_masked_q ^ mask_q`). As a
result:

- the Hamming distance between successive register values,
  `(s_i ^ m) ^ (s_i+1 ^ m) = s_i ^ s_i+1`, is the same as without the mask;
- the S-boxes, MixColumns and the key schedule process unmasked values;
- the round keys are stored unmasked.

So the masking gives no meaningful protection against power or EM analysis.
`make test-secure` only checks that the mask does not change the result and
that the register contents differ between masks. Proper protection would
need masked S-boxes (for example a threshold implementation) and fresh
randomness per round, which this core does not have.

### Clearing

When the result is taken, `aes_core_secure` clears `data_o` and the state
register; a fault clears them too. The round keys stay in registers until
the next block or a reset.

## Timing

- `aes_core_secure`: every block takes 20 cycles from acceptance to
  `valid_o`, independent of key and data (measured on 6774 operations in
  `make test-vectors`).
- `aes_core`: 10 cycles when the key equals the stored key, 20 otherwise.
  The cycle count reveals whether consecutive blocks use the same key, not
  the key or data values.
- `aes_core_pipelined`: one block per cycle with a fixed key; a key change
  stalls the input for the pipeline drain plus 10 cycles.

## Key storage

`aes_core` and `aes_core_secure` keep the 11 round keys in flip-flops after
the operation; `aes_core` reuses them for the next block with the same key,
and `aes_core_pipelined` keeps them until the key changes. There is no
separate key-zeroization input: assert `rst_ni` to clear the stored key
schedule.

## Not covered

- Power and EM analysis (DPA, CPA, template attacks), at any order.
- Fault injection other than on one copy of the `aes_core_secure` round
  counter.
- Glitch attacks on clock or supply, and invasive attacks.
- Leakage through the system around the core (buses, memories).

## Compliance

- **FIPS-197**: the algorithm is implemented and checked in simulation as
  described above; not validated by NIST CAVP.
- **FIPS 140-2 / 140-3**: not claimed. FIPS 140 certifies a whole
  cryptographic module (RNG, key management, roles, physical security), not
  an AES core.
- **Common Criteria**: not evaluated.

## Using the cores

1. Treat all three cores as unprotected against side channels.
2. If you use `aes_core_secure` for fault detection, watch `fault_o`: a rise
   means the round counter copies disagreed. Reset before further use.
   `random_i` can be any value; it does not affect the result.
3. Assert `rst_ni` to clear stored keys when a key must no longer be held.
4. Use the core inside a mode with authentication (for example GCM) in real
   systems; the core itself is single-block AES (ECB).

## Reporting issues

Found a bug or a discrepancy with FIPS-197? Open a GitHub issue; do not post
confidential details in it. No bug bounty is offered.
