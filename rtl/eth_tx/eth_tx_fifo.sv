// -----------------------------------------------------------------------------
// Module:      eth_tx_fifo
// Description: Dual-clock FIFO with Gray-coded pointers. Carries the packet
//              byte stream across the RX and packet clock domains. Pointers are
//              synchronised with two flip-flop stages; depth is a power of two.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module eth_tx_fifo #(
    parameter int unsigned DATA_W = 8,
    parameter int unsigned DEPTH  = 16
) (
    input  wire logic              wr_clk_i,
    input  wire logic              wr_rst_ni,
    input  wire logic              wr_valid_i,
    output logic                   wr_ready_o,
    input  wire logic [DATA_W-1:0] wr_data_i,
    input  wire logic              rd_clk_i,
    input  wire logic              rd_rst_ni,
    output logic                   rd_valid_o,
    input  wire logic              rd_ready_i,
    output logic      [DATA_W-1:0] rd_data_o
);

  localparam int unsigned ADDR_W = $clog2(DEPTH);
  localparam int unsigned PTR_W  = ADDR_W + 1;

  initial begin : g_param_check
    if (DEPTH < 4) begin
      $error("eth_tx_fifo: DEPTH (%0d) must be >= 4", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin
      $error("eth_tx_fifo: DEPTH (%0d) must be a power of 2", DEPTH);
    end
    if (DATA_W < 1) begin
      $error("eth_tx_fifo: DATA_W (%0d) must be >= 1", DATA_W);
    end
`ifdef VENDOR_XILINX
    if (DEPTH < 16) begin
      $error(
          "eth_tx_fifo: DEPTH (%0d) < 16 is not supported by xpm_fifo_sync (VENDOR_XILINX). Minimum FIFO_WRITE_DEPTH is 16; raise DEPTH at the instantiation site.",
          DEPTH);
    end
`endif
  end

`ifdef VENDOR_XILINX

  localparam int unsigned RST_STRETCH_CYCLES = 4;
  localparam int unsigned RST_STRETCH_W = $clog2(RST_STRETCH_CYCLES + 1);

  logic [RST_STRETCH_W-1:0] rst_stretch_q;
  logic                     xpm_rst;
  logic                     xpm_full;
  logic                     xpm_empty;
  logic                     xpm_wr_rst_busy;
  logic                     xpm_rd_rst_busy;

  always_ff @(posedge wr_clk_i) begin : p_rst_stretch
    if (!wr_rst_ni) begin
      rst_stretch_q <= RST_STRETCH_W'(RST_STRETCH_CYCLES);
    end else if (rst_stretch_q != '0) begin
      rst_stretch_q <= rst_stretch_q - 1'b1;
    end
  end

  assign xpm_rst = (rst_stretch_q != '0);

  xpm_fifo_sync #(
      .FIFO_MEMORY_TYPE ("auto"),
      .ECC_MODE         ("no_ecc"),
      .FIFO_WRITE_DEPTH (DEPTH),
      .WRITE_DATA_WIDTH (DATA_W),
      .READ_DATA_WIDTH  (DATA_W),
      .READ_MODE        ("fwft"),
      .FIFO_READ_LATENCY(1),
      .FULL_RESET_VALUE (0),
      .DOUT_RESET_VALUE ("0"),
      .WAKEUP_TIME      (0)
  ) u_xpm_fifo_sync (
      .sleep        (1'b0),
      .rst          (xpm_rst),
      .wr_clk       (wr_clk_i),
      .wr_en        (wr_valid_i & wr_ready_o),
      .din          (wr_data_i),
      .full         (xpm_full),
      .prog_full    (),
      .wr_data_count(),
      .overflow     (),
      .wr_rst_busy  (xpm_wr_rst_busy),
      .almost_full  (),
      .wr_ack       (),
      .rd_en        (rd_valid_o & rd_ready_i),
      .dout         (rd_data_o),
      .empty        (xpm_empty),
      .prog_empty   (),
      .rd_data_count(),
      .underflow    (),
      .rd_rst_busy  (xpm_rd_rst_busy),
      .almost_empty (),
      .data_valid   (),
      .injectsbiterr(1'b0),
      .injectdbiterr(1'b0),
      .sbiterr      (),
      .dbiterr      ()
  );

  assign wr_ready_o = ~xpm_full & ~xpm_wr_rst_busy;
  assign rd_valid_o = ~xpm_empty & ~xpm_rd_rst_busy;

  logic _unused_rd_domain;
  assign _unused_rd_domain = &{1'b0, rd_clk_i, rd_rst_ni};

`ifdef SIM_ONLY
  always_ff @(posedge wr_clk_i) begin : p_assert_same_clk_rst
    assert (rd_clk_i === 1'b1 || rd_clk_i === 1'b0)
    else $error("eth_tx_fifo(VENDOR_XILINX): rd_clk_i is X/Z @ t=%0t", $time);
    assert (rd_clk_i === wr_clk_i)
    else
      $error(
          "eth_tx_fifo(VENDOR_XILINX): wr_clk_i and rd_clk_i differ at this wr_clk_i edge — this branch only supports a single shared clock @ t=%0t",
          $time
      );
    assert (rd_rst_ni === wr_rst_ni)
    else
      $error(
          "eth_tx_fifo(VENDOR_XILINX): wr_rst_ni and rd_rst_ni differ — this branch only supports a single shared reset @ t=%0t",
          $time
      );
  end
`endif

`else
  logic [DATA_W-1:0] mem_q         [0:DEPTH-1];

  logic [ PTR_W-1:0] wr_bin_q;
  logic [ PTR_W-1:0] wr_bin_d;
  logic [ PTR_W-1:0] rd_bin_q;
  logic [ PTR_W-1:0] rd_bin_d;

  logic [ PTR_W-1:0] wr_gray_q;
  logic [ PTR_W-1:0] wr_gray_d;
  logic [ PTR_W-1:0] rd_gray_q;
  logic [ PTR_W-1:0] rd_gray_d;

  (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE",
     syn_preserve = 1, syn_keep = 1, syn_replicate = 0, syn_noprune = 1 *)
  logic [ PTR_W-1:0] wr_gray_sync_q[      0:1];

  (* ASYNC_REG = "TRUE", DONT_TOUCH = "TRUE",
     syn_preserve = 1, syn_keep = 1, syn_replicate = 0, syn_noprune = 1 *)
  logic [ PTR_W-1:0] rd_gray_sync_q[      0:1];

  function automatic logic [PTR_W-1:0] bin2gray(input logic [PTR_W-1:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function automatic logic [PTR_W-1:0] gray2bin(input logic [PTR_W-1:0] g);
    logic [PTR_W-1:0] b;
    int               i;
    b[PTR_W-1] = g[PTR_W-1];
    for (i = PTR_W - 2; i >= 0; i--) begin
      b[i] = b[i+1] ^ g[i];
    end
    gray2bin = b;
  endfunction

  logic [PTR_W-1:0] rd_gray_sync_in_wr;
  logic [PTR_W-1:0] wr_gray_sync_in_rd;
  logic             full_q;
  logic             empty_q;

  assign rd_gray_sync_in_wr = rd_gray_sync_q[1];
  assign wr_gray_sync_in_rd = wr_gray_sync_q[1];

  logic do_write;
  logic do_read;

  assign do_write = wr_valid_i & wr_ready_o;
  assign do_read  = rd_valid_o & rd_ready_i;

  always_comb begin : p_wr_comb
    wr_bin_d  = wr_bin_q + (do_write ? {{(PTR_W - 1) {1'b0}}, 1'b1} : '0);
    wr_gray_d = bin2gray(wr_bin_d);
  end

  always_comb begin : p_rd_comb
    rd_bin_d  = rd_bin_q + (do_read ? {{(PTR_W - 1) {1'b0}}, 1'b1} : '0);
    rd_gray_d = bin2gray(rd_bin_d);
  end

  always_ff @(posedge wr_clk_i) begin : p_wr_seq
    if (!wr_rst_ni) begin
      wr_bin_q  <= '0;
      wr_gray_q <= '0;
    end else begin
      wr_bin_q  <= wr_bin_d;
      wr_gray_q <= wr_gray_d;
      if (do_write) begin
        mem_q[wr_bin_q[ADDR_W-1:0]] <= wr_data_i;
      end
    end
  end

  always_ff @(posedge rd_clk_i) begin : p_rd_seq
    if (!rd_rst_ni) begin
      rd_bin_q  <= '0;
      rd_gray_q <= '0;
    end else begin
      rd_bin_q  <= rd_bin_d;
      rd_gray_q <= rd_gray_d;
    end
  end

  always_ff @(posedge rd_clk_i) begin : p_wr_gray_sync
    if (!rd_rst_ni) begin
      wr_gray_sync_q[0] <= '0;
      wr_gray_sync_q[1] <= '0;
    end else begin
      wr_gray_sync_q[0] <= wr_gray_q;
      wr_gray_sync_q[1] <= wr_gray_sync_q[0];
    end
  end

  always_ff @(posedge wr_clk_i) begin : p_rd_gray_sync
    if (!wr_rst_ni) begin
      rd_gray_sync_q[0] <= '0;
      rd_gray_sync_q[1] <= '0;
    end else begin
      rd_gray_sync_q[0] <= rd_gray_q;
      rd_gray_sync_q[1] <= rd_gray_sync_q[0];
    end
  end

  logic full_d;
  logic empty_d;

  always_comb begin : p_full_empty
    empty_d = (rd_gray_d == wr_gray_sync_in_rd);
    full_d  = (wr_gray_d == {~rd_gray_sync_in_wr[PTR_W-1:PTR_W-2], rd_gray_sync_in_wr[PTR_W-3:0]});
  end

  always_ff @(posedge wr_clk_i) begin : p_full_q
    if (!wr_rst_ni) begin
      full_q <= 1'b0;
    end else begin
      full_q <= full_d;
    end
  end

  always_ff @(posedge rd_clk_i) begin : p_empty_q
    if (!rd_rst_ni) begin
      empty_q <= 1'b1;
    end else begin
      empty_q <= empty_d;
    end
  end

  assign wr_ready_o = ~full_q;
  assign rd_valid_o = ~empty_q;
  assign rd_data_o  = mem_q[rd_bin_q[ADDR_W-1:0]];

`endif

`ifdef SIM_ONLY
  always_ff @(posedge wr_clk_i) begin : p_assert_wr
    if (wr_rst_ni === 1'b1 && wr_valid_i === 1'b1 && wr_ready_o === 1'b0) begin
    end
    if (wr_rst_ni === 1'b1) begin
      assert (!$isunknown(wr_valid_i))
      else $error("eth_tx_fifo: wr_valid_i is X/Z @ t=%0t", $time);
    end
  end
  always_ff @(posedge rd_clk_i) begin : p_assert_rd
    if (rd_rst_ni === 1'b1) begin
      assert (!$isunknown(rd_ready_i))
      else $error("eth_tx_fifo: rd_ready_i is X/Z @ t=%0t", $time);
    end
  end
`endif

endmodule : eth_tx_fifo

`default_nettype wire
