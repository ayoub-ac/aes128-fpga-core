// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Verilator C++ harness for aes_core. Drives NIST FIPS-197 / SP 800-38A
// AES-128 test vectors against the DUT and verifies ciphertext + decrypt
// round-trip + back-to-back throughput.
//
// Build:  see Makefile  (`make sim` or `make test`)
// Output: prints "+PASS" or "+FAIL <reason>" so a Makefile can grep.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vaes_core_tb.h"
#include "Vaes_core_tb___024root.h"
#include "Vaes_core_tb_aes_core_tb.h"
#include "Vaes_core_tb_aes_core_cov.h"
#include "random_vectors.h"

// ---------------------------------------------------------------------------
// 128-bit helpers. Verilator stores wide signals as WData = uint32_t[N].
// For a 128-bit signal, 4 words: word[0] = bits [31:0], word[3] = bits [127:96].
// ---------------------------------------------------------------------------
struct U128 {
    uint32_t w[4]; // little-endian word order
};

// Parse a 32-char hex string into a U128 such that the most-significant byte
// of the hex string ends up in bit position [127:120] (matches AES "MSB-first").
static U128 from_hex(const char* hex) {
    U128 out{};
    if (std::strlen(hex) != 32) {
        std::fprintf(stderr, "from_hex: expected 32 hex chars, got '%s'\n", hex);
        std::exit(2);
    }
    for (int byte = 0; byte < 16; byte++) {
        unsigned v;
        if (std::sscanf(hex + 2 * byte, "%2x", &v) != 1) {
            std::fprintf(stderr, "from_hex: bad hex '%s'\n", hex);
            std::exit(2);
        }
        // hex char index `byte` represents AES byte index `byte`,
        // which lives in bits [127 - 8*byte -: 8].
        int bit_hi = 127 - 8 * byte;
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        out.w[word] |= (uint32_t)(v & 0xff) << shift;
    }
    return out;
}

static std::string to_hex(const U128& v) {
    char buf[33];
    for (int byte = 0; byte < 16; byte++) {
        int bit_hi = 127 - 8 * byte;
        int word   = bit_hi / 32;
        int shift  = bit_hi - word * 32 - 7;
        unsigned b = (v.w[word] >> shift) & 0xff;
        std::snprintf(buf + 2 * byte, 3, "%02x", b);
    }
    buf[32] = 0;
    return std::string(buf);
}

static bool eq(const U128& a, const U128& b) {
    return a.w[0] == b.w[0] && a.w[1] == b.w[1] &&
           a.w[2] == b.w[2] && a.w[3] == b.w[3];
}

static U128 read_data_o(const Vaes_core_tb* dut) {
    U128 v{};
    v.w[0] = dut->data_o[0];
    v.w[1] = dut->data_o[1];
    v.w[2] = dut->data_o[2];
    v.w[3] = dut->data_o[3];
    return v;
}

static void write_port(uint32_t* port, const U128& v) {
    port[0] = v.w[0];
    port[1] = v.w[1];
    port[2] = v.w[2];
    port[3] = v.w[3];
}

// ---------------------------------------------------------------------------
// Simulation primitives
// ---------------------------------------------------------------------------
static vluint64_t g_time = 0;
static int g_failures = 0;

static void tick(Vaes_core_tb* dut) {
    dut->clk_i = 0;
    dut->eval();
    g_time++;
    dut->clk_i = 1;
    dut->eval();
    g_time++;
}

static void reset(Vaes_core_tb* dut) {
    dut->rst_ni  = 0;
    dut->valid_i = 0;
    dut->ready_i = 0;
    dut->encrypt_i = 0;
    write_port(dut->key_i, U128{});
    write_port(dut->data_i, U128{});
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_ni = 1;
    tick(dut);
}

