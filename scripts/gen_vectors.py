# SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
"""Write AES-128 test vectors for tb/tb_vectors.sv.

Each entry is three $readmemh lines: key, plaintext, ciphertext. The
ciphertexts come from the `cryptography` package (OpenSSL backend), which is
independent of the RTL. Layout:

    0..1      FIPS-197 Appendix B and C.1 (checked against the standard)
    2..257    the C.1 key with 256 random blocks (pipelined streaming)
    258..385  VarTxt: key 0, plaintexts with 1..128 leading one bits
    386..513  VarKey: plaintext 0, keys with 1..128 leading one bits
    514, 515  all-zero and all-one key and plaintext
    516..     random keys and plaintexts

Usage: python3 scripts/gen_vectors.py --out build/vectors.hex [--random N] [--seed S]
"""
import argparse
import random

try:
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
except ImportError as exc:
    raise SystemExit("gen_vectors.py needs the cryptography package: pip install cryptography") from exc


def encrypt(key: bytes, pt: bytes) -> bytes:
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(pt) + enc.finalize()


def leading_ones(i: int) -> bytes:
    return (((1 << 128) - 1) ^ ((1 << (128 - i)) - 1)).to_bytes(16, "big")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--random", type=int, default=2000)
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()

    fixed = [
        ("2b7e151628aed2a6abf7158809cf4f3c", "3243f6a8885a308d313198a2e0370734", "3925841d02dc09fbdc118597196a0b32"),
        ("000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff", "69c4e0d86a7b0430d8cdb78070b4c55a"),
    ]
    for key, pt, ct in fixed:
        if encrypt(bytes.fromhex(key), bytes.fromhex(pt)).hex() != ct:
            raise SystemExit("reference model disagrees with FIPS-197")

    zero = bytes(16)
    stream_rng = random.Random(7)
    rng = random.Random(args.seed)
    pairs = [(bytes.fromhex(k), bytes.fromhex(p)) for k, p, _ in fixed]
    pairs += [(bytes.fromhex(fixed[1][0]), stream_rng.randbytes(16)) for _ in range(256)]
    pairs += [(zero, leading_ones(i)) for i in range(1, 129)]
    pairs += [(leading_ones(i), zero) for i in range(1, 129)]
    pairs += [(zero, zero), (b"\xff" * 16, b"\xff" * 16)]
    pairs += [(rng.randbytes(16), rng.randbytes(16)) for _ in range(args.random)]

    with open(args.out, "w") as f:
        for key, pt in pairs:
            f.write(f"{key.hex()}\n{pt.hex()}\n{encrypt(key, pt).hex()}\n")
    print(f"{len(pairs)} vectors -> {args.out}")


if __name__ == "__main__":
    main()
