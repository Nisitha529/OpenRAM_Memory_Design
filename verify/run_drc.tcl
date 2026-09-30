gds read ../my_first_sram.gds
load my_first_sram
select top cell
drc catchup
drc check
drc catchup
set n [drc listall count total]
puts "DRC_RESULT: $n"
drc count total
quit -noprompt
