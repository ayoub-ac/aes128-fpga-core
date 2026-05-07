// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
// Verilator C++ harness for aes_core_secure.
//
// Tests:
//   1. NIST vectors produce correct ciphertext/plaintext (regardless of mask).
//   2. Same key + same plaintext + DIFFERENT random_i -> same output.
//   3. Mid-operation, the public mask register transitions are NOT identical
//      across two runs with different random_i (sanity check that masking is
//      actually applied to the registered state).
//   4. Force the round counter to disagree mid-op (via Verilator public access)
//      and verify fault_o asserts and ready_o de-asserts. Then reset clears it.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>

#include "verilated.h"
#include "Vaes_core_secure_tb.h"
#include "Vaes_core_secure_tb___024root.h"

struct U128 { uint32_t w[4]; };

static U128 from_hex(const char* hex) {
    U128 out{};
    if (std::strlen(hex) != 32) { std::fprintf(stderr, "bad hex\n"); std::exit(2); }
    for (int byte = 0; byte < 16; byte++) {
        unsigned v;
        std::sscanf(hex + 2 * byte, "%2x", &v);
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
    return a.w[0] == b.w[0] && a.w[1] == b.w[1] && a.w[2] == b.w[2] && a.w[3] == b.w[3];
}

static U128 read_data_o(const Vaes_core_secure_tb* dut) {
    U128 v{};
    v.w[0] = dut->data_o[0]; v.w[1] = dut->data_o[1];
    v.w[2] = dut->data_o[2]; v.w[3] = dut->data_o[3];
    return v;
}

static void write_port(uint32_t* port, const U128& v) {
    port[0] = v.w[0]; port[1] = v.w[1]; port[2] = v.w[2]; port[3] = v.w[3];
}

static vluint64_t g_time = 0;
static int g_failures = 0;

static void tick(Vaes_core_secure_tb* dut) {
    dut->clk_i = 0; dut->eval(); g_time++;
    dut->clk_i = 1; dut->eval(); g_time++;
}

static void reset(Vaes_core_secure_tb* dut) {
    dut->rst_ni = 0;
    dut->valid_i = 0; dut->ready_i = 0; dut->encrypt_i = 0;
    write_port(dut->key_i, U128{}); write_port(dut->data_i, U128{});
    write_port(dut->random_i, U128{});
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_ni = 1; tick(dut);
}

static U128 run_block(Vaes_core_secure_tb* dut, const U128& key,
                      const U128& data, bool encrypt, const U128& rnd,
                      const char* label, int max_cycles = 64) {
    int waited = 0;
    while (!dut->ready_o) {
        tick(dut);
        if (++waited > max_cycles) {
            std::fprintf(stderr, "[%s] timeout ready_o\n", label);
            g_failures++; return U128{};
        }
    }
    write_port(dut->key_i, key);
    write_port(dut->data_i, data);
    write_port(dut->random_i, rnd);
    dut->encrypt_i = encrypt ? 1 : 0;
    dut->valid_i = 1;
    tick(dut);
    dut->valid_i = 0;
    write_port(dut->key_i, U128{});
    write_port(dut->data_i, U128{});
    write_port(dut->random_i, U128{});

    waited = 0;
    while (!dut->valid_o) {
        tick(dut);
        if (++waited > max_cycles) {
            std::fprintf(stderr, "[%s] timeout valid_o\n", label);
            g_failures++; return U128{};
        }
    }
    U128 result = read_data_o(dut);
    dut->ready_i = 1; tick(dut); dut->ready_i = 0;
    return result;
}

struct Vec {
    const char* name; const char* key; const char* pt; const char* ct;
};
static const Vec kVectors[] = {
    {"FIPS-197 App.B", "2b7e151628aed2a6abf7158809cf4f3c",
        "3243f6a8885a308d313198a2e0370734", "3925841d02dc09fbdc118597196a0b32"},
    {"NIST SP 800-38A F.1.1 #1", "2b7e151628aed2a6abf7158809cf4f3c",
        "6bc1bee22e409f96e93d7e117393172a", "3ad77bb40d7a3660a89ecaf32466ef97"},
    {"FIPS-197 App.C.1", "000102030405060708090a0b0c0d0e0f",
        "00112233445566778899aabbccddeeff", "69c4e0d86a7b0430d8cdb78070b4c55a"},
};
static constexpr int kNumVectors = sizeof(kVectors) / sizeof(kVectors[0]);

// ---------------------------------------------------------------------------
static void test_correctness(Vaes_core_secure_tb* dut) {
    std::printf("---- Test S1: NIST vectors with secure core ----\n");
    U128 rnd = from_hex("a1b2c3d4e5f60718293a4b5c6d7e8f90");
    for (int i = 0; i < kNumVectors; i++) {
        const Vec& v = kVectors[i];
        U128 key = from_hex(v.key);
        U128 pt  = from_hex(v.pt);
        U128 ct_exp = from_hex(v.ct);
        U128 ct = run_block(dut, key, pt, true, rnd, v.name);
        if (eq(ct, ct_exp)) std::printf("  +PASS enc %s\n", v.name);
        else { std::printf("  +FAIL enc %s exp=%s got=%s\n", v.name, to_hex(ct_exp).c_str(), to_hex(ct).c_str()); g_failures++; }
        U128 pt2 = run_block(dut, key, ct, false, rnd, v.name);
        if (eq(pt2, pt)) std::printf("  +PASS dec %s\n", v.name);
        else { std::printf("  +FAIL dec %s exp=%s got=%s\n", v.name, to_hex(pt).c_str(), to_hex(pt2).c_str()); g_failures++; }
    }
}

static void test_mask_invariance(Vaes_core_secure_tb* dut) {
    std::printf("---- Test S2: output invariant under random_i variation ----\n");
    U128 key = from_hex("2b7e151628aed2a6abf7158809cf4f3c");
    U128 pt  = from_hex("6bc1bee22e409f96e93d7e117393172a");
    U128 ct_exp = from_hex("3ad77bb40d7a3660a89ecaf32466ef97");
    const char* rnds[] = {
        "00000000000000000000000000000000",
        "ffffffffffffffffffffffffffffffff",
        "0123456789abcdeffedcba9876543210",
        "deadbeefcafebabe1337c0debaadf00d",
    };
    int fail = 0;
    for (auto r : rnds) {
        U128 rnd = from_hex(r);
        U128 ct = run_block(dut, key, pt, true, rnd, "mask-inv");
        if (!eq(ct, ct_exp)) {
            std::printf("  +FAIL random_i=%s -> ct=%s\n", r, to_hex(ct).c_str());
            fail++;
        }
    }
    if (fail == 0) std::printf("  +PASS mask_invariance 4/4 random masks produce identical ct\n");
    else { std::printf("  +FAIL mask_invariance %d/4\n", fail); g_failures++; }
}

static void test_internal_state_differs(Vaes_core_secure_tb* dut) {
    std::printf("---- Test S3: registered state differs between mask values ----\n");
    // Reach into the DUT and snapshot state_masked_q after the same number of
    // cycles on two runs with different random_i. They must differ.
    U128 key = from_hex("2b7e151628aed2a6abf7158809cf4f3c");
    U128 pt  = from_hex("6bc1bee22e409f96e93d7e117393172a");

    auto sample_state_at_run_cycle = [&](const char* rnd_hex) -> U128 {
        // wait for ready
        while (!dut->ready_o) tick(dut);
        U128 rnd = from_hex(rnd_hex);
        write_port(dut->key_i, key);
        write_port(dut->data_i, pt);
        write_port(dut->random_i, rnd);
        dut->encrypt_i = 1; dut->valid_i = 1;
        tick(dut);
        dut->valid_i = 0;
        write_port(dut->key_i, U128{}); write_port(dut->data_i, U128{}); write_port(dut->random_i, U128{});
        // Run 14 cycles to be in S_RUN (after ~10 expand cycles).
        for (int i = 0; i < 14; i++) tick(dut);
        // Read state_masked_q via Verilator's flat-public root access.
        U128 s{};
        auto* root = dut->rootp;
        s.w[0] = root->aes_core_secure_tb__DOT__u_dut__DOT__state_masked_q[0];
        s.w[1] = root->aes_core_secure_tb__DOT__u_dut__DOT__state_masked_q[1];
        s.w[2] = root->aes_core_secure_tb__DOT__u_dut__DOT__state_masked_q[2];
        s.w[3] = root->aes_core_secure_tb__DOT__u_dut__DOT__state_masked_q[3];
        // Drain and reset for next call
        while (!dut->valid_o) tick(dut);
        dut->ready_i = 1; tick(dut); dut->ready_i = 0;
        return s;
    };

    U128 s_a = sample_state_at_run_cycle("00000000000000000000000000000000");
    U128 s_b = sample_state_at_run_cycle("ffffffffffffffffffffffffffffffff");
    if (!eq(s_a, s_b)) {
        std::printf("  +PASS internal_state_differs (snapshot A=%s B=%s)\n",
                    to_hex(s_a).c_str(), to_hex(s_b).c_str());
    } else {
        std::printf("  +FAIL internal_state_differs (both runs registered identical state %s)\n",
                    to_hex(s_a).c_str());
        g_failures++;
    }
}

static void test_fault_detection(Vaes_core_secure_tb* dut) {
    std::printf("---- Test S4: round counter fault injection -> fault_o ----\n");
    reset(dut);
    while (!dut->ready_o) tick(dut);
    U128 key = from_hex("2b7e151628aed2a6abf7158809cf4f3c");
    U128 pt  = from_hex("6bc1bee22e409f96e93d7e117393172a");
    U128 rnd = from_hex("a1b2c3d4e5f60718293a4b5c6d7e8f90");
    write_port(dut->key_i, key);
    write_port(dut->data_i, pt);
    write_port(dut->random_i, rnd);
    dut->encrypt_i = 1; dut->valid_i = 1;
    tick(dut);
    dut->valid_i = 0;
    write_port(dut->key_i, U128{}); write_port(dut->data_i, U128{}); write_port(dut->random_i, U128{});

    // Run a few cycles to be in S_EXPAND or S_RUN
    for (int i = 0; i < 14; i++) tick(dut);

    // Inject fault: corrupt round_q2 via flat-public access.
    auto* root = dut->rootp;
    root->aes_core_secure_tb__DOT__u_dut__DOT__round_q2 = 0xF;  // garbage
    tick(dut);

    if (!dut->fault_o) {
        std::printf("  +FAIL fault_o not asserted after counter corruption\n");
        g_failures++;
        return;
    }
    if (dut->ready_o) {
        std::printf("  +FAIL ready_o still high under fault (should be low)\n");
        g_failures++;
        return;
    }
    // Reset must clear fault
    dut->rst_ni = 0;
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_ni = 1; tick(dut);
    if (dut->fault_o) {
        std::printf("  +FAIL fault_o sticky after reset\n");
        g_failures++;
        return;
    }
    if (!dut->ready_o) {
        std::printf("  +FAIL ready_o low after reset (FSM did not recover)\n");
        g_failures++;
        return;
    }
    // And the core encrypts correctly post-reset
    U128 ct_exp = from_hex("3ad77bb40d7a3660a89ecaf32466ef97");
    U128 ct = run_block(dut, key, pt, true, rnd, "post-fault");
    if (!eq(ct, ct_exp)) {
        std::printf("  +FAIL post-fault encrypt got=%s\n", to_hex(ct).c_str());
        g_failures++;
        return;
    }
    std::printf("  +PASS fault_detection (counter corruption -> fault_o, reset clears, recovery OK)\n");
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    auto* dut = new Vaes_core_secure_tb();
    reset(dut);
    test_correctness(dut);
    test_mask_invariance(dut);
    test_internal_state_differs(dut);
    test_fault_detection(dut);
    dut->final();
    delete dut;
    if (g_failures == 0) { std::printf("\n+PASS all secure tests passed\n"); return 0; }
    std::printf("\n+FAIL %d failure(s)\n", g_failures); return 1;
}