// Run one block. Asserts valid_i and key/data, waits for ready_o, then waits
// for valid_o, captures data_o, then handshakes with ready_i. Returns result.
// stall_cycles: hold ready_i low for this many cycles after valid_o asserts to
// exercise the back-pressure / hold behavior of S_DONE.
static U128 run_block(Vaes_core_tb* dut, const U128& key,
                      const U128& data, bool encrypt,
                      const char* label, int max_cycles = 64,
                      int stall_cycles = 0) {
    int waited = 0;
    while (!dut->ready_o) {
        tick(dut);
        if (++waited > max_cycles) {
            std::fprintf(stderr, "[%s] timeout waiting for ready_o\n", label);
            g_failures++;
            return U128{};
        }
    }

    write_port(dut->key_i, key);
    write_port(dut->data_i, data);
    dut->encrypt_i = encrypt ? 1 : 0;
    dut->valid_i = 1;
    tick(dut);
    dut->valid_i = 0;
    write_port(dut->key_i, U128{});
    write_port(dut->data_i, U128{});

    waited = 0;
    while (!dut->valid_o) {
        tick(dut);
        if (++waited > max_cycles) {
            std::fprintf(stderr, "[%s] timeout waiting for valid_o\n", label);
            g_failures++;
            return U128{};
        }
    }

    U128 result = read_data_o(dut);

    // Optionally stall by holding ready_i low. data_o must remain stable.
    for (int s = 0; s < stall_cycles; s++) {
        tick(dut);
        if (!dut->valid_o) {
            std::fprintf(stderr, "[%s] valid_o dropped during stall cycle %d\n", label, s);
            g_failures++;
        }
        U128 again = read_data_o(dut);
        if (!eq(again, result)) {
            std::fprintf(stderr, "[%s] data_o changed during stall cycle %d\n", label, s);
            g_failures++;
        }
    }

    dut->ready_i = 1;
    tick(dut);
    dut->ready_i = 0;

    return result;
}

struct Vec {
    const char* name;
    const char* key;
    const char* pt;
    const char* ct;
};

static const Vec kVectors[] = {
    {"FIPS-197 App.B",
        "2b7e151628aed2a6abf7158809cf4f3c",
        "3243f6a8885a308d313198a2e0370734",
        "3925841d02dc09fbdc118597196a0b32"},
    {"NIST SP 800-38A F.1.1 #1",
        "2b7e151628aed2a6abf7158809cf4f3c",
        "6bc1bee22e409f96e93d7e117393172a",
        "3ad77bb40d7a3660a89ecaf32466ef97"},
    {"NIST SP 800-38A F.1.1 #2",
        "2b7e151628aed2a6abf7158809cf4f3c",
        "ae2d8a571e03ac9c9eb76fac45af8e51",
        "f5d3d58503b9699de785895a96fdbaaf"},
    {"NIST SP 800-38A F.1.1 #3",
        "2b7e151628aed2a6abf7158809cf4f3c",
        "30c81c46a35ce411e5fbc1191a0a52ef",
        "43b1cd7f598ece23881b00e3ed030688"},
    {"NIST SP 800-38A F.1.1 #4",
        "2b7e151628aed2a6abf7158809cf4f3c",
        "f69f2445df4f9b17ad2b417be66c3710",
        "7b0c785e27e8ad3f8223207104725dd4"},
    {"FIPS-197 App.C.1",
        "000102030405060708090a0b0c0d0e0f",
        "00112233445566778899aabbccddeeff",
        "69c4e0d86a7b0430d8cdb78070b4c55a"},
};
static constexpr int kNumVectors = sizeof(kVectors) / sizeof(kVectors[0]);

// ---------------------------------------------------------------------------
// Test cases
// ---------------------------------------------------------------------------
static void test_encrypt_vectors(Vaes_core_tb* dut) {
    std::printf("---- Test 1: encrypt NIST vectors ----\n");
    for (int i = 0; i < kNumVectors; i++) {
        const Vec& v = kVectors[i];
        U128 key = from_hex(v.key);
        U128 pt  = from_hex(v.pt);
        U128 ct_exp = from_hex(v.ct);
        U128 ct_got = run_block(dut, key, pt, /*encrypt=*/true, v.name);
        if (eq(ct_got, ct_exp)) {
            std::printf("  [PASS] enc %s\n", v.name);
        } else {
            std::printf("  [FAIL] enc %s\n", v.name);
            std::printf("         expected %s\n", to_hex(ct_exp).c_str());
            std::printf("         got      %s\n", to_hex(ct_got).c_str());
            g_failures++;
        }
    }
}

