#!/usr/bin/env bash
# Cross-toolchain synthesis report. Runs every installed FPGA toolchain
# against rtl/aes_core.sv (basic, iterative core) and writes SYNTH_REPORT.md
# with a side-by-side LUT/FF/BRAM table.
#
# Toolchains attempted:
#   * Yosys synth_ice40   (always run, only requires yosys)
#   * Yosys synth_ecp5    (")
#   * Yosys synth_xilinx  (Xilinx generic)
#   * Vivado xc7a35tcsg324-1   (only if `vivado` is on PATH)
#   * Quartus Cyclone V        (only if `quartus_sh` is on PATH)
#
# Missing toolchains are noted as "(skipped: tool not on PATH)" rather than
# making the build fail.

set -u
cd "$(dirname "$0")/.."

OUTDIR="synth_report"
mkdir -p "$OUTDIR"

REPORT="SYNTH_REPORT.md"
RTL="rtl/aes_sbox.sv rtl/aes_inv_sbox.sv rtl/aes_key_expand.sv rtl/aes_round.sv rtl/aes_core.sv"

have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Yosys runs
# ---------------------------------------------------------------------------
yosys_run() {
    local target="$1" yopts="$2" outfile="$3"
    if ! have yosys; then
        echo "yosys not installed" > "$outfile"
        return 1
    fi
    yosys -p "read_verilog -sv $RTL; hierarchy -top aes_core; $yopts; stat" \
          > "$outfile" 2>&1
    return $?
}

