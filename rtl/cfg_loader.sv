// cfg_loader.sv -- writes a configuration preset into config_regs.
//
// Two ROM images, one per committed config, each the exact register-write
// sequence export_config.py emits, ending in CFG_COMMIT. On reset release and
// whenever the synchronized preset switch changes, the selected image is
// replayed one write per cycle.
//
// The interlock with the replay runs both ways:
//   * busy is high while a load is DUE (even if deferred), while it runs, and
//     during the final registered write -- so a replay can start only when no
//     configuration change is pending or in flight, and one started after busy
//     falls always sees the new configuration active;
//   * a due load does not start while hold_off is high (a replay is running),
//     so one replay is never decided under two presets.
// A switch change during a load is latched: the running image finishes and
// commits, then the new one loads.
module cfg_loader
  import market_pkg::*;
#(
  parameter string MEM_BASE  = "rtl/mem/rom_cfg_baseline.mem",
  parameter string MEM_TUNED = "rtl/mem/rom_cfg_tuned.mem"
) (
  input  logic                  clk,
  input  logic                  rst_n,
  input  logic                  sw_preset,   // asynchronous
  input  logic                  hold_off,    // defer starting a load
  output logic [CFG_ADDR_W-1:0] cfg_addr,
  output logic [CFG_DATA_W-1:0] cfg_wdata,
  output logic                  cfg_we,
  output logic                  busy,
  output logic                  preset       // preset most recently selected
);
  localparam int N_CFG      = 13;            // == len(cfg_addr_e); pytest pins it
  localparam int CFG_WORD_W = 40;            // 2 hex digits addr, 8 hex digits data

  /* verilator lint_off UNUSEDSIGNAL */
  // The address byte is 8 bits in the image; only CFG_ADDR_W of them are used.
  logic [CFG_WORD_W-1:0] rom_base  [N_CFG];
  logic [CFG_WORD_W-1:0] rom_tuned [N_CFG];
  logic [CFG_WORD_W-1:0] word;
  /* verilator lint_on UNUSEDSIGNAL */
  initial begin
    $readmemh(MEM_BASE,  rom_base);
    $readmemh(MEM_TUNED, rom_tuned);
  end

  (* ASYNC_REG = "TRUE" *) logic s1;
  (* ASYNC_REG = "TRUE" *) logic s2;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin s1 <= 1'b0; s2 <= 1'b0; end
    else        begin s1 <= sw_preset; s2 <= s1; end
  end

  logic                     loading, loaded, start_load;
  logic [$clog2(N_CFG)-1:0] idx;

  assign start_load = !loading && (!loaded || (s2 != preset));
  assign word = preset ? rom_tuned[idx] : rom_base[idx];
  assign busy = start_load || loading || cfg_we;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      loading <= 1'b0; loaded <= 1'b0; idx <= '0; preset <= 1'b0;
      cfg_we <= 1'b0; cfg_addr <= '0; cfg_wdata <= '0;
    end else begin
      cfg_we <= 1'b0;
      if (!loading) begin
        if (start_load && !hold_off) begin
          loading <= 1'b1; idx <= '0; preset <= s2;
        end
      end else begin
        cfg_we    <= 1'b1;
        cfg_addr  <= word[32 +: CFG_ADDR_W];
        cfg_wdata <= word[31:0];
        if (idx == ($clog2(N_CFG))'(N_CFG - 1)) begin
          loading <= 1'b0; loaded <= 1'b1;
        end else begin
          idx <= idx + 1'b1;
        end
      end
    end
  end
endmodule