static void test_decrypt_vectors(Vaes_core_tb* dut) {
    std::printf("---- Test 2: decrypt NIST vectors ----\n");
    for (int i = 0; i < kNumVectors; i++) {
        const Vec& v = kVectors[i];
        U128 key = from_hex(v.key);
        U128 ct  = from_hex(v.ct);
        U128 pt_exp = from_hex(v.pt);
        U128 pt_got = run_block(dut, key, ct, /*encrypt=*/false, v.name);
        if (eq(pt_got, pt_exp)) {
            std::printf("  [PASS] dec %s\n", v.name);
        } else {
            std::printf("  [FAIL] dec %s\n", v.name);
            std::printf("         expected %s\n", to_hex(pt_exp).c_str());
            std::printf("         got      %s\n", to_hex(pt_got).c_str());
            g_failures++;
        }
    }
}

static void test_roundtrip(Vaes_core_tb* dut) {
    std::printf("---- Test 3: encrypt(decrypt(x)) == x ----\n");
    U128 key = from_hex("0f1571c947d9e8590cb7add6af7f6798");
    const char* plaintexts[] = {
        "00000000000000000000000000000000",
        "ffffffffffffffffffffffffffffffff",
        "0123456789abcdeffedcba9876543210",
        "deadbeefcafebabe0123456789abcdef",
    };
    for (auto pt_hex : plaintexts) {
        U128 pt  = from_hex(pt_hex);
        U128 ct  = run_block(dut, key, pt, /*encrypt=*/true,  "rt-enc");
        U128 pt2 = run_block(dut, key, ct, /*encrypt=*/false, "rt-dec");
        if (eq(pt, pt2)) {
            std::printf("  [PASS] roundtrip pt=%s\n", pt_hex);
        } else {
            std::printf("  [FAIL] roundtrip pt=%s -> got %s\n", pt_hex, to_hex(pt2).c_str());
            g_failures++;
        }
    }
}

static void test_back_to_back(Vaes_core_tb* dut) {
    std::printf("---- Test 4: back-to-back blocks (throughput) ----\n");
    const Vec& v = kVectors[1]; // NIST F.1.1 #1
    U128 key = from_hex(v.key);
    U128 pt  = from_hex(v.pt);
    U128 ct_exp = from_hex(v.ct);

    vluint64_t t0 = g_time;
    const int N = 16;
    for (int i = 0; i < N; i++) {
        U128 ct = run_block(dut, key, pt, /*encrypt=*/true, "b2b");
        if (!eq(ct, ct_exp)) {
            std::printf("  [FAIL] back-to-back block %d mismatch\n", i);
            g_failures++;
            return;
        }
    }
    vluint64_t cycles = (g_time - t0) / 2;
    double cyc_per_block = double(cycles) / N;
    std::printf("  [PASS] %d blocks in %llu cycles (%.1f cycles/block)\n",
                N, (unsigned long long)cycles, cyc_per_block);
}

// ---------------------------------------------------------------------------
// Edge case tests
// ---------------------------------------------------------------------------
struct EdgeVec {
    const char* name;
    const char* key;
    const char* pt;
    const char* ct;
};

static const EdgeVec kEdgeVectors[] = {
    {"all-zero key + all-zero pt",
        "00000000000000000000000000000000",
        "00000000000000000000000000000000",
        "66e94bd4ef8a2c3b884cfa59ca342b2e"},
    {"all-FF key + all-FF pt",
        "ffffffffffffffffffffffffffffffff",
        "ffffffffffffffffffffffffffffffff",
        "bcbf217cb280cf30b2517052193ab979"},
    {"single-bit key (0x80..00) + zero pt",
        "80000000000000000000000000000000",
        "00000000000000000000000000000000",
        "0edd33d3c621e546455bd8ba1418bec8"},
    {"zero key + single-bit pt (0x80..00)",
        "00000000000000000000000000000000",
        "80000000000000000000000000000000",
        "3ad78e726c1ec02b7ebfe92b23d9ec34"},
};

