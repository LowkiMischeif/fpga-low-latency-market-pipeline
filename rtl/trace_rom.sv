// trace_rom.sv -- the on-chip event trace, initialised from a .mem image
// written by scripts/generate_events.py. Registered read so it infers BRAM.
module trace_rom
  import market_pkg::*;
#(
  parameter int    N        = 2000,
  parameter string MEM_FILE = "rtl/mem/rom_trace.mem"
) (
  input  logic                  clk,
  input  logic [$clog2(N)-1:0]  addr,
  output logic [EVENT_W-1:0]    data
);
  (* rom_style = "block" *) logic [EVENT_W-1:0] mem [N];
  initial $readmemh(MEM_FILE, mem);
  always_ff @(posedge clk) data <= mem[addr];
endmodule
