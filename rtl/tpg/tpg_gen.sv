// -----------------------------------------------------------------------------
// Module:      tpg_gen
// Description: Test pattern generator. Produces the standard feature naming
//              convention test patterns plus a few extra ones, at the geometry
//              and pixel format given by the control registers.
// -----------------------------------------------------------------------------

`timescale 1ns / 1ps
`default_nettype none

module tpg_gen #(
    parameter int unsigned MAX_WIDTH = 4096,
    parameter int unsigned MAX_HEIGHT = 4096,
    parameter int unsigned MAX_BPP = 16,
    parameter int unsigned NUM_TAP = 1,
    parameter int unsigned NUM_PATTERNS = 15,
    parameter logic [14:0] ENABLED_PATTERNS = 15'h7FFF
) (
    input wire logic clk,
    input wire logic rst_ni,
    input wire logic start_i,
    input wire logic [$clog2(MAX_WIDTH+1)-1:0] width_i,
    input wire logic [$clog2(MAX_HEIGHT+1)-1:0] height_i,
    input wire logic [31:0] pixel_format_i,
    input wire logic [3:0] pattern_select_i,
    output logic [NUM_TAP*32-1:0] m_axis_tdata_o,
    output logic m_axis_tvalid_o,
    input wire logic m_axis_tready_i,
    output logic m_axis_tuser_o,
    output logic m_axis_tlast_o,
    output logic [63:0] frame_id_o,
    output logic busy_o
);

  localparam int unsigned        UnusedMaxBpp               = MAX_BPP;

  localparam int unsigned        XW                         = $clog2(MAX_WIDTH + 1);
  localparam int unsigned        YW                         = $clog2(MAX_HEIGHT + 1);

  localparam logic        [31:0] PFNC_MONO8                 = 32'h0108_0001;
  localparam logic        [31:0] PFNC_MONO10                = 32'h0110_0003;
  localparam logic        [31:0] PFNC_MONO12                = 32'h0110_0005;
  localparam logic        [31:0] PFNC_MONO16                = 32'h0110_0007;
  localparam logic        [31:0] PFNC_BAYERRG8              = 32'h0108_0009;
  localparam logic        [31:0] PFNC_BAYERGR8              = 32'h0108_0008;
  localparam logic        [31:0] PFNC_BAYERGB8              = 32'h0108_000A;
  localparam logic        [31:0] PFNC_BAYERBG8              = 32'h0108_000B;
  localparam logic        [31:0] PFNC_RGB8                  = 32'h0218_0014;

  localparam logic        [ 3:0] PAT_OFF                    = 4'd0;
  localparam logic        [ 3:0] PAT_BLACK                  = 4'd1;
  localparam logic        [ 3:0] PAT_WHITE                  = 4'd2;
  localparam logic        [ 3:0] PAT_GREY_H_RAMP            = 4'd3;
  localparam logic        [ 3:0] PAT_GREY_V_RAMP            = 4'd4;
  localparam logic        [ 3:0] PAT_GREY_H_RAMP_MOVING     = 4'd5;
  localparam logic        [ 3:0] PAT_GREY_V_RAMP_MOVING     = 4'd6;
  localparam logic        [ 3:0] PAT_HORIZONTAL_LINE_MOVING = 4'd7;
  localparam logic        [ 3:0] PAT_VERTICAL_LINE_MOVING   = 4'd8;
  localparam logic        [ 3:0] PAT_COLOR_BAR              = 4'd9;
  localparam logic        [ 3:0] PAT_FRAME_COUNTER          = 4'd10;
  localparam logic        [ 3:0] PAT_SENSOR_BAYER_SIM       = 4'd11;
  localparam logic        [ 3:0] PAT_RANDOM                 = 4'd12;
  localparam logic        [ 3:0] PAT_CROSS_HATCH            = 4'd13;
  localparam logic        [ 3:0] PAT_DIAG_RAMP            = 4'd14;

  typedef enum logic [1:0] {
    BAYER_CH_R = 2'd0,
    BAYER_CH_G = 2'd1,
    BAYER_CH_B = 2'd2
  } bayer_ch_e;

  typedef enum logic [0:0] {
    IDLE      = 1'b0,
    GEN_PIXEL = 1'b1
  } tpg_state_e;

  tpg_state_e state_q, state_d;

  logic [XW-1:0] x_q;
  logic [XW-1:0] x_d;
  logic [YW-1:0] y_q;
  logic [YW-1:0] y_d;
  logic [  63:0] frame_id_q;
  logic [  63:0] frame_id_d;

  logic [XW-1:0] width_q;
  logic [XW-1:0] width_d;
  logic [YW-1:0] height_q;
  logic [YW-1:0] height_d;
  logic [  31:0] pixel_format_q;
  logic [  31:0] pixel_format_d;
  logic [   3:0] pattern_q;
  logic [   3:0] pattern_d;

  logic          pixel_valid;
  logic          pixel_accept;
  logic          last_col;
  logic          last_row;
  logic          frame_last;
  logic          sof_q;
  logic          sof_d;

  always_comb begin
    width_d        = width_q;
    height_d       = height_q;
    pixel_format_d = pixel_format_q;
    pattern_d      = pattern_q;
    if ((state_q == IDLE) && start_i) begin
      width_d        = width_i;
      height_d       = height_i;
      pixel_format_d = pixel_format_i;
      pattern_d      = pattern_select_i;
    end
  end

  logic pattern_enabled;
  always_comb begin
    pattern_enabled = 1'b0;
    if (pattern_q < NUM_PATTERNS[3:0]) begin
      pattern_enabled = ENABLED_PATTERNS[pattern_q];
    end
  end

  logic [15:0] frame_phase;
  always_comb frame_phase = frame_id_q[15:0];

  logic [YW-1:0] hline_y_pos;
  logic [XW-1:0] vline_x_pos;
  logic [  15:0] phase_mod_h_q;
  logic [  15:0] phase_mod_h_d;
  logic [  15:0] phase_mod_w_q;
  logic [  15:0] phase_mod_w_d;
  always_comb begin
    hline_y_pos = (height_q == '0) ? '0 : (YW'(height_q - 1'b1) - YW'(phase_mod_h_q));
    vline_x_pos = (width_q == '0) ? '0 : (XW'(width_q - 1'b1) - XW'(phase_mod_w_q));
  end

  logic frame_advance;
  assign frame_advance = pixel_accept & frame_last;

  always_comb begin
    phase_mod_h_d = phase_mod_h_q;
    phase_mod_w_d = phase_mod_w_q;
    if (frame_advance) begin
      phase_mod_h_d = phase_mod_h_q + 16'd1;
      phase_mod_w_d = phase_mod_w_q + 16'd1;
    end
    if (phase_mod_h_d >= {{(16 - YW) {1'b0}}, height_q}) phase_mod_h_d = '0;
    if (phase_mod_w_d >= {{(16 - XW) {1'b0}}, width_q}) phase_mod_w_d = '0;
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      phase_mod_h_q <= '0;
      phase_mod_w_q <= '0;
    end else begin
      phase_mod_h_q <= phase_mod_h_d;
      phase_mod_w_q <= phase_mod_w_d;
    end
  end

  logic [31:0] lfsr_q;
  logic [31:0] lfsr_d;

  function automatic logic [31:0] step_lfsr(input logic [31:0] v);
    return (v >> 1) ^ (32'hEDB88320 & {32{v[0]}});
  endfunction

  logic [31:0] lfsr_chain[NUM_TAP+1];
  always_comb begin
    lfsr_chain[0] = lfsr_q;
    for (int unsigned i = 0; i < NUM_TAP; i++) begin
      lfsr_chain[i+1] = step_lfsr(lfsr_chain[i]);
    end
  end

  always_comb begin
    lfsr_d = lfsr_q;
    if ((state_q == IDLE) && start_i) begin
      lfsr_d = frame_id_q[31:0] | 32'h1;
    end else if (pixel_accept) begin
      lfsr_d = lfsr_chain[NUM_TAP];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      lfsr_q <= 32'hFFFF_FFFF;
    end else begin
      lfsr_q <= lfsr_d;
    end
  end

  function automatic logic [31:0] gen_pixel(input logic [XW-1:0] xarg, input logic [31:0] lfsr_val);
    logic [15:0] raw16;
    logic [7:0] rgb_r, rgb_g, rgb_b;
    logic [   2:0] bar_idx;
    logic [XW+2:0] x_times_8;
    logic [7:0] cb_r, cb_g, cb_b, cb_luma, cb_bayer;
    logic      [11:0] luma_sum;
    bayer_ch_e        bayer_ch;
    logic bx, by;
    logic [7:0] bayer8_byte;
    logic       is_bayer8_format;
    logic [15:0] ramp_h_static, ramp_v_static, ramp_h_moving, ramp_v_moving;
    logic on_hline, on_vline;
    logic ch_vline, ch_hline;
    logic [7:0] diag_r, diag_g, diag_b, diag_mono;
    logic [31:0] tdata;

    x_times_8 = {3'b0, xarg} << 3;
    if (x_times_8 >= ({3'b0, width_q} * 16'd7)) bar_idx = 3'd7;
    else if (x_times_8 >= ({3'b0, width_q} * 16'd6)) bar_idx = 3'd6;
    else if (x_times_8 >= ({3'b0, width_q} * 16'd5)) bar_idx = 3'd5;
    else if (x_times_8 >= ({3'b0, width_q} * 16'd4)) bar_idx = 3'd4;
    else if (x_times_8 >= ({3'b0, width_q} * 16'd3)) bar_idx = 3'd3;
    else if (x_times_8 >= ({3'b0, width_q} * 16'd2)) bar_idx = 3'd2;
    else if (x_times_8 >= ({3'b0, width_q} * 16'd1)) bar_idx = 3'd1;
    else bar_idx = 3'd0;

    unique case (bar_idx)
      3'd0: begin
        cb_r = 8'hFF;
        cb_g = 8'hFF;
        cb_b = 8'hFF;
      end
      3'd1: begin
        cb_r = 8'hFF;
        cb_g = 8'hFF;
        cb_b = 8'h00;
      end
      3'd2: begin
        cb_r = 8'h00;
        cb_g = 8'hFF;
        cb_b = 8'hFF;
      end
      3'd3: begin
        cb_r = 8'h00;
        cb_g = 8'hFF;
        cb_b = 8'h00;
      end
      3'd4: begin
        cb_r = 8'hFF;
        cb_g = 8'h00;
        cb_b = 8'hFF;
      end
      3'd5: begin
        cb_r = 8'hFF;
        cb_g = 8'h00;
        cb_b = 8'h00;
      end
      3'd6: begin
        cb_r = 8'h00;
        cb_g = 8'h00;
        cb_b = 8'hFF;
      end
      3'd7: begin
        cb_r = 8'h00;
        cb_g = 8'h00;
        cb_b = 8'h00;
      end
      default: begin
        cb_r = 8'h00;
        cb_g = 8'h00;
        cb_b = 8'h00;
      end
    endcase

    luma_sum = ({4'd0, cb_r} * 12'd5) + ({4'd0, cb_g} * 12'd9) + ({4'd0, cb_b} * 12'd2);
    cb_luma  = luma_sum[11:4];

    bx       = xarg[0];
    by       = y_q[0];
    bayer_ch = BAYER_CH_G;
    unique case (pixel_format_q)
      PFNC_BAYERRG8: begin
        unique case ({
          by, bx
        })
          2'b00:   bayer_ch = BAYER_CH_R;
          2'b01:   bayer_ch = BAYER_CH_G;
          2'b10:   bayer_ch = BAYER_CH_G;
          2'b11:   bayer_ch = BAYER_CH_B;
          default: bayer_ch = BAYER_CH_G;
        endcase
      end
      PFNC_BAYERGR8: begin
        unique case ({
          by, bx
        })
          2'b00:   bayer_ch = BAYER_CH_G;
          2'b01:   bayer_ch = BAYER_CH_R;
          2'b10:   bayer_ch = BAYER_CH_B;
          2'b11:   bayer_ch = BAYER_CH_G;
          default: bayer_ch = BAYER_CH_G;
        endcase
      end
      PFNC_BAYERGB8: begin
        unique case ({
          by, bx
        })
          2'b00:   bayer_ch = BAYER_CH_G;
          2'b01:   bayer_ch = BAYER_CH_B;
          2'b10:   bayer_ch = BAYER_CH_R;
          2'b11:   bayer_ch = BAYER_CH_G;
          default: bayer_ch = BAYER_CH_G;
        endcase
      end
      PFNC_BAYERBG8: begin
        unique case ({
          by, bx
        })
          2'b00:   bayer_ch = BAYER_CH_B;
          2'b01:   bayer_ch = BAYER_CH_G;
          2'b10:   bayer_ch = BAYER_CH_G;
          2'b11:   bayer_ch = BAYER_CH_R;
          default: bayer_ch = BAYER_CH_G;
        endcase
      end
      default: bayer_ch = BAYER_CH_G;
    endcase

    unique case (bayer_ch)
      BAYER_CH_R: cb_bayer = cb_r;
      BAYER_CH_G: cb_bayer = cb_g;
      BAYER_CH_B: cb_bayer = cb_b;
      default:    cb_bayer = cb_g;
    endcase

    ramp_h_static = {xarg[7:0], 8'h00};
    ramp_v_static = {y_q[7:0], 8'h00};
    ramp_h_moving = ramp_h_static + {frame_phase[7:0], 8'h00};
    ramp_v_moving = ramp_v_static + {frame_phase[7:0], 8'h00};

    on_hline      = (y_q == hline_y_pos);
    on_vline      = (xarg == vline_x_pos);

    ch_vline      = (xarg[4:0] == 5'b0);
    ch_hline      = (y_q[4:0] == 5'b0);

    diag_r        = 32'(xarg) + 32'(frame_phase);
    diag_g        = 32'(y_q) + 32'(frame_phase);
    diag_b        = 32'(xarg) + 32'(y_q) + (32'(frame_phase) << 1);
    diag_mono     = 32'(xarg) + 32'(y_q) + 32'(frame_phase);

    raw16         = 16'h0000;
    rgb_r         = 8'h00;
    rgb_g         = 8'h00;
    rgb_b         = 8'h00;
    if (pattern_enabled) begin
      unique case (pattern_q)
        PAT_OFF: begin
          raw16 = 16'h0000;
          rgb_r = 8'h00;
          rgb_g = 8'h00;
          rgb_b = 8'h00;
        end
        PAT_BLACK: begin
          raw16 = 16'h0000;
          rgb_r = 8'h00;
          rgb_g = 8'h00;
          rgb_b = 8'h00;
        end
        PAT_WHITE: begin
          raw16 = 16'hFFFF;
          rgb_r = 8'hFF;
          rgb_g = 8'hFF;
          rgb_b = 8'hFF;
        end
        PAT_GREY_H_RAMP: begin
          raw16 = ramp_h_static;
          rgb_r = ramp_h_static[15:8];
          rgb_g = ramp_h_static[15:8];
          rgb_b = ramp_h_static[15:8];
        end
        PAT_GREY_V_RAMP: begin
          raw16 = ramp_v_static;
          rgb_r = ramp_v_static[15:8];
          rgb_g = ramp_v_static[15:8];
          rgb_b = ramp_v_static[15:8];
        end
        PAT_GREY_H_RAMP_MOVING: begin
          raw16 = ramp_h_moving;
          rgb_r = ramp_h_moving[15:8];
          rgb_g = ramp_h_moving[15:8];
          rgb_b = ramp_h_moving[15:8];
        end
        PAT_GREY_V_RAMP_MOVING: begin
          raw16 = ramp_v_moving;
          rgb_r = ramp_v_moving[15:8];
          rgb_g = ramp_v_moving[15:8];
          rgb_b = ramp_v_moving[15:8];
        end
        PAT_HORIZONTAL_LINE_MOVING: begin
          raw16 = on_hline ? 16'hFFFF : 16'h0000;
          rgb_r = on_hline ? 8'hFF : 8'h00;
          rgb_g = on_hline ? 8'hFF : 8'h00;
          rgb_b = on_hline ? 8'hFF : 8'h00;
        end
        PAT_VERTICAL_LINE_MOVING: begin
          raw16 = on_vline ? 16'hFFFF : 16'h0000;
          rgb_r = on_vline ? 8'hFF : 8'h00;
          rgb_g = on_vline ? 8'hFF : 8'h00;
          rgb_b = on_vline ? 8'hFF : 8'h00;
        end
        PAT_COLOR_BAR: begin
          raw16 = {cb_luma, 8'h00};
          rgb_r = cb_r;
          rgb_g = cb_g;
          rgb_b = cb_b;
        end
        PAT_FRAME_COUNTER: begin
          raw16 = frame_id_q[15:0];
          rgb_r = frame_id_q[7:0];
          rgb_g = frame_id_q[7:0];
          rgb_b = frame_id_q[7:0];
        end
        PAT_SENSOR_BAYER_SIM: begin
          raw16 = 16'h0000;
          rgb_r = 8'h00;
          rgb_g = 8'h00;
          rgb_b = 8'h00;
        end
        PAT_RANDOM: begin
          raw16 = {lfsr_val[7:0], 8'h00};
          rgb_r = lfsr_val[7:0];
          rgb_g = lfsr_val[15:8];
          rgb_b = lfsr_val[23:16];
        end
        PAT_CROSS_HATCH: begin
          raw16 = (ch_vline || ch_hline) ? 16'hFFFF : 16'h0000;
          rgb_r = ch_vline ? 8'hFF : 8'h00;
          rgb_g = (ch_vline && ch_hline) ? 8'hFF : 8'h00;
          rgb_b = ch_hline ? 8'hFF : 8'h00;
        end
        PAT_DIAG_RAMP: begin
          raw16 = {diag_mono, 8'h00};
          rgb_r = diag_r;
          rgb_g = diag_g;
          rgb_b = diag_b;
        end
        default: begin
          raw16 = 16'h0000;
          rgb_r = 8'h00;
          rgb_g = 8'h00;
          rgb_b = 8'h00;
        end
      endcase
    end

    is_bayer8_format = (pixel_format_q == PFNC_BAYERRG8) ||
                       (pixel_format_q == PFNC_BAYERGR8) ||
                       (pixel_format_q == PFNC_BAYERGB8) ||
                       (pixel_format_q == PFNC_BAYERBG8);
    if (is_bayer8_format && (pattern_q == PAT_COLOR_BAR) && pattern_enabled) begin
      bayer8_byte = cb_bayer;
    end else begin
      bayer8_byte = raw16[15:8];
    end

    tdata = 32'h0000_0000;
    unique case (pixel_format_q)
      PFNC_MONO8: begin
        tdata = {raw16[15:8], 24'h00_0000};
      end
      PFNC_BAYERRG8, PFNC_BAYERGR8, PFNC_BAYERGB8, PFNC_BAYERBG8: begin
        tdata = {bayer8_byte, 24'h00_0000};
      end
      PFNC_MONO10: begin
        tdata = {raw16[15:6], 22'h00_0000};
      end
      PFNC_MONO12: begin
        tdata = {raw16[15:4], 20'h0_0000};
      end
      PFNC_MONO16: begin
        tdata = {raw16, 16'h0000};
      end
      PFNC_RGB8: begin
        tdata = {rgb_r, rgb_g, rgb_b, 8'h00};
      end
      default: begin
        tdata = {raw16, 16'h0000};
      end
    endcase
    return tdata;
  endfunction

  logic [NUM_TAP*32-1:0] tdata_mux;
  always_comb begin
    tdata_mux = '0;
    for (int unsigned t = 0; t < NUM_TAP; t++) begin
      tdata_mux[t*32+:32] = gen_pixel(x_q + XW'(t), lfsr_chain[t]);
    end
  end

  logic [XW:0] x_plus_tap;
  assign x_plus_tap = {1'b0, x_q} + (XW + 1)'(NUM_TAP);

  always_comb begin
    state_d     = state_q;
    x_d         = x_q;
    y_d         = y_q;
    frame_id_d  = frame_id_q;
    sof_d       = sof_q;
    pixel_valid = 1'b0;
    last_col    = (width_q != '0) && (x_plus_tap >= {1'b0, width_q});
    last_row    = (height_q != '0) && (y_q == (height_q - 1'b1));
    frame_last  = last_col & last_row;

    unique case (state_q)
      IDLE: begin
        x_d   = '0;
        y_d   = '0;
        sof_d = 1'b1;
        if (start_i && (pattern_select_i != PAT_OFF) && (width_i != '0) && (height_i != '0)) begin
          state_d = GEN_PIXEL;
        end
      end

      GEN_PIXEL: begin
        pixel_valid = 1'b1;
        if (pixel_accept) begin
          sof_d = 1'b0;
          if (frame_last) begin
            x_d        = '0;
            y_d        = '0;
            frame_id_d = frame_id_q + 64'd1;
            state_d    = IDLE;
          end else if (last_col) begin
            x_d = '0;
            y_d = y_q + 1'b1;
          end else begin
            x_d = x_q + XW'(NUM_TAP);
          end
        end
      end

      default: begin
        state_d = IDLE;
      end
    endcase
  end

  assign pixel_accept = pixel_valid & m_axis_tready_i;

  always_ff @(posedge clk) begin
    if (!rst_ni) begin
      state_q        <= IDLE;
      x_q            <= '0;
      y_q            <= '0;
      frame_id_q     <= 64'd0;
      sof_q          <= 1'b1;
      width_q        <= '0;
      height_q       <= '0;
      pixel_format_q <= 32'h0000_0000;
      pattern_q      <= 4'd0;
    end else begin
      state_q        <= state_d;
      x_q            <= x_d;
      y_q            <= y_d;
      frame_id_q     <= frame_id_d;
      sof_q          <= sof_d;
      width_q        <= width_d;
      height_q       <= height_d;
      pixel_format_q <= pixel_format_d;
      pattern_q      <= pattern_d;
    end
  end

  always_comb begin
    m_axis_tdata_o  = tdata_mux;
    m_axis_tvalid_o = pixel_valid;
    m_axis_tuser_o  = pixel_valid & sof_q;
    m_axis_tlast_o  = pixel_valid & last_col;
  end

  assign frame_id_o = frame_id_q;
  assign busy_o     = (state_q != IDLE);

`ifdef SIM_ONLY
  always_ff @(posedge clk) begin
    if (rst_ni) begin
      if (state_q == GEN_PIXEL) begin
        assert (x_q < width_q)
        else $error("tpg_gen: x_q (%0d) out of range (width=%0d)", x_q, width_q);
        assert (y_q < height_q)
        else $error("tpg_gen: y_q (%0d) out of range (height=%0d)", y_q, height_q);
      end
      if ((state_q == IDLE) && start_i) begin
        assert (pattern_select_i < NUM_PATTERNS[3:0])
        else
          $error(
              "tpg_gen: pattern_select_i=%0d >= NUM_PATTERNS=%0d", pattern_select_i, NUM_PATTERNS
          );
        assert ((pixel_format_i == PFNC_MONO8)    ||
                (pixel_format_i == PFNC_MONO10)   ||
                (pixel_format_i == PFNC_MONO12)   ||
                (pixel_format_i == PFNC_MONO16)   ||
                (pixel_format_i == PFNC_BAYERRG8) ||
                (pixel_format_i == PFNC_BAYERGR8) ||
                (pixel_format_i == PFNC_BAYERGB8) ||
                (pixel_format_i == PFNC_BAYERBG8) ||
                (pixel_format_i == PFNC_RGB8))
        else
          $warning(
              "tpg_gen: unsupported pixel_format_i=0x%08h, falling back to Mono16",
              pixel_format_i
          );
      end
    end
  end
`endif

endmodule : tpg_gen

`default_nettype wire
