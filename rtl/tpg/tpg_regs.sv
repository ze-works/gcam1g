// -----------------------------------------------------------------------------
// Module:      tpg_regs
// Description: AXI4-Lite registers local to the test pattern generator. Each
//              block owns its registers rather than sharing a central register
//              file.
// -----------------------------------------------------------------------------

`default_nettype none
module tpg_regs #(
    parameter int unsigned ADDR_W = 8
) (
    input  wire logic              clk,
    input  wire logic              rst_ni,
    input  wire logic [ADDR_W-1:0] s_awaddr,
    input  wire logic              s_awvalid,
    output logic                   s_awready,
    input  wire logic [      31:0] s_wdata,
    input  wire logic [       3:0] s_wstrb,
    input  wire logic              s_wvalid,
    output logic                   s_wready,
    output logic      [       1:0] s_bresp,
    output logic                   s_bvalid,
    input  wire logic              s_bready,
    input  wire logic [ADDR_W-1:0] s_araddr,
    input  wire logic              s_arvalid,
    output logic                   s_arready,
    output logic      [      31:0] s_rdata,
    output logic      [       1:0] s_rresp,
    output logic                   s_rvalid,
    input  wire logic              s_rready,
    output logic      [       3:0] pattern_select_o,
    output logic                   tpg_enable_o
);
  typedef enum logic [ADDR_W-1:0] {
    R_CTRL = 'h00,
    R_ID   = 'h04
  } csr_e;
  localparam logic [31:0] ID_VAL = 32'h54504730;

  logic [31:0] ctrl_q;
  assign pattern_select_o = ctrl_q[3:0];
  assign tpg_enable_o     = ctrl_q[8];

  logic aw_hs;
  logic w_hs;
  logic wr_commit;
  assign aw_hs = s_awvalid & s_awready;
  assign w_hs  = s_wvalid & s_wready;
  logic              awaddr_q_v;
  logic [ADDR_W-1:0] awaddr_q;
  logic              wdata_v;
  logic [      31:0] wdata_q;
  logic [       3:0] wstrb_q;

  assign s_awready = ~awaddr_q_v & ~s_bvalid;
  assign s_wready  = ~wdata_v & ~s_bvalid;
  assign wr_commit = awaddr_q_v & wdata_v & ~s_bvalid;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      awaddr_q_v <= 1'b0;
      wdata_v    <= 1'b0;
      awaddr_q   <= '0;
      wdata_q    <= '0;
      wstrb_q    <= '0;
      ctrl_q     <= 32'h0000_0003;
      s_bvalid   <= 1'b0;
      s_bresp    <= 2'b00;
    end else begin
      if (aw_hs) begin
        awaddr_q_v <= 1'b1;
        awaddr_q   <= s_awaddr;
      end
      if (w_hs) begin
        wdata_v <= 1'b1;
        wdata_q <= s_wdata;
        wstrb_q <= s_wstrb;
      end
      if (wr_commit) begin
        if (awaddr_q == R_CTRL) begin
          if (wstrb_q[0]) ctrl_q[7:0] <= wdata_q[7:0];
          if (wstrb_q[1]) ctrl_q[15:8] <= wdata_q[15:8];
          if (wstrb_q[2]) ctrl_q[23:16] <= wdata_q[23:16];
          if (wstrb_q[3]) ctrl_q[31:24] <= wdata_q[31:24];
        end
        s_bvalid   <= 1'b1;
        s_bresp    <= 2'b00;
        awaddr_q_v <= 1'b0;
        wdata_v    <= 1'b0;
      end
      if (s_bvalid & s_bready) s_bvalid <= 1'b0;
    end
  end

  logic ar_hs;
  assign ar_hs     = s_arvalid & s_arready;
  assign s_arready = ~s_rvalid;
  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      s_rvalid <= 1'b0;
      s_rdata  <= '0;
      s_rresp  <= 2'b00;
    end else begin
      if (ar_hs) begin
        s_rvalid <= 1'b1;
        s_rresp  <= 2'b00;
        unique case (s_araddr)
          R_CTRL:  s_rdata <= ctrl_q;
          R_ID:    s_rdata <= ID_VAL;
          default: s_rdata <= 32'h0;
        endcase
      end else if (s_rvalid & s_rready) s_rvalid <= 1'b0;
    end
  end
endmodule
`default_nettype wire