static void test_edge_known_vectors(Vaes_core_tb* dut) {
    std::printf("---- Test 5: known-answer edge case vectors ----\n");
    for (const auto& v : kEdgeVectors) {
        U128 key = from_hex(v.key);
        U128 pt  = from_hex(v.pt);
        U128 ct_exp = from_hex(v.ct);
        U128 ct = run_block(dut, key, pt, /*encrypt=*/true, v.name);
        if (!eq(ct, ct_exp)) {
            std::printf("  +FAIL edge_%s expected=%s got=%s\n", v.name,
                        to_hex(ct_exp).c_str(), to_hex(ct).c_str());
            g_failures++;
            continue;
        }
        U128 pt2 = run_block(dut, key, ct, /*encrypt=*/false, v.name);
        if (!eq(pt, pt2)) {
            std::printf("  +FAIL edge_%s decrypt got=%s\n", v.name, to_hex(pt2).c_str());
            g_failures++;
            continue;
        }
        std::printf("  +PASS edge_%s\n", v.name);
    }
}

static void test_random_roundtrip(Vaes_core_tb* dut) {
    std::printf("---- Test 6: 1000 random encrypt-then-decrypt blocks ----\n");
    int failed = 0;
    for (int i = 0; i < kNumRoundtripPts; i++) {
        U128 key = from_hex(kRoundtripKeys[i]);
        U128 pt  = from_hex(kRoundtripPts[i]);
        U128 ct  = run_block(dut, key, pt, /*encrypt=*/true,  "rand-rt");
        U128 pt2 = run_block(dut, key, ct, /*encrypt=*/false, "rand-rt");
        if (!eq(pt, pt2)) {
            if (failed < 3) {
                std::printf("  +FAIL random_roundtrip[%d] pt=%s got=%s\n",
                            i, kRoundtripPts[i], to_hex(pt2).c_str());
            }
            failed++;
        }
    }
    if (failed == 0) {
        std::printf("  +PASS random_roundtrip 1000/1000\n");
    } else {
        std::printf("  +FAIL random_roundtrip %d failures of %d\n", failed, kNumRoundtripPts);
        g_failures++;
    }
}

static void test_key_change_b2b(Vaes_core_tb* dut) {
    std::printf("---- Test 7: back-to-back encrypt with key changes ----\n");
    int failed = 0;
    for (int i = 0; i < 8; i++) {
        const RandomVec& a = kRandomVecs[i * 2];
        const RandomVec& b = kRandomVecs[i * 2 + 1];
        U128 ct_a = run_block(dut, from_hex(a.key), from_hex(a.pt), true, "kc-a");
        U128 ct_b = run_block(dut, from_hex(b.key), from_hex(b.pt), true, "kc-b");
        if (!eq(ct_a, from_hex(a.ct)) || !eq(ct_b, from_hex(b.ct))) {
            std::printf("  +FAIL key_change pair %d\n", i);
            failed++;
        }
    }
    if (failed == 0) std::printf("  +PASS key_change_b2b 8 pairs\n");
    else { std::printf("  +FAIL key_change_b2b %d/8\n", failed); g_failures++; }
}

static void test_reset_mid_op(Vaes_core_tb* dut) {
    std::printf("---- Test 8: reset asserted mid-operation ----\n");
    // Issue an encrypt, then assert reset before valid_o appears.
    while (!dut->ready_o) tick(dut);
    U128 key = from_hex("2b7e151628aed2a6abf7158809cf4f3c");
    U128 pt  = from_hex("6bc1bee22e409f96e93d7e117393172a");
    U128 ct_exp = from_hex("3ad77bb40d7a3660a89ecaf32466ef97");
    write_port(dut->key_i, key);
    write_port(dut->data_i, pt);
    dut->encrypt_i = 1;
    dut->valid_i = 1;
    tick(dut);
    dut->valid_i = 0;
    write_port(dut->key_i, U128{});
    write_port(dut->data_i, U128{});

    // Run a few cycles into the operation, then yank reset.
    for (int i = 0; i < 5; i++) tick(dut);
    dut->rst_ni = 0;
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_ni = 1;
    tick(dut);

    if (!dut->ready_o) {
        std::printf("  +FAIL reset_recovery: ready_o not asserted after reset release\n");
        g_failures++;
        return;
    }
    if (dut->valid_o) {
        std::printf("  +FAIL reset_recovery: stale valid_o after reset\n");
        g_failures++;
        return;
    }
    U128 ct = run_block(dut, key, pt, true, "post-reset");
    if (!eq(ct, ct_exp)) {
        std::printf("  +FAIL reset_recovery output mismatch got=%s\n", to_hex(ct).c_str());
        g_failures++;
        return;
    }
    std::printf("  +PASS reset_mid_op (FSM recovered to IDLE, post-reset block correct)\n");
}

