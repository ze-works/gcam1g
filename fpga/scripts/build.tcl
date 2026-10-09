# -----------------------------------------------------------------------------
# File:        build.tcl
# Description: Builds the block design through synthesis and implementation to
#              a bitstream. Verifies that the clock constraints resolved
#              against real clocks and stops if they did not, counts the
#              critical warnings, and writes a clock domain crossing report.
# -----------------------------------------------------------------------------

set _this [file normalize [info script]]
set GCAM  [expr {[info exists ::env(GCAM_ROOT)] ? $::env(GCAM_ROOT)
                 : [file dirname [file dirname [file dirname [file dirname $_this]]]]}]
set OUT   [expr {[info exists ::env(FULLFAB_OUT)] ? $::env(FULLFAB_OUT)
                 : [file join $GCAM output prj xilinx kv260_fullfab]}]
set PART  xck26-sfvc784-2LV-c
puts "BUILD_ROOT: GCAM=$GCAM"
puts "BUILD_OUT : $OUT"

create_project fullfabz $OUT/.fullfabz -part $PART -force
set _sombp [get_board_parts "*:kv260_som:*" -latest_file_version]
set_property board_part $_sombp [current_project]
set_property board_connections {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3} [current_project]
set_property ip_repo_paths [list $OUT/ip_repo] [current_project]
update_ip_catalog

set_property verilog_define {VENDOR_XILINX} [get_filesets sources_1]

source $GCAM/fpga/bd/kv260_fullfab_bd.tcl
build_kv260_fullfab_bd kv260_fullfab_bd $PART
set bd_file [get_files kv260_fullfab_bd.bd]
make_wrapper -files $bd_file -top
set wrap [file join [get_property directory [current_project]] fullfabz.gen sources_1 bd kv260_fullfab_bd hdl kv260_fullfab_bd_wrapper.v]
add_files -norecurse $wrap
add_files -fileset constrs_1 $GCAM/fpga/xdc/kv260_ias_mipi.xdc
add_files -fileset constrs_1 $GCAM/fpga/xdc/kv260_fullfab_clocks.xdc
set_property USED_IN_SYNTHESIS false [get_files -of [get_filesets constrs_1] */kv260_fullfab_clocks.xdc]
if {![info exists ::fullfab_cfg(PKT_MHZ)]} {
  error "configuration not resolved: the block design script has not run"
}
set_property top kv260_fullfab_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
catch {set_property strategy Performance_Explore [get_runs impl_1]}
set _impl [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high $_impl
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $_impl
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $_impl
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore $_impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED true $_impl
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $_impl
puts "IMPL_DIRECTIVES: place=[get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $_impl] route=[get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $_impl] post_route_phys_opt=[get_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED $_impl]"
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "RUN_STATUS: [get_property STATUS [get_runs impl_1]]"
open_run impl_1
set _want_clocks {
  clk_out1_kv260_fullfab_bd_clk_wiz_main_0
  clk_out2_kv260_fullfab_bd_clk_wiz_main_0
  clk_out3_kv260_fullfab_bd_clk_wiz_main_0
  clk_out4_kv260_fullfab_bd_clk_wiz_main_0
}
set _missing {}
foreach _c $_want_clocks {
  if {[llength [get_clocks -quiet $_c]] == 0} { lappend _missing $_c }
}
if {[llength $_missing] > 0} {
  puts "CLKGRP_PRESENT: [lsort [get_clocks -quiet *]]"
  error "CLKGRP_ERR: the constraint file refers to clocks that do not exist: $_missing\n\
    The clock names in kv260_fullfab_clocks.xdc disagree with the block design cell names. \
    If a clock generator cell is renamed, update the constraint file too."
}
puts "CLKGRP_OK: [llength $_want_clocks] clocks — [join $_want_clocks { }]"
puts "FINAL_WNS: [get_property SLACK [get_timing_paths -delay_type max -max_paths 1 -nworst 1]]"

report_cdc -details -file $OUT/cdc_report.rpt
report_cdc -summary -file $OUT/cdc_summary.rpt
puts "CDC_REPORT: $OUT/cdc_report.rpt"
if {[catch {
  set _fh [open $OUT/cdc_summary.rpt r]; set _txt [read $_fh]; close $_fh
  foreach _l [split $_txt "\n"] {
    if {[regexp {(Critical|Warning|Info|Safe|Unsafe|Unknown|CDC-\d+)} $_l]} { puts "CDC| $_l" }
  }
} _e]} { puts "CDC_SUMMARY_READ_FAIL: $_e" }

set _cw [get_msg_config -count -severity "CRITICAL WARNING"]
set _w  [get_msg_config -count -severity "WARNING"]
puts "MSG_COUNT: CRITICAL_WARNING=$_cw  WARNING=$_w"
set _wp [get_timing_paths -delay_type max -max_paths 1 -nworst 1]
puts "FINAL_WORST: [get_property STARTPOINT_PIN $_wp] -> [get_property ENDPOINT_PIN $_wp]"
puts "FINAL_BIT: [glob -nocomplain $OUT/.fullfabz/fullfabz.runs/impl_1/*.bit]"
puts "BUILD_ALL_DONE"
