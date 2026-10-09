// -----------------------------------------------------------------------------
// Module:      clk_rx_mon
// Description: Free-running counter on clk_rx, published to the CSR clock. Read
//              the counter twice and divide by the elapsed time to get the real
//              clk_rx frequency; zero means the clock is dead. Gray-coded, so
//              the crossing is safe.
// -----------------------------------------------------------------------------

`default_nettype none
module clk_rx_mon (
    input  wire         clk_rx,
    input  wire         rst_rx_ni,
    input  wire         pclk,
    input  wire         prst_ni,
    output logic [31:0] count_o
);
  function automatic logic [31:0] bin2gray(input logic [31:0] b);
    return b ^ (b >> 1);
  endfunction
  function automatic logic [31:0] gray2bin(input logic [31:0] g);
    logic [31:0] b;
    b = g;
    for (int i = 16; i >= 1; i = i >> 1) b = b ^ (b >> i);
    return b;
  endfunction

  logic [31:0] cnt_q, gray_q;
  always_ff @(posedge clk_rx) begin
    if (!rst_rx_ni) begin
      cnt_q  <= 32'd0;
      gray_q <= 32'd0;
    end else begin
      cnt_q  <= cnt_q + 32'd1;
      gray_q <= bin2gray(cnt_q + 32'd1);
    end
  end

  (* ASYNC_REG = "TRUE" *) logic [31:0] s1_q, s2_q;
  always_ff @(posedge pclk) begin
    if (!prst_ni) begin
      s1_q    <= 32'd0;
      s2_q    <= 32'd0;
      count_o <= 32'd0;
    end else begin
      s1_q    <= gray_q;
      s2_q    <= s1_q;
      count_o <= gray2bin(s2_q);
    end
  end
endmodule
`default_nettype wire
