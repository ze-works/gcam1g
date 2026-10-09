# -----------------------------------------------------------------------------
# File:        kv260_fullfab_bd.tcl
# Description: Builds the block design. The image path runs from the source
#              through pixel packing and stream protocol framing into Ethernet
#              frames, which are written to a ring in memory for software to
#              forward. Clocks all come from one generator, addresses and ring
#              geometry from the generated register description. Configuration
#              variables are resolved here and nowhere else.
# -----------------------------------------------------------------------------

set ::gcam_bd_dir [file dirname [file normalize [info script]]]

proc build_kv260_fullfab_bd {bd_name part} {
  if {[info exists ::env(GCAM_ROOT)]} {
    set _gcam $::env(GCAM_ROOT)
  } elseif {[info script] ne ""} {
    set _gcam [file normalize [file join [file dirname [info script]] .. .. ..]]
  } else {
    error "ADDR_ERR: set GCAM_ROOT (the script path is empty in an interactive session)"
  }
  set _genmap ""
  foreach _c [list $_gcam/output/gen/kv260/fpprj_regs.tcl \
                   [file join $::gcam_bd_dir fpprj_regs.tcl]] {
    if {[file exists $_c]} { set _genmap $_c; break }
  }
  if {$_genmap eq ""} {
    error "ADDR_ERR: fpprj_regs.tcl not found next to this script or in the generated output directory"
  }
  source $_genmap
  puts "CFG: addrmap    = $_genmap (fpprj gen --registers)"

  array set ::fullfab_cfg {}
  foreach {k default note} {
    ETH_BYTES 2   "bytes per beat on the packet path"
    PKT_MHZ   200 "packet and bus clock, in MHz"
    DATA_MHZ  200 "datapath clock, in MHz"
    NUM_TAP   2   "pixels per clock on the image path (1, 2 or 4)"
    GV_PPB    8000 "stream payload bytes per packet (1428 for a standard MTU)"
  } {
    set ::fullfab_cfg($k) [expr {[info exists ::env($k)] ? $::env($k) : $default}]
    set src [expr {[info exists ::env($k)] ? "env" : "default"}]
    puts [format "CFG: %-10s = %-6s (%s)  %s" $k $::fullfab_cfg($k) $src $note]
  }

  create_bd_design $bd_name

  set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* zynq_ps]
  if {[catch {apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
        -config {apply_board_preset 1} $ps}]} {
    puts "NOTE: no board preset — configuring PS ports manually."
  }
  set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__S_AXI_GP2 {1} \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__GPIO_EMIO__PERIPHERAL__ENABLE {1} \
    CONFIG.PSU__GPIO_EMIO__PERIPHERAL__IO {2} \
  ] $ps

  set sensor  [create_bd_cell -type ip -vlnv user.org:gcam:tpg:*   sensor]
  set pixpipe [create_bd_cell -type ip -vlnv user.org:gcam:pixpipe:*  pixpipe]
  set imfifo [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:* imfifo]
  set _imfifo_async [expr {$::fullfab_cfg(PKT_MHZ) == $::fullfab_cfg(DATA_MHZ) ? 0 : 1}]
  set_property -dict [list \
    CONFIG.TDATA_NUM_BYTES {16} CONFIG.TUSER_WIDTH {1} \
    CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} \
    CONFIG.FIFO_DEPTH {512} CONFIG.FIFO_MODE {1} CONFIG.IS_ACLK_ASYNC $_imfifo_async \
  ] $imfifo
  puts "CFG: imfifo IS_ACLK_ASYNC = $_imfifo_async (PKT_MHZ=$::fullfab_cfg(PKT_MHZ) DATA_MHZ=$::fullfab_cfg(DATA_MHZ))"
  set eth_bytes_val $::fullfab_cfg(ETH_BYTES)

  set gvsp    [create_bd_cell -type ip -vlnv user.org:gcam:gvsp:*     gvsp]
  set_property -dict [list CONFIG.ETH_BYTES $eth_bytes_val] $gvsp
  set ethtx   [create_bd_cell -type ip -vlnv user.org:gcam:eth_tx:*   ethtx]
  set_property -dict [list CONFIG.ETH_BYTES $eth_bytes_val] $ethtx
  set ctrl    [create_bd_cell -type ip -vlnv user.org:gcam:ctrl:*     ctrl]

  set dwc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_dwidth_converter:* dwc_s2mm]
  set_property -dict [list CONFIG.S_TDATA_NUM_BYTES $eth_bytes_val CONFIG.M_TDATA_NUM_BYTES {16} \
    CONFIG.HAS_TLAST {1} CONFIG.HAS_TKEEP {1}] $dwc
  set ethwr [create_bd_cell -type ip -vlnv user.org:gcam:eth_wr:* eth_wr]
  set _ring_slot  $::fpprj_const(CTRL_RING_SLOT_SIZE_B)
  set _ring_nslot $::fpprj_const(CTRL_RING_NUM_SLOTS)
  set_property -dict [list CONFIG.NUM_SLOTS $_ring_nslot CONFIG.SLOT_SIZE_B $_ring_slot] $ethwr

  set scc [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_sc_ctrl]
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {5}] $scc
  set schfb [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:* axi_sc_hp0]
  set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $schfb
  set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_ps]

  set pl_src [get_bd_pins zynq_ps/pl_clk0]
  set presn  [get_bd_pins zynq_ps/pl_resetn0]
  set pkt_mhz  $::fullfab_cfg(PKT_MHZ)
  set data_mhz $::fullfab_cfg(DATA_MHZ)

  set cwmain [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:* clk_wiz_main]
  set_property -dict [list \
      CONFIG.PRIM_IN_FREQ {99.999001} \
      CONFIG.CLKOUT1_USED {true} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ [format %.3f [expr {double($pkt_mhz)}]] \
      CONFIG.CLKOUT2_USED {true} CONFIG.CLKOUT2_REQUESTED_OUT_FREQ [format %.3f [expr {double($data_mhz)}]] \
      CONFIG.CLKOUT3_USED {true} CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {250.000} \
      CONFIG.CLKOUT4_USED {true} CONFIG.CLKOUT4_REQUESTED_OUT_FREQ {200.000} \
      CONFIG.USE_RESET {false} CONFIG.USE_LOCKED {true}] $cwmain
  connect_bd_net $pl_src [get_bd_pins clk_wiz_main/clk_in1]
  set mmcm_locked [get_bd_pins clk_wiz_main/locked]
  set clk_pkt_out  [get_bd_pins clk_wiz_main/clk_out1]
  set clk_pix_out  [get_bd_pins clk_wiz_main/clk_out2]
  set clk_rx_out   [get_bd_pins clk_wiz_main/clk_out3]
  set clk_dphy_out [get_bd_pins clk_wiz_main/clk_out4]

  if {$pkt_mhz == 100} {
    set pclk $pl_src
    connect_bd_net $pclk [get_bd_pins rst_ps/slowest_sync_clk]
  } else {
    set pclk $clk_pkt_out
    connect_bd_net $pclk [get_bd_pins rst_ps/slowest_sync_clk]
    connect_bd_net $mmcm_locked [get_bd_pins rst_ps/dcm_locked]
  }
  connect_bd_net $presn [get_bd_pins rst_ps/ext_reset_in]
  set arstn [get_bd_pins rst_ps/peripheral_aresetn]
  set clk_pix $clk_pix_out
  set rstd [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_pix]
  set_property -dict [list CONFIG.C_AUX_RESET_HIGH {1}] $rstd
  connect_bd_net $clk_pix [get_bd_pins rst_pix/slowest_sync_clk]
  connect_bd_net $presn  [get_bd_pins rst_pix/ext_reset_in]
  connect_bd_net $mmcm_locked [get_bd_pins rst_pix/dcm_locked]
  connect_bd_net [get_bd_pins ctrl/soft_reset_o] [get_bd_pins rst_pix/aux_reset_in]
  set arstn150 [get_bd_pins rst_pix/peripheral_aresetn]
  set img_rstn150 $arstn150
  set rstdr [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_pix_raw]
  connect_bd_net $clk_pix [get_bd_pins rst_pix_raw/slowest_sync_clk]
  connect_bd_net $presn  [get_bd_pins rst_pix_raw/ext_reset_in]
  connect_bd_net $mmcm_locked [get_bd_pins rst_pix_raw/dcm_locked]
  set arstn150_raw [get_bd_pins rst_pix_raw/peripheral_aresetn]

  foreach c {gvsp ethtx ctrl eth_wr} {
    connect_bd_net $pclk  [get_bd_pins $c/clk]
  }
  foreach c {sensor pixpipe} {
    connect_bd_net $clk_pix [get_bd_pins $c/clk]
  }
  foreach c {ethtx ctrl eth_wr} {
    connect_bd_net $arstn [get_bd_pins $c/rst_ni]
  }
  set imginv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* img_rst_inv]
  set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {not}] $imginv
  set imgand [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:* img_rst_and]
  set_property -dict [list CONFIG.C_SIZE {1} CONFIG.C_OPERATION {and}] $imgand
  connect_bd_net [get_bd_pins ctrl/soft_reset_o] [get_bd_pins img_rst_inv/Op1]
  connect_bd_net [get_bd_pins img_rst_inv/Res]   [get_bd_pins img_rst_and/Op1]
  connect_bd_net $arstn                          [get_bd_pins img_rst_and/Op2]
  set img_rstn [get_bd_pins img_rst_and/Res]
  connect_bd_net $img_rstn [get_bd_pins gvsp/rst_ni]
  connect_bd_net $arstn    [get_bd_pins gvsp/blkid_rst_ni]
  foreach c {sensor pixpipe} {
    connect_bd_net $img_rstn150 [get_bd_pins $c/rst_ni]
  }
  foreach c {axi_sc_ctrl/aclk axi_sc_hp0/aclk \
             zynq_ps/maxihpm0_fpd_aclk zynq_ps/saxihp0_fpd_aclk} {
    connect_bd_net $pclk [get_bd_pins $c]
  }
  catch {connect_bd_net $pclk [get_bd_pins zynq_ps/maxihpm0_lpd_aclk]}
  foreach r {axi_sc_ctrl/aresetn axi_sc_hp0/aresetn} {
    connect_bd_net $arstn [get_bd_pins $r]
  }
  connect_bd_net $pclk  [get_bd_pins dwc_s2mm/aclk]
  connect_bd_net $arstn [get_bd_pins dwc_s2mm/aresetn]
  connect_bd_net $clk_pix [get_bd_pins imfifo/s_axis_aclk]
  if {$_imfifo_async} {
    connect_bd_net $pclk [get_bd_pins imfifo/m_axis_aclk]
  }
  connect_bd_net $img_rstn150 [get_bd_pins imfifo/s_axis_aresetn]

  set clk_rx $clk_rx_out
  set rstv [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst_rx]
  connect_bd_net $clk_rx [get_bd_pins rst_rx/slowest_sync_clk]
  connect_bd_net $presn  [get_bd_pins rst_rx/ext_reset_in]
  connect_bd_net $mmcm_locked [get_bd_pins rst_rx/dcm_locked]
  set rstn_rx [get_bd_pins rst_rx/peripheral_aresetn]
  set mcsi [create_bd_cell -type ip -vlnv xilinx.com:ip:mipi_csi2_rx_subsystem:* mipi_csi]
  set_property -dict [list \
    CONFIG.DPHYRX_BOARD_INTERFACE {som240_1_connector_mipi_csi_isp} \
    CONFIG.SupportLevel {1} \
    CONFIG.CMN_NUM_LANES {4} CONFIG.CMN_NUM_PIXELS {2} CONFIG.CMN_PXL_FORMAT {YUV422_8bit} \
    CONFIG.CSI_BUF_DEPTH {8192} \
    CONFIG.C_CSI_FILTER_USERDATATYPE {true} \
    CONFIG.C_HS_LINE_RATE {896} CONFIG.C_HS_SETTLE_NS {112} CONFIG.DPY_LINE_RATE {896} \
    CONFIG.DPY_EN_REG_IF {true}] $mcsi
  connect_bd_net $clk_dphy_out [get_bd_pins mipi_csi/dphy_clk_200M]
  connect_bd_net $pclk   [get_bd_pins mipi_csi/lite_aclk]
  connect_bd_net $clk_rx [get_bd_pins mipi_csi/video_aclk]
  connect_bd_net $arstn  [get_bd_pins mipi_csi/lite_aresetn]
  connect_bd_net $rstn_rx [get_bd_pins mipi_csi/video_aresetn]
  make_bd_intf_pins_external [get_bd_intf_pins mipi_csi/mipi_phy_if]
  catch { set_property name mipi_phy_if [get_bd_intf_ports mipi_phy_if_0] }
  set p_rst [create_bd_port -dir O ap1302_rst_b]
  set p_stb [create_bd_port -dir O ap1302_standby]
  set slc_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:* slc_cam_rst]
  set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {0} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {1}] $slc_rst
  set slc_stb [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:* slc_cam_stb]
  set_property -dict [list CONFIG.DIN_WIDTH {2} CONFIG.DIN_FROM {1} CONFIG.DIN_TO {1} CONFIG.DOUT_WIDTH {1}] $slc_stb
  connect_bd_net [get_bd_pins zynq_ps/emio_gpio_o] [get_bd_pins slc_cam_rst/Din] [get_bd_pins slc_cam_stb/Din]
  connect_bd_net [get_bd_pins slc_cam_rst/Dout] $p_rst
  connect_bd_net [get_bd_pins slc_cam_stb/Dout] $p_stb
  set cemi [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_emio_i]
  set_property -dict [list CONFIG.CONST_WIDTH {2} CONFIG.CONST_VAL {0}] $cemi
  connect_bd_net [get_bd_pins const_emio_i/dout] [get_bd_pins zynq_ps/emio_gpio_i]
  set caiic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_iic:* cam_iic]
  connect_bd_net $pclk  [get_bd_pins cam_iic/s_axi_aclk]
  connect_bd_net $arstn [get_bd_pins cam_iic/s_axi_aresetn]
  set psfw [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_firewall:* ps_fw]
  connect_bd_net $pclk  [get_bd_pins ps_fw/aclk]
  connect_bd_net $arstn [get_bd_pins ps_fw/aresetn]
  make_bd_intf_pins_external [get_bd_intf_pins cam_iic/IIC]
  catch { set_property name cam_iic [get_bd_intf_ports IIC_0] }
  set gmi [create_bd_cell -type ip -vlnv user.org:gcam:mipi_src:1.0 mipi_src]
  connect_bd_net $clk_pix [get_bd_pins mipi_src/clk]; connect_bd_net $arstn150 [get_bd_pins mipi_src/rst_ni]
  connect_bd_net $arstn150_raw [get_bd_pins mipi_src/dbg_cnt_rst_ni]
  set y2r [create_bd_cell -type ip -vlnv user.org:gcam:yuv2rgb:1.0 yuv2rgb]
  connect_bd_net $clk_pix [get_bd_pins yuv2rgb/clk]; connect_bd_net $arstn150 [get_bd_pins yuv2rgb/rst_ni]
  set rxcdc [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_data_fifo:* rx_cdc]
  set_property -dict [list CONFIG.IS_ACLK_ASYNC {1} CONFIG.FIFO_DEPTH {2048} CONFIG.HAS_TLAST {1} CONFIG.TUSER_WIDTH {1} CONFIG.HAS_RD_DATA_COUNT {1}] $rxcdc
  connect_bd_net $clk_rx  [get_bd_pins rx_cdc/s_axis_aclk];  connect_bd_net $rstn_rx [get_bd_pins rx_cdc/s_axis_aresetn]
  connect_bd_net $clk_pix  [get_bd_pins rx_cdc/m_axis_aclk]
  connect_bd_intf_net [get_bd_intf_pins mipi_csi/video_out] [get_bd_intf_pins rx_cdc/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins rx_cdc/M_AXIS]      [get_bd_intf_pins yuv2rgb/s_axis]
  connect_bd_intf_net [get_bd_intf_pins yuv2rgb/m_axis]     [get_bd_intf_pins mipi_src/s_axis]
  connect_bd_net [get_bd_pins ctrl/mipi_format_mode_o] [get_bd_pins mipi_src/format_mode_i]
  connect_bd_net [get_bd_pins ctrl/yuv_y_in_high_o] [get_bd_pins yuv2rgb/y_in_high_i]
  connect_bd_net [get_bd_pins ctrl/yuv_cbcr_swap_o] [get_bd_pins yuv2rgb/cbcr_swap_i]
  set clkmon [create_bd_cell -type ip -vlnv user.org:gcam:clk_rx_mon:1.0 clkmon]
  connect_bd_net $clk_rx  [get_bd_pins clkmon/clk_rx];  connect_bd_net $rstn_rx [get_bd_pins clkmon/rst_rx_ni]
  connect_bd_net $pclk    [get_bd_pins clkmon/pclk];    connect_bd_net $arstn   [get_bd_pins clkmon/prst_ni]
  set smx [create_bd_cell -type ip -vlnv user.org:gcam:src_mux2:1.0 src_mux]
  set gcam_num_tap $::fullfab_cfg(NUM_TAP)
  if {$gcam_num_tap > 2} {
    error "NUM_TAP=$gcam_num_tap is not supported: the receiver is fixed at two pixels per beat and a gather stage would be required"
  }
  foreach c [list $sensor $y2r $gmi $smx $pixpipe] {
    set_property -dict [list CONFIG.NUM_TAP $gcam_num_tap] $c
  }
  connect_bd_net $clk_pix [get_bd_pins src_mux/clk]; connect_bd_net $img_rstn150 [get_bd_pins src_mux/rst_ni]
  connect_bd_net [get_bd_pins ctrl/src_sel_o] [get_bd_pins src_mux/sel_i]
  connect_bd_net [get_bd_pins ctrl/src_sel_o] [get_bd_pins eth_wr/drop_on_full_i]
  set srs0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:* sensor_rs0]
  set srs1 [create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:* sensor_rs1]
  foreach rs {sensor_rs0 sensor_rs1} {
    connect_bd_net $clk_pix      [get_bd_pins $rs/aclk]
    connect_bd_net $img_rstn150 [get_bd_pins $rs/aresetn]
  }
  connect_bd_intf_net [get_bd_intf_pins sensor/m_axis]     [get_bd_intf_pins sensor_rs0/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins sensor_rs0/M_AXIS] [get_bd_intf_pins sensor_rs1/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins sensor_rs1/M_AXIS] [get_bd_intf_pins src_mux/s0_axis]
  connect_bd_intf_net [get_bd_intf_pins mipi_src/m_axis] [get_bd_intf_pins src_mux/s1_axis]
  connect_bd_intf_net [get_bd_intf_pins src_mux/m_axis]  [get_bd_intf_pins pixpipe/s_axis]
  connect_bd_intf_net [get_bd_intf_pins pixpipe/m_axis]  [get_bd_intf_pins imfifo/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins imfifo/M_AXIS]   [get_bd_intf_pins gvsp/s_axis]

  connect_bd_intf_net [get_bd_intf_pins gvsp/m_axis_pld]  [get_bd_intf_pins ethtx/s_axis_pld]
  connect_bd_intf_net [get_bd_intf_pins gvsp/m_axis_meta] [get_bd_intf_pins ethtx/s_axis_meta]

  connect_bd_intf_net [get_bd_intf_pins ethtx/m_axis_eth]    [get_bd_intf_pins dwc_s2mm/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins dwc_s2mm/M_AXIS]     [get_bd_intf_pins eth_wr/s_axis]

  connect_bd_intf_net [get_bd_intf_pins eth_wr/m_axi]         [get_bd_intf_pins axi_sc_hp0/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_sc_hp0/M00_AXI]   [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]
  connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_HPM0_FPD] [get_bd_intf_pins ps_fw/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins ps_fw/M_AXI]            [get_bd_intf_pins axi_sc_ctrl/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_sc_ctrl/M01_AXI]  [get_bd_intf_pins ctrl/s_axil]
  connect_bd_intf_net [get_bd_intf_pins axi_sc_ctrl/M02_AXI]  [get_bd_intf_pins mipi_csi/csirxss_s_axi]
  connect_bd_intf_net [get_bd_intf_pins axi_sc_ctrl/M03_AXI]  [get_bd_intf_pins cam_iic/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_sc_ctrl/M04_AXI]  [get_bd_intf_pins ps_fw/S_AXI_CTL]

  proc _k {name w val} {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_$name]
    set_property -dict [list CONFIG.CONST_WIDTH $w CONFIG.CONST_VAL $val] $c
    return [get_bd_pins const_$name/dout]
  }
  connect_bd_net [_k gv_nf  1  0] [get_bd_pins gvsp/new_frame_i]
  connect_bd_net [_k gv_bid 64 0] [get_bd_pins gvsp/block_id_i]
  connect_bd_net [get_bd_pins ctrl/acquisition_start_o] [get_bd_pins ctrl/acquisition_active_i]
  connect_bd_net [_k cr_fr 32 0] [get_bd_pins ctrl/frames_received_i]

  connect_bd_net $pclk  [get_bd_pins mipi_src/dbg_clk]
  connect_bd_net $arstn [get_bd_pins mipi_src/dbg_rst_ni]
  connect_bd_net [get_bd_pins mipi_src/dbg_valid_o]     [get_bd_pins ctrl/dbg0_i]
  connect_bd_net [get_bd_pins mipi_src/dbg_beat_o]      [get_bd_pins ctrl/dbg1_i]
  connect_bd_net [get_bd_pins ethtx/eth_out_beats_o]    [get_bd_pins ctrl/dbg2_i]
  connect_bd_net [get_bd_pins clkmon/count_o]           [get_bd_pins ctrl/dbg3_i]

  connect_bd_net [get_bd_pins ctrl/wr_ring_base_addr_o] [get_bd_pins eth_wr/ring_base_addr_i]
  connect_bd_net [get_bd_pins ctrl/wr_consumer_idx_o]   [get_bd_pins eth_wr/consumer_idx_i]
  connect_bd_net [get_bd_pins eth_wr/producer_idx_o]    [get_bd_pins ctrl/wr_producer_idx_i]

  set irqcc [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:* irq_concat]
  set_property -dict [list CONFIG.NUM_PORTS {2}] $irqcc
  set irq0tie [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_irq0_tie]
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $irq0tie
  connect_bd_net [get_bd_pins const_irq0_tie/dout]      [get_bd_pins irq_concat/In0]
  connect_bd_net [get_bd_pins cam_iic/iic2intc_irpt]    [get_bd_pins irq_concat/In1]
  connect_bd_net [get_bd_pins irq_concat/dout]          [get_bd_pins zynq_ps/pl_ps_irq0]

  set gv_ppb_val $::fullfab_cfg(GV_PPB)
  proc _c {name w val} {
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* const_$name]
    set_property -dict [list CONFIG.CONST_WIDTH $w CONFIG.CONST_VAL $val] $c
    return [get_bd_pins const_$name/dout]
  }
  connect_bd_net [_c s_start 1 0] [get_bd_pins sensor/start_i]
  connect_bd_net [get_bd_pins ctrl/acquisition_start_o] [get_bd_pins sensor/run_i]
  proc _slc13 {name src} {
    set s [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:* slc_$name]
    set_property -dict [list CONFIG.DIN_WIDTH {16} CONFIG.DIN_FROM {12} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {13}] $s
    connect_bd_net $src [get_bd_pins slc_$name/Din]
    return [get_bd_pins slc_$name/Dout]
  }
  proc _ext32 {name src} {
    set z [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* zc_$name]
    set_property -dict [list CONFIG.CONST_WIDTH {16} CONFIG.CONST_VAL {0}] $z
    set c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:* cat_$name]
    set_property -dict [list CONFIG.NUM_PORTS {2}] $c
    connect_bd_net $src                        [get_bd_pins cat_$name/In0]
    connect_bd_net [get_bd_pins zc_$name/dout] [get_bd_pins cat_$name/In1]
    return [get_bd_pins cat_$name/dout]
  }
  connect_bd_net [_slc13 sw [get_bd_pins ctrl/width_o]]  [get_bd_pins sensor/width_i]
  connect_bd_net [_slc13 sh [get_bd_pins ctrl/height_o]] [get_bd_pins sensor/height_i]
  connect_bd_net [get_bd_pins ctrl/pixel_format_o] [get_bd_pins sensor/pixel_format_i]
  connect_bd_net [get_bd_pins ctrl/pattern_select_o] [get_bd_pins sensor/pattern_select_i]
  connect_bd_net [get_bd_pins ctrl/pixel_format_o]  [get_bd_pins pixpipe/pixel_format_i]
  set_property -dict [list CONFIG.GV_PPB_DEFAULT $gv_ppb_val \
                           CONFIG.RING_SLOT_SIZE_B $_ring_slot \
                           CONFIG.RING_NUM_SLOTS  $_ring_nslot] $ctrl
  connect_bd_net [get_bd_pins ctrl/gv_ppb_o] [get_bd_pins gvsp/pkt_payload_bytes_i]
  connect_bd_net [get_bd_pins ctrl/frame_size_bytes_o] [get_bd_pins gvsp/frame_size_bytes_i]
  connect_bd_net [_ext32 gw [get_bd_pins ctrl/width_o]]  [get_bd_pins gvsp/width_i]
  connect_bd_net [_ext32 gh [get_bd_pins ctrl/height_o]] [get_bd_pins gvsp/height_i]
  connect_bd_net [get_bd_pins ctrl/pixel_format_o] [get_bd_pins gvsp/pixel_format_i]
  connect_bd_net [get_bd_pins ctrl/line_bytes_o] [get_bd_pins gvsp/line_bytes_i]
  connect_bd_net [get_bd_pins ctrl/dst_ip_o]   [get_bd_pins gvsp/dst_ip_i]
  connect_bd_net [get_bd_pins ctrl/dst_port_o] [get_bd_pins gvsp/dst_port_i]
  connect_bd_net [get_bd_pins ctrl/src_mac_o] [get_bd_pins ethtx/local_mac_i]
  connect_bd_net [get_bd_pins ctrl/src_ip_o]  [get_bd_pins ethtx/local_ip_i]
  connect_bd_net [get_bd_pins ctrl/dst_mac_o] [get_bd_pins ethtx/dst_mac_i]
  connect_bd_net [_c e_sp 16 20202] [get_bd_pins ethtx/src_port_i]

  assign_bd_address
  set _sp [get_bd_addr_spaces /zynq_ps/Data]
  set _fixmap $::fpprj_addrmap
  foreach {seg off rng} $_fixmap { catch { unassign_bd_address [get_bd_addr_segs $seg] } }
  foreach {seg off rng} $_fixmap {
    set s [get_bd_addr_segs $seg]
    if {[llength $s] == 0} { error "ADDR_ERR: segment '$seg' not found (has the block design changed?)" }
    assign_bd_address -offset $off -range $rng -target_address_space $_sp $s -force
  }
  set _present {}
  foreach as [get_bd_addr_segs -of_objects $_sp] { lappend _present [get_property OFFSET $as] }
  foreach {seg off rng} $_fixmap {
    set _want [format "0x%010X" $off]
    if {[lsearch -exact $_present $_want] < 0} {
      error "ADDR_ERR: expected offset $_want for '$seg' is not present (found: $_present)"
    }
    puts "ADDR_OK: $seg @ $_want"
  }
  set ila_en [expr {[info exists ::env(ILA)] ? $::env(ILA) : 0}]
  if {$ila_en} {
    set ila_depth [expr {[info exists ::env(ILA_DEPTH)] ? $::env(ILA_DEPTH) : 1024}]
    puts "NOTE: logic analysers inserted (depth=$ila_depth); set ILA=0 for a normal build"

    proc _mk_ila {name clk rstn depth slots} {
      set c [create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:* $name]
      set_property -dict [list CONFIG.C_NUM_MONITOR_SLOTS [llength $slots] \
                               CONFIG.C_DATA_DEPTH $depth \
                               CONFIG.C_MON_TYPE {INTERFACE}] $c
      connect_bd_net $clk  [get_bd_pins $name/clk]
      connect_bd_net $rstn [get_bd_pins $name/resetn]
      set i 0
      foreach sl $slots {
        set n [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins $sl]]
        if {[llength $n] == 0} {
          puts "WARNING: analyser $name slot $i: no net on $sl, skipping"
        } else {
          connect_bd_intf_net -intf_net $n [get_bd_intf_pins $name/SLOT_${i}_AXIS]
        }
        incr i
      }
      return $c
    }

    _mk_ila ila_vid  $clk_rx $rstn_rx  $ila_depth {mipi_csi/video_out}
    _mk_ila ila_data $clk_pix $arstn150 $ila_depth \
      {rx_cdc/M_AXIS mipi_src/m_axis pixpipe/m_axis}
    _mk_ila ila_pkt  $pclk   $arstn    $ila_depth \
      {imfifo/M_AXIS gvsp/m_axis_pld dwc_s2mm/M_AXIS}
  }

  validate_bd_design
  save_bd_design
  puts "FULLFAB_BD_OK: $bd_name"
}