static void test_long_stall(Vaes_core_tb* dut) {
    std::printf("---- Test 9: long stall with ready_i held low ----\n");
    U128 key = from_hex("2b7e151628aed2a6abf7158809cf4f3c");
    U128 pt  = from_hex("ae2d8a571e03ac9c9eb76fac45af8e51");
    U128 ct_exp = from_hex("f5d3d58503b9699de785895a96fdbaaf");
    U128 ct = run_block(dut, key, pt, true, "stall", /*max_cycles=*/64, /*stall_cycles=*/50);
    if (eq(ct, ct_exp)) std::printf("  +PASS long_stall (50 cycles, valid_o + data_o stable)\n");
    else { std::printf("  +FAIL long_stall got=%s\n", to_hex(ct).c_str()); g_failures++; }
}

static void test_python_cross_validate(Vaes_core_tb* dut) {
    std::printf("---- Test 10: cross-validate vs pycryptodome on 100 random blocks ----\n");
    int failed = 0;
    for (int i = 0; i < kNumRandomVecs; i++) {
        const RandomVec& v = kRandomVecs[i];
        U128 key = from_hex(v.key);
        U128 pt  = from_hex(v.pt);
        U128 ct_exp = from_hex(v.ct);
        U128 ct = run_block(dut, key, pt, true, "xval");
        if (!eq(ct, ct_exp)) {
            if (failed < 3) {
                std::printf("  +FAIL xval[%d] key=%s pt=%s exp=%s got=%s\n",
                            i, v.key, v.pt, v.ct, to_hex(ct).c_str());
            }
            failed++;
        }
    }
    if (failed == 0) std::printf("  +PASS python_cross_validate 100/100\n");
    else { std::printf("  +FAIL python_cross_validate %d/%d\n", failed, kNumRandomVecs); g_failures++; }
}

// ---------------------------------------------------------------------------
// Functional coverage report. Reads the per-bin flags from the coverage
// collector via Verilator's flat-public-rw access and prints a coverage line.
// ---------------------------------------------------------------------------
static void report_coverage(const Vaes_core_tb* dut) {
    auto* cov = dut->rootp->aes_core_tb->u_cov;
    struct Bin { const char* name; uint8_t hit; };
    Bin bins[] = {
        {"state_idle",    cov->c_state_idle},
        {"state_expand",  cov->c_state_expand},
        {"state_run",     cov->c_state_run},
        {"state_done",    cov->c_state_done},
        {"encrypt_path",  cov->c_encrypt_path},
        {"decrypt_path",  cov->c_decrypt_path},
        {"back_pressure", cov->c_back_pressure},
        {"key_change",    cov->c_key_change},
        {"reset_mid_op",  cov->c_reset_mid_op},
    };
    int total = sizeof(bins) / sizeof(bins[0]);
    int hit = 0;
    std::printf("\n---- Functional coverage ----\n");
    for (int i = 0; i < total; i++) {
        std::printf("  [%s] %-15s\n", bins[i].hit ? "HIT " : "MISS", bins[i].name);
        if (bins[i].hit) hit++;
    }
    std::printf("Coverage: %d/%d bins (%.1f%%)\n",
                hit, total, 100.0 * hit / total);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new Vaes_core_tb();

    reset(dut);

    test_encrypt_vectors(dut);
    test_decrypt_vectors(dut);
    test_roundtrip(dut);
    test_back_to_back(dut);
    test_edge_known_vectors(dut);
    test_random_roundtrip(dut);
    test_key_change_b2b(dut);
    test_reset_mid_op(dut);
    test_long_stall(dut);
    test_python_cross_validate(dut);

    report_coverage(dut);

    dut->final();
    delete dut;

    if (g_failures == 0) {
        std::printf("\n+PASS all tests passed\n");
        return 0;
    } else {
        std::printf("\n+FAIL %d failure(s)\n", g_failures);
        return 1;
    }
}
