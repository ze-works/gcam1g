# -----------------------------------------------------------------------------
# File:        kv260_ias_mipi.xdc
# Description: Pin assignment for the camera control and i2c pins, and the
#              timing exception for the clock monitor crossing. The camera data
#              lanes are configured by the receiver board interface and are
#              deliberately not constrained here.
# -----------------------------------------------------------------------------

set_property -dict {PACKAGE_PIN J11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ap1302_rst_b]
set_property -dict {PACKAGE_PIN J10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports ap1302_standby]

set_property -dict {PACKAGE_PIN G11 IOSTANDARD LVCMOS33 SLEW SLOW} [get_ports cam_iic_scl_io]
set_property -dict {PACKAGE_PIN F10 IOSTANDARD LVCMOS33 SLEW SLOW} [get_ports cam_iic_sda_io]

set_max_delay -datapath_only 5.000 \
  -from [get_cells -hier -filter {NAME =~ *clkmon*gray_q_reg* && IS_SEQUENTIAL}] \
  -to   [get_cells -hier -filter {NAME =~ *clkmon*s1_q_reg*  && IS_SEQUENTIAL}]
