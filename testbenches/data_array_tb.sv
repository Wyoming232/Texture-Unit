`timescale 1ns/1ps

module data_array_tb;
    import cache_pkg::*;
    parameter integer L = 1;
    localparam integer C = 6;

    logic clk, n_rst;
    logic [BANKS-1:0] rd_valid, rd_ready, rd_rsp_valid;
    logic [BANKS-1:0][SET_W-1:0] rd_set;
    logic [BANKS-1:0][WAY_W-1:0] rd_way;
    logic [BANKS-1:0][OFFSET_W-1:0] rd_byte_offset;
    logic [BANKS-1:0][C-1:0] rd_cookie, rd_rsp_cookie;
    logic [BANKS-1:0][TEXEL_BITS-1:0] rd_rsp_data;
    logic fill_valid, fill_ready;
    logic [BANK_W-1:0] fill_bank;
    logic [SET_W-1:0] fill_set;
    logic [WAY_W-1:0] fill_way;
    logic [LINE_BITS-1:0] fill_line;
    logic protocol_error;

    always #5 clk = ~clk;

    data_array #(.READ_LATENCY(L), .COOKIE_W(C)) dut (
        .clk(clk), .n_rst(n_rst), .rd_valid(rd_valid), .rd_ready(rd_ready),
        .rd_set(rd_set), .rd_way(rd_way), .rd_byte_offset(rd_byte_offset),
        .rd_cookie(rd_cookie), .rd_rsp_valid(rd_rsp_valid),
        .rd_rsp_data(rd_rsp_data), .rd_rsp_cookie(rd_rsp_cookie),
        .fill_valid(fill_valid), .fill_ready(fill_ready), .fill_bank(fill_bank),
        .fill_set(fill_set), .fill_way(fill_way), .fill_line(fill_line),
        .protocol_error(protocol_error)
    );

    initial begin
        clk = 1'b0;
        n_rst = 1'b0;
        rd_valid = '0;
        rd_set = '0;
        rd_way = '0;
        rd_byte_offset = '0;
        rd_cookie = '0;
        fill_valid = 1'b0;
        fill_bank = '0;
        fill_set = '0;
        fill_way = '0;
        fill_line = '0;
        @(negedge clk);
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase: fill bank 0/set 0/way 2, then read its second texel.
        @(negedge clk);
        fill_way = 2'd2;
        fill_line[63:0] = 64'h1111_2222_3333_4444;
        fill_line[127:64] = 64'hAAAA_BBBB_CCCC_DDDD;
        fill_valid = 1'b1;
        @(negedge clk);
        fill_valid = 1'b0;
        rd_valid[0] = 1'b1;
        rd_way[0] = 2'd2;
        rd_byte_offset[0] = 7'd8;
        rd_cookie[0] = 6'd5;
        @(negedge clk);
        rd_valid = '0;
        // For L=1: rd_rsp_valid[0]=1 now, data=0xAAAABBBBCCCCDDDD,
        // cookie=5. Other response-valid bits=0; protocol_error=0.
        // For larger L, inspect that response L-1 cycles later.
        #(L * 10);

        // Add the next manual testcase here.
        $finish;
    end
endmodule