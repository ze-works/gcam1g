// -----------------------------------------------------------------------------
// Module:      pixpipe_pfc_packer
// Description: Converts 32 bit per pixel video into packed pixel data. Output
//              is a 128 bit AXI-Stream with byte enables, packed according to
//              the pixel format naming convention. The format is selected at
//              run time by a register.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module pixpipe_pfc_packer #(
    parameter int unsigned NUM_TAP    = 1,
    parameter int unsigned OUT_DATA_W = 128,
    parameter int unsigned OUT_KEEP_W = OUT_DATA_W / 8
) (
    input wire logic clk,
    input wire logic rst_ni,

    input wire logic [31:0] pixel_format_i,

    input  wire logic [NUM_TAP*32-1:0] s_axis_tdata_i,
    input  wire logic                  s_axis_tvalid_i,
    output logic                       s_axis_tready_o,
    input  wire logic                  s_axis_tuser_i,
    input  wire logic                  s_axis_tlast_i,

    output logic      [OUT_DATA_W-1:0] m_axis_tdata_o,
    output logic      [OUT_KEEP_W-1:0] m_axis_tkeep_o,
    output logic                       m_axis_tvalid_o,
    input  wire logic                  m_axis_tready_i,
    output logic                       m_axis_tuser_o,
    output logic                       m_axis_tlast_o
);

  initial begin
    if (OUT_DATA_W != 128) begin
    end
    if (OUT_KEEP_W != OUT_DATA_W / 8) begin
      $error("pixpipe_pfc_packer: OUT_KEEP_W must equal OUT_DATA_W/8");
    end
  end

  localparam logic [31:0] PFNC_MONO8        = 32'h0108_0001;
  localparam logic [31:0] PFNC_MONO10       = 32'h0110_0003;
  localparam logic [31:0] PFNC_MONO10P      = 32'h010A_0046;
  localparam logic [31:0] PFNC_MONO12       = 32'h0110_0005;
  localparam logic [31:0] PFNC_MONO12P      = 32'h010C_0047;
  localparam logic [31:0] PFNC_MONO16       = 32'h0110_0007;
  localparam logic [31:0] PFNC_MONO10PACKED = 32'h010C_0004;
  localparam logic [31:0] PFNC_MONO12PACKED = 32'h010C_0006;
  localparam logic [31:0] PFNC_BAYERRG8     = 32'h0108_0009;
  localparam logic [31:0] PFNC_BAYERGR8     = 32'h0108_0008;
  localparam logic [31:0] PFNC_BAYERGB8     = 32'h0108_000A;
  localparam logic [31:0] PFNC_BAYERBG8     = 32'h0108_000B;
  localparam logic [31:0] PFNC_BAYERRG10    = 32'h0110_000D;
  localparam logic [31:0] PFNC_BAYERGR10    = 32'h0110_000C;
  localparam logic [31:0] PFNC_BAYERGB10    = 32'h0110_000E;
  localparam logic [31:0] PFNC_BAYERBG10    = 32'h0110_000F;
  localparam logic [31:0] PFNC_BAYERRG10P   = 32'h010A_0058;
  localparam logic [31:0] PFNC_BAYERGR10P   = 32'h010A_0056;
  localparam logic [31:0] PFNC_BAYERGB10P   = 32'h010A_0054;
  localparam logic [31:0] PFNC_BAYERBG10P   = 32'h010A_0052;
  localparam logic [31:0] PFNC_BAYERRG12    = 32'h0110_0011;
  localparam logic [31:0] PFNC_BAYERGR12    = 32'h0110_0010;
  localparam logic [31:0] PFNC_BAYERGB12    = 32'h0110_0012;
  localparam logic [31:0] PFNC_BAYERBG12    = 32'h0110_0013;
  localparam logic [31:0] PFNC_BAYERRG12P   = 32'h010C_0059;
  localparam logic [31:0] PFNC_BAYERGR12P   = 32'h010C_0057;
  localparam logic [31:0] PFNC_BAYERGB12P   = 32'h010C_0055;
  localparam logic [31:0] PFNC_BAYERBG12P   = 32'h010C_0053;
  localparam logic [31:0] PFNC_RGB8         = 32'h0218_0014;

  typedef enum logic [3:0] {
    PCK_MONO8    = 4'd0,
    PCK_LSB16    = 4'd1,
    PCK_LSB10P   = 4'd2,
    PCK_LSB12P   = 4'd3,
    PCK_MONO16   = 4'd4,
    PCK_PAIR10MP = 4'd5,
    PCK_PAIR12MP = 4'd6,
    PCK_RGB8     = 4'd7,
    PCK_UNKNOWN  = 4'd15
  } pck_class_e;

  pck_class_e pck_class;
  always_comb begin
    unique case (pixel_format_i)
      PFNC_MONO8, PFNC_BAYERRG8, PFNC_BAYERGR8, PFNC_BAYERGB8, PFNC_BAYERBG8: pck_class = PCK_MONO8;
      PFNC_MONO10, PFNC_BAYERRG10, PFNC_BAYERGR10,
      PFNC_BAYERGB10, PFNC_BAYERBG10,
      PFNC_MONO12, PFNC_BAYERRG12, PFNC_BAYERGR12,
      PFNC_BAYERGB12, PFNC_BAYERBG12:
      pck_class = PCK_LSB16;
      PFNC_MONO10P, PFNC_BAYERRG10P, PFNC_BAYERGR10P, PFNC_BAYERGB10P, PFNC_BAYERBG10P:
      pck_class = PCK_LSB10P;
      PFNC_MONO12P, PFNC_BAYERRG12P, PFNC_BAYERGR12P, PFNC_BAYERGB12P, PFNC_BAYERBG12P:
      pck_class = PCK_LSB12P;
      PFNC_MONO16: pck_class = PCK_MONO16;
      PFNC_MONO10PACKED: pck_class = PCK_PAIR10MP;
      PFNC_MONO12PACKED: pck_class = PCK_PAIR12MP;
      PFNC_RGB8: pck_class = PCK_RGB8;
      default: pck_class = PCK_UNKNOWN;
    endcase
  end

  function automatic void pfc_emit_pixel(input logic [31:0] pdata, input pck_class_e pc,
                                         input logic [31:0] fmt, input logic pair_have_i,
                                         input logic [11:0] pair_p0_i, output logic [23:0] pv,
                                         output logic [5:0] pb, output logic pe,
                                         output logic pair_have_o, output logic [11:0] pair_p0_o);
    logic [7:0] l_r, l_g, l_b;
    logic [ 9:0] l10;
    logic [11:0] l12;
    logic [15:0] l16;
    logic [9:0] p0a, p1a;
    logic [11:0] p0b, p1b;
    logic [7:0] b0, b1, b2;

    l_r         = pdata[31:24];
    l_g         = pdata[23:16];
    l_b         = pdata[15:8];
    l10         = pdata[31:22];
    l12         = pdata[31:20];
    l16         = pdata[31:16];

    pv          = 24'h0;
    pb          = 6'd0;
    pe          = 1'b0;
    pair_have_o = pair_have_i;
    pair_p0_o   = pair_p0_i;
    p0a         = 10'h0;
    p1a         = 10'h0;
    p0b         = 12'h0;
    p1b         = 12'h0;
    b0          = 8'h0;
    b1          = 8'h0;
    b2          = 8'h0;

    unique case (pc)
      PCK_MONO8: begin
        pv = {16'h0, l_r};
        pb = 6'd8;
        pe = 1'b1;
      end

      PCK_LSB16: begin
        if (fmt == PFNC_MONO10 ||
            fmt == PFNC_BAYERRG10 || fmt == PFNC_BAYERGR10 ||
            fmt == PFNC_BAYERGB10 || fmt == PFNC_BAYERBG10) begin
          pv = {8'h0, 6'h0, l10};
        end else begin
          pv = {8'h0, 4'h0, l12};
        end
        pb = 6'd16;
        pe = 1'b1;
      end

      PCK_LSB10P: begin
        pv = {14'h0, l10};
        pb = 6'd10;
        pe = 1'b1;
      end

      PCK_LSB12P: begin
        pv = {12'h0, l12};
        pb = 6'd12;
        pe = 1'b1;
      end

      PCK_MONO16, PCK_UNKNOWN: begin
        pv = {8'h0, l16};
        pb = 6'd16;
        pe = 1'b1;
      end

      PCK_PAIR10MP: begin
        if (!pair_have_i) begin
          pair_have_o = 1'b1;
          pair_p0_o   = {2'b0, l10};
          pe          = 1'b0;
        end else begin
          p0a         = pair_p0_i[9:0];
          p1a         = l10;
          b0          = p0a[9:2];
          b1          = {p1a[1:0], 2'b00, p0a[1:0], 2'b00};
          b2          = p1a[9:2];
          pv          = {b2, b1, b0};
          pb          = 6'd24;
          pe          = 1'b1;
          pair_have_o = 1'b0;
        end
      end

      PCK_PAIR12MP: begin
        if (!pair_have_i) begin
          pair_have_o = 1'b1;
          pair_p0_o   = l12;
          pe          = 1'b0;
        end else begin
          p0b         = pair_p0_i;
          p1b         = l12;
          b0          = p0b[11:4];
          b1          = {p1b[3:0], p0b[3:0]};
          b2          = p1b[11:4];
          pv          = {b2, b1, b0};
          pb          = 6'd24;
          pe          = 1'b1;
          pair_have_o = 1'b0;
        end
      end

      PCK_RGB8: begin
        pv = {l_b, l_g, l_r};
        pb = 6'd24;
        pe = 1'b1;
      end

      default: begin
        pv = {8'h0, l16};
        pb = 6'd16;
        pe = 1'b1;
      end
    endcase
  endfunction

  logic        pair_have_q;
  logic        pair_have_d;
  logic [11:0] pair_p0_q;
  logic [11:0] pair_p0_d;

  localparam int unsigned MAX_PUSH = NUM_TAP * 24;
  localparam int unsigned BUF_W    = OUT_DATA_W + MAX_PUSH + 8;
  localparam int unsigned BCNT_W   = $clog2(BUF_W + 1);

  logic [     BUF_W-1:0] bit_buf_q;
  logic [     BUF_W-1:0] bit_buf_d;
  logic [    BCNT_W-1:0] bit_cnt_q;
  logic [    BCNT_W-1:0] bit_cnt_d;

  logic                  sof_pending_q;
  logic                  sof_pending_d;
  logic                  eof_pending_q;
  logic                  eof_pending_d;

  logic [OUT_DATA_W-1:0] out_data_q;
  logic [OUT_DATA_W-1:0] out_data_d;
  logic [OUT_KEEP_W-1:0] out_keep_q;
  logic [OUT_KEEP_W-1:0] out_keep_d;
  logic                  out_valid_q;
  logic                  out_valid_d;
  logic                  out_sof_q;
  logic                  out_sof_d;
  logic                  out_last_q;
  logic                  out_last_d;

  logic                  s_ready;
  logic                  in_accept;

  logic                  eol_in;

  always_comb begin
    bit_buf_d     = bit_buf_q;
    bit_cnt_d     = bit_cnt_q;
    out_data_d    = out_data_q;
    out_keep_d    = out_keep_q;
    out_valid_d   = out_valid_q;
    out_sof_d     = out_sof_q;
    out_last_d    = out_last_q;
    sof_pending_d = sof_pending_q;
    eof_pending_d = eof_pending_q;
    pair_have_d   = pair_have_q;
    pair_p0_d     = pair_p0_q;
    eol_in        = 1'b0;

    s_ready       = 1'b0;
    if ((bit_cnt_q + MAX_PUSH) <= BUF_W) begin
      if (!out_valid_q || m_axis_tready_i) begin
        s_ready = 1'b1;
      end
    end

    in_accept = s_ready & s_axis_tvalid_i;

    if (in_accept) begin
      eol_in = s_axis_tlast_i;
      if (s_axis_tuser_i) begin
        sof_pending_d = 1'b1;
      end
    end

    if (out_valid_q && m_axis_tready_i) begin
      out_valid_d = 1'b0;
      out_data_d  = '0;
      out_keep_d  = '0;
      out_sof_d   = 1'b0;
      out_last_d  = 1'b0;
    end

    if (in_accept) begin
      logic [ BUF_W-1:0] buf_acc;
      logic [BCNT_W-1:0] cnt_acc;
      logic              ph;
      logic [      11:0] p0;
      buf_acc = bit_buf_q;
      cnt_acc = bit_cnt_q;
      ph      = pair_have_q;
      p0      = pair_p0_q;
      for (int t = 0; t < NUM_TAP; t++) begin
        logic [     23:0] pv;
        logic [      5:0] pb;
        logic             pe;
        logic             ph_n;
        logic [     11:0] p0_n;
        logic [BUF_W-1:0] mask;
        logic [BUF_W-1:0] shifted;
        pfc_emit_pixel(s_axis_tdata_i[t*32+:32], pck_class, pixel_format_i, ph, p0, pv, pb, pe,
                       ph_n, p0_n);
        if (pe) begin
          mask    = ({BUF_W{1'b1}}) >> (BUF_W - pb);
          shifted = (BUF_W'(pv) & mask) << cnt_acc;
          buf_acc = buf_acc | shifted;
          cnt_acc = cnt_acc + BCNT_W'(pb);
        end
        ph = ph_n;
        p0 = p0_n;
      end
      bit_buf_d   = buf_acc;
      bit_cnt_d   = cnt_acc;
      pair_have_d = ph;
      pair_p0_d   = p0;
    end

    if ((!out_valid_q) || (out_valid_q && m_axis_tready_i)) begin
      logic [BCNT_W-1:0] cnt_after_push;
      logic              do_flush;
      cnt_after_push = bit_cnt_d;

      do_flush       = eol_in;

      if (cnt_after_push >= BCNT_W'(OUT_DATA_W)) begin
        out_data_d    = bit_buf_d[OUT_DATA_W-1:0];
        out_keep_d    = {OUT_KEEP_W{1'b1}};
        out_valid_d   = 1'b1;
        out_sof_d     = sof_pending_d;
        out_last_d    = 1'b0;
        bit_buf_d     = bit_buf_d >> OUT_DATA_W;
        bit_cnt_d     = cnt_after_push - BCNT_W'(OUT_DATA_W);
        sof_pending_d = 1'b0;

        if (do_flush && (bit_cnt_d == '0)) begin
          out_last_d    = 1'b1;
          eof_pending_d = 1'b0;
        end else if (do_flush) begin
          eof_pending_d = 1'b1;
        end
      end else if (do_flush && (cnt_after_push > 0)) begin
        logic [    BCNT_W-1:0] byte_cnt;
        logic [OUT_KEEP_W-1:0] keep;
        byte_cnt = (cnt_after_push + 7) >> 3;
        keep     = '0;
        for (int i = 0; i < OUT_KEEP_W; i++) begin
          if (i < int'(byte_cnt)) keep[i] = 1'b1;
        end
        out_data_d    = bit_buf_d[OUT_DATA_W-1:0];
        out_keep_d    = keep;
        out_valid_d   = 1'b1;
        out_sof_d     = sof_pending_d;
        out_last_d    = 1'b1;
        bit_buf_d     = '0;
        bit_cnt_d     = '0;
        sof_pending_d = 1'b0;
        eof_pending_d = 1'b0;
      end else if (do_flush && (cnt_after_push == 0)) begin
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      bit_buf_q     <= '0;
      bit_cnt_q     <= '0;
      out_data_q    <= '0;
      out_keep_q    <= '0;
      out_valid_q   <= 1'b0;
      out_sof_q     <= 1'b0;
      out_last_q    <= 1'b0;
      sof_pending_q <= 1'b0;
      eof_pending_q <= 1'b0;
      pair_have_q   <= 1'b0;
      pair_p0_q     <= '0;
    end else begin
      bit_buf_q     <= bit_buf_d;
      bit_cnt_q     <= bit_cnt_d;
      out_data_q    <= out_data_d;
      out_keep_q    <= out_keep_d;
      out_valid_q   <= out_valid_d;
      out_sof_q     <= out_sof_d;
      out_last_q    <= out_last_d;
      sof_pending_q <= sof_pending_d;
      eof_pending_q <= eof_pending_d;
      if (in_accept) begin
        if (eol_in) begin
          pair_have_q <= 1'b0;
          pair_p0_q   <= '0;
        end else begin
          pair_have_q <= pair_have_d;
          pair_p0_q   <= pair_p0_d;
        end
      end
    end
  end

  always_comb begin
    s_axis_tready_o = s_ready;
    m_axis_tdata_o  = out_data_q;
    m_axis_tkeep_o  = out_keep_q;
    m_axis_tvalid_o = out_valid_q;
    m_axis_tuser_o  = out_sof_q;
    m_axis_tlast_o  = out_last_q;
  end

`ifdef SIM_ONLY
  logic prev_format_warned_q;
  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      prev_format_warned_q <= 1'b0;
    end else begin
      if (s_axis_tvalid_i && (pck_class == PCK_UNKNOWN) && !prev_format_warned_q) begin
        $warning(
            "pixpipe_pfc_packer: unsupported PFNC pixel_format_i=0x%08h (defaulting to Mono16)",
            pixel_format_i);
        prev_format_warned_q <= 1'b1;
      end
      if (m_axis_tvalid_o) begin
        assert (m_axis_tkeep_o !== '0)
        else $error("pixpipe_pfc_packer: tkeep == 0 with tvalid asserted");
        for (int j = 1; j < OUT_KEEP_W; j++) begin
          if (m_axis_tkeep_o[j] && !m_axis_tkeep_o[j-1]) begin
            assert (1'b0)
            else $error("pixpipe_pfc_packer: tkeep not LSB-contiguous: 0x%0h", m_axis_tkeep_o);
          end
        end
      end
    end
  end
`endif

endmodule : pixpipe_pfc_packer

`default_nettype wire
