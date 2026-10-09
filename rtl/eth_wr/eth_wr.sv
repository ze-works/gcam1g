// -----------------------------------------------------------------------------
// Module:      eth_wr
// Description: Block design wrapper for the DDR ring writer. Accepts an
//              Ethernet frame byte stream and writes it into the DDR slot ring,
//              exposing the producer index. Ring geometry is set by block
//              design parameters.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module eth_wr #(
    parameter int unsigned AXI_ADDR_W  = 40,
    parameter int unsigned AXI_DATA_W  = 128,
    parameter int unsigned AXI_ID_W    = 4,
    parameter int unsigned SLOT_SIZE_B = 8192,
    parameter int unsigned NUM_SLOTS   = 16384
) (
    input wire clk,
    input wire rst_ni,

    input  wire  [AXI_ADDR_W-1:0] ring_base_addr_i,
    input  wire  [          31:0] consumer_idx_i,
    output logic [          31:0] producer_idx_o,
    output logic                  pkt_done_o,
    output logic                  err_o,

    input wire drop_on_full_i,

    input  wire  [  AXI_DATA_W-1:0] s_axis_tdata,
    input  wire  [AXI_DATA_W/8-1:0] s_axis_tkeep,
    input  wire                     s_axis_tvalid,
    output logic                    s_axis_tready,
    input  wire                     s_axis_tlast,

    output logic [    AXI_ID_W-1:0] m_axi_awid,
    output logic [  AXI_ADDR_W-1:0] m_axi_awaddr,
    output logic [             7:0] m_axi_awlen,
    output logic [             2:0] m_axi_awsize,
    output logic [             1:0] m_axi_awburst,
    output logic                    m_axi_awvalid,
    input  wire                     m_axi_awready,
    output logic [  AXI_DATA_W-1:0] m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0] m_axi_wstrb,
    output logic                    m_axi_wlast,
    output logic                    m_axi_wvalid,
    input  wire                     m_axi_wready,
    input  wire  [    AXI_ID_W-1:0] m_axi_bid,
    input  wire  [             1:0] m_axi_bresp,
    input  wire                     m_axi_bvalid,
    output logic                    m_axi_bready,
    output logic [    AXI_ID_W-1:0] m_axi_arid,
    output logic [  AXI_ADDR_W-1:0] m_axi_araddr,
    output logic [             7:0] m_axi_arlen,
    output logic [             2:0] m_axi_arsize,
    output logic [             1:0] m_axi_arburst,
    output logic                    m_axi_arvalid,
    input  wire                     m_axi_arready,
    input  wire  [    AXI_ID_W-1:0] m_axi_rid,
    input  wire  [  AXI_DATA_W-1:0] m_axi_rdata,
    input  wire  [             1:0] m_axi_rresp,
    input  wire                     m_axi_rlast,
    input  wire                     m_axi_rvalid,
    output logic                    m_axi_rready
);

  if ((SLOT_SIZE_B & (SLOT_SIZE_B - 1)) != 0) begin : g_slot_pow2
    $error("SLOT_SIZE_B(%0d) must be a power of two (slot index uses shift/mask)", SLOT_SIZE_B);
  end
  if ((NUM_SLOTS & (NUM_SLOTS - 1)) != 0) begin : g_nslots_pow2
    $error("NUM_SLOTS(%0d) must be a power of two (ring wrap uses mask)", NUM_SLOTS);
  end
  if (SLOT_SIZE_B < 4096) begin : g_slot_min
    $error("SLOT_SIZE_B(%0d) must be >= 4096 (AXI bursts assume a 4KB boundary)", SLOT_SIZE_B);
  end

  eth_wr_pkt #(
      .AXI_ADDR_W(AXI_ADDR_W),
      .AXI_DATA_W(AXI_DATA_W),
      .AXI_ID_W  (AXI_ID_W),

      .SLOT_SIZE_B(SLOT_SIZE_B),
      .NUM_SLOTS  (NUM_SLOTS)
  ) u_wr (
      .clk             (clk),
      .rst_ni          (rst_ni),
      .ring_base_addr_i(ring_base_addr_i),
      .consumer_idx_i  (consumer_idx_i),
      .producer_idx_o  (producer_idx_o),
      .pkt_done_o      (pkt_done_o),
      .err_o           (err_o),
      .drop_on_full_i  (drop_on_full_i),
      .s_axis_tdata_i  (s_axis_tdata),
      .s_axis_tkeep_i  (s_axis_tkeep),
      .s_axis_tvalid_i (s_axis_tvalid),
      .s_axis_tready_o (s_axis_tready),
      .s_axis_tlast_i  (s_axis_tlast),
      .m_axi_awid_o    (m_axi_awid),
      .m_axi_awaddr_o  (m_axi_awaddr),
      .m_axi_awlen_o   (m_axi_awlen),
      .m_axi_awsize_o  (m_axi_awsize),
      .m_axi_awburst_o (m_axi_awburst),
      .m_axi_awvalid_o (m_axi_awvalid),
      .m_axi_awready_i (m_axi_awready),
      .m_axi_wdata_o   (m_axi_wdata),
      .m_axi_wstrb_o   (m_axi_wstrb),
      .m_axi_wlast_o   (m_axi_wlast),
      .m_axi_wvalid_o  (m_axi_wvalid),
      .m_axi_wready_i  (m_axi_wready),
      .m_axi_bid_i     (m_axi_bid),
      .m_axi_bresp_i   (m_axi_bresp),
      .m_axi_bvalid_i  (m_axi_bvalid),
      .m_axi_bready_o  (m_axi_bready)
  );

  always_comb begin
    m_axi_arid    = '0;
    m_axi_araddr  = '0;
    m_axi_arlen   = '0;
    m_axi_arsize  = 3'(0);
    m_axi_arburst = 2'b01;
    m_axi_arvalid = 1'b0;
    m_axi_rready  = 1'b1;
  end

  logic _unused_rd;
  assign _unused_rd = &{1'b0, m_axi_arready, m_axi_rid, m_axi_rdata, m_axi_rresp,
                        m_axi_rlast, m_axi_rvalid};

endmodule : eth_wr

`default_nettype wire
