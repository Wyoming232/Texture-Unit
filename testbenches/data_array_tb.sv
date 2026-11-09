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


    // A missing handshake must fail instead of hanging the simulation.
    initial begin
        #20000;
        $fatal(1, "data_array_tb.sv: simulation timeout");
    end

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
        assert (rd_rsp_valid === '0 && rd_ready === '0 && fill_ready === 1'b0 && protocol_error === 1'b0)
            else $fatal(1, "Reset: data array status");
        @(negedge clk);
        n_rst = 1'b1;

        // Testcase 1: fill bank 0/set 0/way 2, read the second texel + cookie.
        @(negedge clk);
        fill_way = 2'd2;
        fill_line[63:0] = 64'h1111_2222_3333_4444;
        fill_line[127:64] = 64'hAAAA_BBBB_CCCC_DDDD;
        fill_line[LINE_BITS-1 -: 64] = 64'hDEAD_BEEF_7654_3210;
        fill_valid = 1'b1;
        #1;
        assert (fill_ready === 1'b1) else $fatal(1, "TC1: fill acceptance");
        @(negedge clk);
        fill_valid = 1'b0;
        rd_valid[0] = 1'b1;
        rd_way[0] = 2'd2;
        rd_byte_offset[0] = 7'd8;
        rd_cookie[0] = 6'd5;
        #1;
        assert (rd_ready[0] === 1'b1) else $fatal(1, "TC1: read acceptance");
        @(negedge clk);
        rd_valid = '0;
        repeat (L-1) begin // Only latency waiting; no generated stimulus.
            assert (rd_rsp_valid === '0) else $fatal(1, "TC1: response too early");
            @(negedge clk);
        end
        assert (rd_rsp_valid === 4'b0001 && rd_rsp_data[0] === 64'hAAAA_BBBB_CCCC_DDDD &&
                rd_rsp_cookie[0] === 6'd5 && protocol_error === 1'b0)
            else $fatal(1, "TC1: second texel, cookie, or READ_LATENCY");

        // Testcase 2: first and last aligned offsets of the same filled line.
        @(negedge clk);
        rd_valid[0] = 1'b1;
        rd_byte_offset[0] = 7'd0;
        rd_cookie[0] = 6'd0;
        @(negedge clk);
        rd_valid = '0;
        repeat (L-1) @(negedge clk);
        assert (rd_rsp_valid === 4'b0001 && rd_rsp_data[0] === 64'h1111_2222_3333_4444 && rd_rsp_cookie[0] === 6'd0)
            else $fatal(1, "TC2: first texel");
        @(negedge clk);
        rd_valid[0] = 1'b1;
        rd_byte_offset[0] = 7'd120;
        rd_cookie[0] = 6'd63;
        @(negedge clk);
        rd_valid = '0;
        repeat (L-1) @(negedge clk);
        assert (rd_rsp_valid === 4'b0001 && rd_rsp_data[0] === 64'hDEAD_BEEF_7654_3210 && rd_rsp_cookie[0] === 6'd63)
            else $fatal(1, "TC2: last texel/maximum cookie");

        // Testcase 3: fill stalls only its own bank; another bank still reads.
        @(negedge clk);
        fill_bank = 2'd1;
        fill_set = 3'd3;
        fill_way = 2'd1;
        fill_line = '0;
        fill_line[63:0] = 64'h5555_6666_7777_8888;
        fill_valid = 1'b1;
        @(negedge clk);
        fill_bank = 2'd0;
        fill_set = 3'd0;
        fill_way = 2'd2;
        fill_line[63:0] = 64'h9999_AAAA_BBBB_CCCC;
        rd_valid = 4'b0011;
        rd_byte_offset[0] = 7'd0;
        rd_cookie[0] = 6'd10;
        rd_set[1] = 3'd3;
        rd_way[1] = 2'd1;
        rd_byte_offset[1] = 7'd0;
        rd_cookie[1] = 6'd11;
        #1;
        assert (fill_ready === 1'b1 && rd_ready[0] === 1'b0 && rd_ready[1] === 1'b1)
            else $fatal(1, "TC3: fill priority is bank-local");
        @(negedge clk);
        fill_valid = 1'b0;
        rd_valid = '0;
        repeat (L-1) @(negedge clk);
        assert (rd_rsp_valid === 4'b0010 && rd_rsp_data[1] === 64'h5555_6666_7777_8888 && rd_rsp_cookie[1] === 6'd11)
            else $fatal(1, "TC3: other bank read or spurious stalled-bank response");
        @(negedge clk);
        rd_valid[0] = 1'b1; // Retry the blocked read after fill completion.
        #1;
        assert (rd_ready[0] === 1'b1) else $fatal(1, "TC3: retry ready");
        @(negedge clk);
        rd_valid = '0;
        repeat (L-1) @(negedge clk);
        assert (rd_rsp_valid === 4'b0001 && rd_rsp_data[0] === 64'h9999_AAAA_BBBB_CCCC && rd_rsp_cookie[0] === 6'd10)
            else $fatal(1, "TC3: retry sees newly filled data");

        // Testcase 4: reset flushes a read response (or pending pipeline work).
        @(negedge clk);
        rd_valid[0] = 1'b1;
        @(negedge clk);
        rd_valid = '0;
        n_rst = 1'b0;
        #1;
        assert (rd_rsp_valid === '0 && protocol_error === 1'b0)
            else $fatal(1, "TC4: asynchronous reset flush");
        @(negedge clk);
        n_rst = 1'b1;
        repeat (L+1) begin
            @(negedge clk);
            assert (rd_rsp_valid === '0) else $fatal(1, "TC4: stale response after reset");
        end

        $display("PASS: data_array_tb (READ_LATENCY=%0d)", L);
        $finish;
    end
endmodule