extract_yosys_stat() {
    # Cell counts from the last "=== aes_core ===" stat block of a Yosys log.
    # Every flow below flattens the design, so that block holds every cell.
    # Accepts both stat layouts: "<count> <cell>" (Yosys >= 0.40) and
    # "<cell> <count>" (older releases).
    local f="$1"
    if [[ ! -s "$f" ]] || grep -q "yosys not installed" "$f"; then
        echo "(skipped)"
        return
    fi
    local block
    block=$(awk '
        /^=== aes_core ===/ { out=""; collect=1; next }
        /^===/              { collect=0 }
        collect             { out = out "\n" $0 }
        END { print out }
    ' "$f")
    if [[ -z "$block" ]]; then
        echo "(no stat block)"
        return
    fi
    count() {
        echo "$block" | awk -v re="$1" '
            NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ re { sum += $1 }
            NF == 2 && $2 ~ /^[0-9]+$/ && $1 ~ re { sum += $2 }
            END { print sum + 0 }'
    }
    local luts ffs brams muxes
    luts=$(count '^(SB_LUT4|LUT[1-6])$')
    ffs=$(count '^(SB_DFF[A-Z]*|TRELLIS_FF|FD[RSCP]E?)$')
    brams=$(count '^(SB_RAM40_4K|DP16KD|PDPW16KD|RAMB18E1|RAMB36E1)$')
    muxes=$(count '^(PFUMX|L6MUX21|MUXF7|MUXF8)$')
    echo "${luts} LUT / ${ffs} FF / ${brams} BRAM / ${muxes} MUX"
}

echo "[synth_report] Yosys ice40..."
yosys_run "ice40"  "synth_ice40 -top aes_core"             "$OUTDIR/yosys_ice40.log"  || true
echo "[synth_report] Yosys ecp5..."
yosys_run "ecp5"   "synth_ecp5 -top aes_core -abc9"        "$OUTDIR/yosys_ecp5.log"   || true
echo "[synth_report] Yosys xilinx..."
yosys_run "xilinx" "synth_xilinx -flatten -top aes_core"          "$OUTDIR/yosys_xilinx.log" || true

# ---------------------------------------------------------------------------
# Vendor flows (best-effort)
# ---------------------------------------------------------------------------
VIVADO_RESULT="(skipped: vivado not on PATH)"
if have vivado; then
    echo "[synth_report] Vivado synth_design Artix-7..."
    cat > "$OUTDIR/vivado_synth.tcl" <<'EOF'
set_part xc7a35tcsg324-1
read_verilog -sv {rtl/aes_sbox.sv rtl/aes_inv_sbox.sv rtl/aes_key_expand.sv rtl/aes_round.sv rtl/aes_core.sv}
synth_design -top aes_core -part xc7a35tcsg324-1 -mode out_of_context
report_utilization -file synth_report/vivado_util.rpt
EOF
    if vivado -mode batch -nojournal -nolog -source "$OUTDIR/vivado_synth.tcl" \
              > "$OUTDIR/vivado.log" 2>&1; then
        VIVADO_LUTS=$(awk '/Slice LUTs/ {print $4; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "?")
        VIVADO_FFS=$(awk  '/Slice Registers/ {print $4; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "?")
        VIVADO_BRAM=$(awk '/Block RAM Tile/ {print $5; exit}' "$OUTDIR/vivado_util.rpt" 2>/dev/null || echo "0")
        VIVADO_RESULT="${VIVADO_LUTS} LUT / ${VIVADO_FFS} FF / ${VIVADO_BRAM} BRAM"
    else
        VIVADO_RESULT="(failed - see synth_report/vivado.log)"
    fi
fi

QUARTUS_RESULT="(skipped: quartus_sh not on PATH)"
if have quartus_sh; then
    echo "[synth_report] Quartus Cyclone V..."
    QPROJ="$OUTDIR/qproj"
    mkdir -p "$QPROJ"
    cat > "$QPROJ/aes_core.qsf" <<'EOF'
set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE 5CSEMA5F31C6
set_global_assignment -name TOP_LEVEL_ENTITY aes_core
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_sbox.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_inv_sbox.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_key_expand.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_round.sv
set_global_assignment -name SYSTEMVERILOG_FILE ../../rtl/aes_core.sv
EOF
    cat > "$QPROJ/aes_core.qpf" <<'EOF'
PROJECT_REVISION = "aes_core"
EOF
    if (cd "$QPROJ" && quartus_sh --flow compile aes_core > ../quartus.log 2>&1); then
        QU_LUTS=$(awk -F\| '/ALMs needed/ {gsub(/ /,"",$3); print $3; exit}' "$OUTDIR/quartus.log" || echo "?")
        QU_FFS=$(awk  -F\| '/Total registers/ {gsub(/ /,"",$3); print $3; exit}' "$OUTDIR/quartus.log" || echo "?")
        QUARTUS_RESULT="${QU_LUTS} ALM / ${QU_FFS} FF"
    else
        QUARTUS_RESULT="(failed - see synth_report/quartus.log)"
    fi
fi

# ---------------------------------------------------------------------------
# Build the report
# ---------------------------------------------------------------------------
ICE40_RESULT=$(extract_yosys_stat "$OUTDIR/yosys_ice40.log")
ECP5_RESULT=$(extract_yosys_stat "$OUTDIR/yosys_ecp5.log")
XIL_RESULT=$(extract_yosys_stat   "$OUTDIR/yosys_xilinx.log")

YOSYS_VERSION=$( (yosys -V 2>/dev/null || echo "Yosys not installed") | head -n 1 | sed 's/ (git.*//')

cat > "$REPORT" <<EOF
# Synthesis report: aes_core (basic iterative core)

Generated by \`make synth_report\` with ${YOSYS_VERSION}. Post-synthesis
cell counts, before place and route; the design is flattened. Vivado and
Quartus rows are filled only when those tools are on PATH. MUX counts the
ECP5 PFUMX / L6MUX21 and Xilinx MUXF7 / MUXF8 cells, which are not LUTs.

| Toolchain       | Target                  | Result |
|-----------------|-------------------------|--------|
| Yosys synth_ice40  | iCE40                | ${ICE40_RESULT} |
| Yosys synth_ecp5   | ECP5                 | ${ECP5_RESULT} |
| Yosys synth_xilinx | Xilinx 7-series      | ${XIL_RESULT} |
| Vivado synth_design | Artix-7 xc7a35tcsg324-1 | ${VIVADO_RESULT} |
| Quartus             | Cyclone V 5CSEMA5F31C6  | ${QUARTUS_RESULT} |

## Notes

* Device capacities for comparison: iCE40 UP5K 5280 LUT4 and 30 SB_RAM40_4K;
  iCE40 HX8K 7680 LUT4 and 32 SB_RAM40_4K; ECP5 LFE5U-25F 24288 LUT4,
  LFE5U-45F 43848 LUT4; Artix-7 xc7a35t 20800 LUT6.
* Most of the area is the 36 table S-boxes (16 forward and 16 inverse in the
  round, 4 in the key expansion) and the 11 x 128-bit round-key store.
* The vendor flows in scripts/synth_report.sh have not been run by the
  maintainer.

## Reproduction

\`\`\`
make synth_report
\`\`\`

Raw logs land in \`synth_report/\`.
EOF

echo "[synth_report] Wrote $REPORT"
