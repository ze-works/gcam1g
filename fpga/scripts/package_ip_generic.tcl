# -----------------------------------------------------------------------------
# File:        package_ip_generic.tcl
# Description: Packages one RTL module as a block design IP. Standard bus
#              interfaces are inferred from the port names.
# -----------------------------------------------------------------------------

source [file dirname [info script]]/tclargs.tcl
tclargs::require part name top files out

set part  $opt(part)
set name  $opt(name)
set top   $opt(top)
set out   $opt(out)
set iprepo $out/ip_repo
set tmp    $out/.ip_tmp_$name

file mkdir $iprepo
file delete -force $tmp
create_project ${name}_ip $tmp/proj -part $part -force

set flist {}
foreach f [split $opt(files) ,] {
  set f [string trim $f]
  if {$f eq ""} continue
  lappend flist $f
}
add_files -norecurse $flist
set_property top $top [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir $tmp -vendor user.org -library gcam \
  -taxonomy /UserIP -import_files -force
set core [ipx::current_core]
set_property name         $name $core
set_property display_name "$name (gcam1g fullfab stage)" $core
set_property description   "gcam1g full-fabric pipeline-stage IP (clean-room MIT)" $core
set_property version       1.0 $core
set_property core_revision 1   $core

foreach busif {s_axil m_axis s_axis m_axi m_axi_wr m_axi_rd s_wr s_rd} {
  catch {ipx::associate_bus_interfaces -busif $busif -clock clk $core}
}
catch {
  set rstif [ipx::get_bus_interfaces rst_ni -of_objects $core]
  set p [ipx::get_bus_parameters POLARITY -of_objects $rstif]
  set_property value ACTIVE_LOW $p
}

ipx::create_xgui_files $core
ipx::update_checksums   $core
ipx::save_core          $core
file delete -force $iprepo/$name
file copy   -force $tmp $iprepo/$name

puts "==== inferred bus interfaces ($name) ===="
set _nif 0
foreach b [ipx::get_bus_interfaces -of_objects $core] {
  puts "  [get_property name $b]  ([get_property bus_type_vlnv $b])  mode=[get_property interface_mode $b]"
  incr _nif
}
puts "IP_PACKAGE_OK: $iprepo/$name ($_nif bus interfaces)"
