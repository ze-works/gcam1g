# -----------------------------------------------------------------------------
# File:        kv260_fullfab_clocks.xdc
# Description: Clock group declarations. Every derived clock comes from one
#              generator and is therefore synchronous; only the external camera
#              interface clock is a separate source and is declared
#              asynchronous against the rest.
# -----------------------------------------------------------------------------

set_clock_groups -name gcam_dphy_vs_mmcm -asynchronous \
  -group [get_clocks -include_generated_clocks mipi_phy_if_clk_p] \
  -group [get_clocks clk_out*_kv260_fullfab_bd_clk_wiz_main_0]
