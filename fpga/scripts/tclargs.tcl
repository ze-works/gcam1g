# -----------------------------------------------------------------------------
# File:        tclargs.tcl
# Description: Parses key=value arguments into a global array. The board
#              definition is injected this way rather than hardcoded, so the
#              same scripts build any board.
# -----------------------------------------------------------------------------

namespace eval tclargs {
  proc parse {} {
    global argv opt
    array unset opt
    foreach a $argv {
      set i [string first = $a]
      if {$i < 0} { error "tclargs: expected key=value, got '$a'" }
      set opt([string range $a 0 [expr {$i - 1}]]) [string range $a [expr {$i + 1}] end]
    }
  }
  proc require {args} {
    global opt
    parse
    set missing {}
    foreach k $args { if {![info exists opt($k)]} { lappend missing $k } }
    if {[llength $missing]} {
      puts stderr "ERROR: missing -tclargs: [join $missing { }] (run via `fpprj build --board <b>`)"
      exit 2
    }
  }
  proc filelist {path} {
    set fh [open $path r]
    set files {}
    foreach line [split [read $fh] \n] {
      set line [string trim $line]
      if {$line ne "" && [string index $line 0] ne "#"} { lappend files $line }
    }
    close $fh
    return $files
  }
}
