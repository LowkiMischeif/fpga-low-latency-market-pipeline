// Randomized replay of a generated trace through event_decoder ->
// sequence_checker, with randomized valid gaps and randomized backpressure.
// Every output is scoreboarded against the golden expectations from
// scripts/generate_events.py.
//
// The golden CSV and the RTL could in principle be wrong in the same way,
// which is why tb_event_decoder.sv and tb_sequence_checker.sv carry
// hand-written vectors and tb/assertions.sv carries trace-independent
// properties. This testbench adds volume and backpressure, not ground truth.
module tb_decode_validate;
  import market_pkg::*;

  localparam int MAX_EVENTS = 8192;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [EVENT_W-1:0] s_data;
  logic               s_valid, s_ready;

  market_event_t      d_event, m_event;
  event_err_t         d_err, m_err;
  logic               d_valid, d_ready, m_valid, m_ready;
  logic [CNT_W-1:0]   gap_count, stale_count, missed_total, bad_event_count;

  event_decoder u_dec (
    .clk(clk), .rst_n(rst_n),
    .s_data(s_data), .s_valid(s_valid), .s_ready(s_ready),
    .m_event(d_event), .m_err(d_err), .m_valid(d_valid), .m_ready(d_ready)
  );

  sequence_checker u_seq (
    .clk(clk), .rst_n(rst_n),
    .s_event(d_event), .s_err(d_err), .s_valid(d_valid), .s_ready(d_ready),
    .m_event(m_event), .m_err(m_err), .m_valid(m_valid), .m_ready(m_ready),
    .gap_count(gap_count), .stale_count(stale_count),
    .missed_total(missed_total), .bad_event_count(bad_event_count)
  );

  // No bind statements here: tb/bind_assertions.sv binds the checker to both
  // stages for the whole compiled library.

  logic [EVENT_W-1:0] trace_words [0:MAX_EVENTS-1];
  int exp_etype  [0:MAX_EVENTS-1];
  int exp_symbol [0:MAX_EVENTS-1];
  int exp_side   [0:MAX_EVENTS-1];
  int exp_price  [0:MAX_EVENTS-1];
  int exp_qty    [0:MAX_EVENTS-1];
  int exp_seq    [0:MAX_EVENTS-1];
  int exp_btype  [0:MAX_EVENTS-1];
  int exp_bside  [0:MAX_EVENTS-1];
  int exp_brsv   [0:MAX_EVENTS-1];
  int exp_gap    [0:MAX_EVENTS-1];
  int exp_stale  [0:MAX_EVENTS-1];

  int n_events = 0;
  int seed = 1;
  int errors = 0;
  int sent = 0, recvd = 0;
  bit loaded = 1'b0;

  // Read the golden CSV. Column order must match CSV_COLUMNS in
  // generate_events.py.
  task automatic load_expected(string path);
    int fd, r, w;
    string line;
    fd = $fopen(path, "r");
    if (fd == 0) $fatal(1, "FAIL: cannot open %s", path);
    r = $fgets(line, fd);              // header
    n_events = 0;
    while ($fgets(line, fd) != 0) begin
      r = $sscanf(line, "%h,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
                  w,
                  exp_etype[n_events], exp_symbol[n_events], exp_side[n_events],
                  exp_price[n_events], exp_qty[n_events], exp_seq[n_events],
                  exp_btype[n_events], exp_bside[n_events], exp_brsv[n_events],
                  exp_gap[n_events], exp_stale[n_events]);
      if (r != 12)
        $fatal(1, "FAIL: malformed CSV row %0d (parsed %0d of 12 fields)",
               n_events, r);
      n_events++;
      if (n_events >= MAX_EVENTS) $fatal(1, "FAIL: trace exceeds MAX_EVENTS");
    end
    $fclose(fd);
  endtask

  initial begin
    string hex_path, csv_path;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    if (!$value$plusargs("HEX=%s", hex_path)) hex_path = "tb/traces/random.hex";
    if (!$value$plusargs("CSV=%s", csv_path))
      csv_path = "tb/traces/random_expected.csv";
    $display("INFO: seed=%0d hex=%s csv=%s", seed, hex_path, csv_path);
    $readmemh(hex_path, trace_words);
    load_expected(csv_path);
    $display("INFO: loaded %0d events", n_events);
    loaded = 1'b1;
  end

  // Driver: randomized valid gaps.
  initial begin
    s_valid = 1'b0;
    s_data  = '0;
    wait (loaded);
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    while (sent < n_events) begin
      if ($urandom_range(0, 3) == 0) begin
        @(negedge clk);
        s_valid = 1'b0;
        repeat ($urandom_range(1, 3)) @(posedge clk);
      end
      @(negedge clk);
      while (!s_ready) @(negedge clk);
      s_data  = trace_words[sent];
      s_valid = 1'b1;
      @(posedge clk);
      sent++;
      @(negedge clk);
      s_valid = 1'b0;
    end
  end

  // Backpressure: randomly deassert m_ready to prove the pipe stalls as a
  // unit without losing or reordering events.
  //
  // Driven on the NEGEDGE. Assigning m_ready at the posedge races both the
  // DUT and the scoreboard, which sample it on that same edge -- the symptom
  // is outputs that appear to duplicate and a scoreboard that drifts behind
  // the trace.
  initial begin
    m_ready = 1'b1;
    forever begin
      @(negedge clk);
      if ($urandom_range(0, 4) == 0) begin
        m_ready = 1'b0;
        repeat ($urandom_range(1, 4)) @(negedge clk);
        m_ready = 1'b1;
      end
    end
  end

  // Scoreboard: every handed-off output must match the golden row, in order.
  always_ff @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      if (recvd >= n_events) begin
        errors++;
        $error("FAIL: extra output beyond %0d events", n_events);
      end else begin
        if (m_event.etype  !== exp_etype[recvd][TYPE_W-1:0])    begin errors++; $error("FAIL[%0d]: etype exp %0h got %0h",    recvd, exp_etype[recvd],  m_event.etype);  end
        if (m_event.symbol !== exp_symbol[recvd][SYMBOL_W-1:0]) begin errors++; $error("FAIL[%0d]: symbol exp %0h got %0h",   recvd, exp_symbol[recvd], m_event.symbol); end
        if (m_event.side   !== exp_side[recvd][SIDE_W-1:0])     begin errors++; $error("FAIL[%0d]: side exp %0h got %0h",     recvd, exp_side[recvd],   m_event.side);   end
        if (m_event.price  !== exp_price[recvd][PRICE_W-1:0])   begin errors++; $error("FAIL[%0d]: price exp %0h got %0h",    recvd, exp_price[recvd],  m_event.price);  end
        if (m_event.qty    !== exp_qty[recvd][QTY_W-1:0])       begin errors++; $error("FAIL[%0d]: qty exp %0h got %0h",      recvd, exp_qty[recvd],    m_event.qty);    end
        if (m_event.seq    !== exp_seq[recvd][SEQ_W-1:0])       begin errors++; $error("FAIL[%0d]: seq exp %0h got %0h",      recvd, exp_seq[recvd],    m_event.seq);    end
        if (m_err.bad_type !== exp_btype[recvd][0])             begin errors++; $error("FAIL[%0d]: bad_type exp %0d got %0b", recvd, exp_btype[recvd],  m_err.bad_type); end
        if (m_err.bad_side !== exp_bside[recvd][0])             begin errors++; $error("FAIL[%0d]: bad_side exp %0d got %0b", recvd, exp_bside[recvd],  m_err.bad_side); end
        if (m_err.bad_rsv  !== exp_brsv[recvd][0])              begin errors++; $error("FAIL[%0d]: bad_rsv exp %0d got %0b",  recvd, exp_brsv[recvd],   m_err.bad_rsv);  end
        if (m_err.gap      !== exp_gap[recvd][0])               begin errors++; $error("FAIL[%0d]: gap exp %0d got %0b",      recvd, exp_gap[recvd],    m_err.gap);      end
        if (m_err.stale    !== exp_stale[recvd][0])             begin errors++; $error("FAIL[%0d]: stale exp %0d got %0b",    recvd, exp_stale[recvd],  m_err.stale);    end
        recvd++;
      end
    end
  end

  initial begin
    wait (loaded);
    wait (recvd == n_events);
    repeat (5) @(posedge clk);
    if (errors != 0)
      $fatal(1, "FAIL: %0d mismatches over %0d events (seed=%0d)",
             errors, n_events, seed);
    $display("PASS: tb_decode_validate -- %0d events, seed=%0d", n_events, seed);
    $display("INFO: gap_count=%0d stale_count=%0d missed_total=%0d bad_event_count=%0d",
             gap_count, stale_count, missed_total, bad_event_count);
    $finish;
  end

  initial begin
    #20000000;
    $fatal(1, "FAIL: timeout -- sent=%0d recvd=%0d of %0d", sent, recvd, n_events);
  end
endmodule
