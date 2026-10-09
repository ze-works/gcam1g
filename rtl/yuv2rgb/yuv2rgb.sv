// -----------------------------------------------------------------------------
// Module:      yuv2rgb
// Description: YUV 4:2:2 to RGB888 conversion, one or more pixels per clock.
//              The camera streams 4:2:2 because that keeps the MIPI link
//              reliable; this stage converts it right after the receiver.
//              Integer approximation of BT.601 full range. Byte order within a
//              sample pair is selected by registers, not fixed in the RTL.
// -----------------------------------------------------------------------------

`default_nettype none
module yuv2rgb #(
    parameter int unsigned NUM_TAP = 1,
    parameter bit          Y_IN_HIGH = 1'b1
) (
    input  wire                   clk,
    input  wire                   rst_ni,
    input  wire                   y_in_high_i,
    input  wire                   cbcr_swap_i,
    input  wire  [NUM_TAP*16-1:0] s_axis_tdata,
    input  wire                   s_axis_tvalid,
    output logic                  s_axis_tready,
    input  wire                   s_axis_tuser,
    input  wire                   s_axis_tlast,
    output logic [NUM_TAP*24-1:0] m_axis_tdata,
    output logic                  m_axis_tvalid,
    input  wire                   m_axis_tready,
    output logic                  m_axis_tuser,
    output logic                  m_axis_tlast
);
  function automatic logic [23:0] csc(input logic [7:0] Y, input logic [7:0] Cb,
                                      input logic [7:0] Cr);
    int r, g, b;
    int cbv, crv;
    cbv = int'(Cb) - 128;
    crv = int'(Cr) - 128;
    r   = int'(Y) + ((359 * crv) >>> 8);
    g   = int'(Y) - ((88 * cbv) >>> 8) - ((183 * crv) >>> 8);
    b   = int'(Y) + ((454 * cbv) >>> 8);
    if (r < 0) r = 0;
    else if (r > 255) r = 255;
    if (g < 0) g = 0;
    else if (g > 255) g = 255;
    if (b < 0) b = 0;
    else if (b > 255) b = 255;
    return {r[7:0], g[7:0], b[7:0]};
  endfunction

  generate
    if (NUM_TAP == 1) begin : g_tap1
      wire [7:0] y_in = y_in_high_i ? s_axis_tdata[15:8] : s_axis_tdata[7:0];
      wire [7:0] c_in = y_in_high_i ? s_axis_tdata[7:0] : s_axis_tdata[15:8];
      localparam int D = 4, PW = $clog2(D);
      logic [23:0] fdata[0:D-1];
      logic        fuser[0:D-1];
      logic        flast[0:D-1];
      logic [PW:0] wr = 0, rd = 0;
      wire [PW:0] occ = wr - rd;
      wire        full2 = (occ > (PW + 1)'(D - 2));
      wire        empty = (wr == rd);
      assign s_axis_tready = !full2;
      wire  acc = s_axis_tvalid && s_axis_tready;
      logic even_q;
      logic [7:0] y0_q, cb_q;
      logic          sof0_q;
      wire           ev = s_axis_tuser ? 1'b1 : even_q;
      wire  [PW-1:0] wr_i0 = wr[PW-1:0];
      wire  [  PW:0] wr_p1 = wr + 1'b1;
      wire  [PW-1:0] wr_i1 = wr_p1[PW-1:0];
      always_ff @(posedge clk) begin
        if (!rst_ni) begin
          even_q <= 1'b1;
          y0_q   <= '0;
          cb_q   <= '0;
          sof0_q <= 1'b0;
          wr     <= '0;
          rd     <= '0;
        end else begin
          if (acc) begin
            if (ev) begin
              y0_q   <= y_in;
              cb_q   <= c_in;
              sof0_q <= s_axis_tuser;
              even_q <= 1'b0;
            end else begin
              fdata[wr_i0] <= cbcr_swap_i ? csc(y0_q, c_in, cb_q) : csc(y0_q, cb_q, c_in);
              fuser[wr_i0] <= sof0_q;
              flast[wr_i0] <= 1'b0;
              fdata[wr_i1] <= cbcr_swap_i ? csc(y_in, c_in, cb_q) : csc(y_in, cb_q, c_in);
              fuser[wr_i1] <= 1'b0;
              flast[wr_i1] <= s_axis_tlast;
              wr           <= wr + 2'd2;
              even_q       <= 1'b1;
            end
          end
          if (m_axis_tvalid && m_axis_tready) rd <= rd + 1'b1;
        end
      end
      assign m_axis_tvalid = !empty;
      assign m_axis_tdata  = fdata[rd[PW-1:0]];
      assign m_axis_tuser  = fuser[rd[PW-1:0]];
      assign m_axis_tlast  = flast[rd[PW-1:0]];
    end else begin : g_tapN
      initial
        assert ((NUM_TAP % 2) == 0)
        else
          $error(
              "yuv2rgb: NUM_TAP=%0d must be even (4:2:2 samples come in pixel pairs)", NUM_TAP
          );
      logic [NUM_TAP*24-1:0] rgb_c;
      always_comb begin
        for (int p = 0; p < NUM_TAP / 2; p++) begin
          logic [15:0] s0, s1;
          logic [7:0] y0, y1, c0, c1, cb, cr;
          s0 = s_axis_tdata[(2*p)*16+:16];
          s1 = s_axis_tdata[(2*p+1)*16+:16];
          y0 = y_in_high_i ? s0[15:8] : s0[7:0];
          c0 = y_in_high_i ? s0[7:0] : s0[15:8];
          y1 = y_in_high_i ? s1[15:8] : s1[7:0];
          c1 = y_in_high_i ? s1[7:0] : s1[15:8];
          cb = cbcr_swap_i ? c1 : c0;
          cr = cbcr_swap_i ? c0 : c1;
          rgb_c[(2*p)*24+:24] = csc(y0, cb, cr);
          rgb_c[(2*p+1)*24+:24] = csc(y1, cb, cr);
        end
      end
      logic [NUM_TAP*24-1:0] d_q;
      logic v_q, u_q, l_q;
      assign s_axis_tready = m_axis_tready || !v_q;
      always_ff @(posedge clk) begin
        if (!rst_ni) begin
          v_q <= 1'b0;
          d_q <= '0;
          u_q <= 1'b0;
          l_q <= 1'b0;
        end else begin
          if (s_axis_tready) begin
            v_q <= s_axis_tvalid;
            d_q <= rgb_c;
            u_q <= s_axis_tuser;
            l_q <= s_axis_tlast;
          end
        end
      end
      assign m_axis_tvalid = v_q;
      assign m_axis_tdata  = d_q;
      assign m_axis_tuser  = u_q;
      assign m_axis_tlast  = l_q;
    end
  endgenerate
endmodule
`default_nettype wire
