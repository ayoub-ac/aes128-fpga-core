// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// NIST FIPS-197 / NIST SP 800-38A AES-128 reference test vectors.
//
// This file is informational and consumed by the C++ Verilator harness
// (tb/sim_main.cpp), which mirrors the same vectors as `WData` arrays.
// Kept here in plain SystemVerilog so that an external simulator (Icarus, VCS)
// can also pull the same vectors via `include `if needed.
//
// Source:
//   - FIPS-197 Appendix B/C
//   - NIST SP 800-38A Appendix F.1.1 / F.1.2 (ECB-AES128)

`ifndef NIST_VECTORS_SV
`define NIST_VECTORS_SV

package nist_vectors_pkg;

  // FIPS-197 Appendix B
  parameter logic [127:0] KEY_FIPS_B   = 128'h2b7e151628aed2a6abf7158809cf4f3c;
  parameter logic [127:0] PT_FIPS_B    = 128'h3243f6a8885a308d313198a2e0370734;
  parameter logic [127:0] CT_FIPS_B    = 128'h3925841d02dc09fbdc118597196a0b32;

  // NIST SP 800-38A F.1.1 ECB-AES128 vector 1
  parameter logic [127:0] KEY_NIST_1   = 128'h2b7e151628aed2a6abf7158809cf4f3c;
  parameter logic [127:0] PT_NIST_1    = 128'h6bc1bee22e409f96e93d7e117393172a;
  parameter logic [127:0] CT_NIST_1    = 128'h3ad77bb40d7a3660a89ecaf32466ef97;

  // NIST SP 800-38A F.1.1 vector 2
  parameter logic [127:0] PT_NIST_2    = 128'hae2d8a571e03ac9c9eb76fac45af8e51;
  parameter logic [127:0] CT_NIST_2    = 128'hf5d3d58503b9699de785895a96fdbaaf;

  // NIST SP 800-38A F.1.1 vector 3
  parameter logic [127:0] PT_NIST_3    = 128'h30c81c46a35ce411e5fbc1191a0a52ef;
  parameter logic [127:0] CT_NIST_3    = 128'h43b1cd7f598ece23881b00e3ed030688;

  // NIST SP 800-38A F.1.1 vector 4
  parameter logic [127:0] PT_NIST_4    = 128'hf69f2445df4f9b17ad2b417be66c3710;
  parameter logic [127:0] CT_NIST_4    = 128'h7b0c785e27e8ad3f8223207104725dd4;

  // FIPS-197 Appendix C.1 (key = 000102...0F, plaintext = 00112233...EEFF)
  parameter logic [127:0] KEY_FIPS_C   = 128'h000102030405060708090a0b0c0d0e0f;
  parameter logic [127:0] PT_FIPS_C    = 128'h00112233445566778899aabbccddeeff;
  parameter logic [127:0] CT_FIPS_C    = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;

endpackage

`endif
