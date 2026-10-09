# -----------------------------------------------------------------------------
# File:        fpprj_regs.tcl
# Description: Address map and shared constants for the block design. Generated
#              from the same register description as the register headers and
#              the RTL package, so the fabric, the software and the diagnostics
#              cannot disagree. Do not edit by hand.
# -----------------------------------------------------------------------------

set ::fpprj_addrmap {
  ctrl/s_axil/reg0  0xA0020000  4K
  mipi_csi/csirxss_s_axi/Reg  0xA0100000  64K
  cam_iic/S_AXI/Reg  0xA0110000  64K
  ps_fw/S_AXI_CTL/Control  0xA0120000  64K
}

set ::fpprj_const(CTRL_WIRE_OVERHEAD) 50
set ::fpprj_const(CTRL_BEAT_MAX) 4
set ::fpprj_const(CTRL_RING_SLOT_SIZE_B) 8192
set ::fpprj_const(CTRL_RING_NUM_SLOTS) 16384
