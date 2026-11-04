`timescale 1ns/1ps
// One read OR full-line fill per bank/cycle. Compile cache_pkg.sv first.
module data_array
    import cache_pkg::*;
#(
    parameter integer READ_LATENCY=1,
    parameter integer COOKIE_W=(LANES>1)?$clog2(LANES):1
) (
    input logic clk, n_rst,
    input logic [BANKS-1:0] rd_valid,
    output logic [BANKS-1:0] rd_ready,
    input logic [BANKS-1:0][SET_W-1:0] rd_set,
    input logic [BANKS-1:0][WAY_W-1:0] rd_way,
    input logic [BANKS-1:0][OFFSET_W-1:0] rd_byte_offset,
    input logic [BANKS-1:0][COOKIE_W-1:0] rd_cookie,
    output logic [BANKS-1:0] rd_rsp_valid,
    output logic [BANKS-1:0][TEXEL_BITS-1:0] rd_rsp_data,
    output logic [BANKS-1:0][COOKIE_W-1:0] rd_rsp_cookie,
    input logic fill_valid,
    output logic fill_ready,
    input logic [BANK_W-1:0] fill_bank,
    input logic [SET_W-1:0] fill_set,
    input logic [WAY_W-1:0] fill_way,
    input logic [LINE_BITS-1:0] fill_line,
    output logic protocol_error
);
    logic fill_coordinate_ok, fill_fire;
    logic [BANKS-1:0] read_coordinate_ok;
    assign fill_coordinate_ok=(int'(fill_bank)<BANKS) &&
                              (int'(fill_set)<SETS_PER_BANK) &&
                              (int'(fill_way)<WAYS);
    assign fill_ready=n_rst && fill_coordinate_ok;
    assign fill_fire=fill_valid && fill_ready;
    for (genvar b=0; b<BANKS; b=b+1) begin : bank
        logic [LINE_BITS-1:0] storage [0:SETS_PER_BANK*WAYS-1];
        logic [READ_LATENCY-1:0] valid_q;
        logic [TEXEL_BITS-1:0] data_q [0:READ_LATENCY-1];
        logic [COOKIE_W-1:0] cookie_q [0:READ_LATENCY-1];
        logic read_fire, bank_fill;
        assign read_coordinate_ok[b]=(int'(rd_set[b])<SETS_PER_BANK) &&
            (int'(rd_way[b])<WAYS) &&
            (int'(rd_byte_offset[b])<=LINE_BYTES-TEXEL_BYTES) &&
            ((int'(rd_byte_offset[b]) % TEXEL_BYTES)==0);
        assign bank_fill=fill_fire && fill_bank==BANK_W'(b);
        // Refill priority only blocks the target bank; other banks keep reading.
        assign rd_ready[b]=n_rst && read_coordinate_ok[b] && !bank_fill;
        assign read_fire=rd_valid[b] && rd_ready[b];
        assign rd_rsp_valid[b]=n_rst && valid_q[READ_LATENCY-1];
        assign rd_rsp_data[b]=data_q[READ_LATENCY-1];
        assign rd_rsp_cookie[b]=cookie_q[READ_LATENCY-1];
        // Byte j occupies line[8*j +: 8]. Responses have no backpressure port.
        always_ff @(posedge clk or negedge n_rst) begin
            if (!n_rst) begin
                valid_q<='0;
                for (integer p=0; p<READ_LATENCY; p=p+1) begin
                    data_q[p]<='0; cookie_q[p]<='0;
                end
            end else begin
                valid_q[0]<=read_fire;
                if (read_fire) begin
                    data_q[0]<=storage[int'(rd_set[b])*WAYS+int'(rd_way[b])]
                        [int'(rd_byte_offset[b])*8 +: TEXEL_BITS];
                    cookie_q[0]<=rd_cookie[b];
                end
                for (integer p=1; p<READ_LATENCY; p=p+1) begin
                    valid_q[p]<=valid_q[p-1];
                    data_q[p]<=data_q[p-1]; cookie_q[p]<=cookie_q[p-1];
                end
            end
        end
        // RAM contents do not reset. Cache tags determine which lines are valid.
        always_ff @(posedge clk) begin
            if (bank_fill)
                storage[int'(fill_set)*WAYS+int'(fill_way)]<=fill_line;
        end
    end
    // Reject malformed requests and retain a diagnostic until reset.
    always_ff @(posedge clk or negedge n_rst) begin
        if (!n_rst) protocol_error<=1'b0;
        else if ((fill_valid && !fill_coordinate_ok) ||
                 (|(rd_valid & ~read_coordinate_ok))) protocol_error<=1'b1;
    end
`ifndef SYNTHESIS
    initial begin
        if (READ_LATENCY<1 || COOKIE_W<1 || BANKS<1 || WAYS<1 ||
            SETS_PER_BANK<1 || TEXEL_BYTES<1 || LINE_BYTES<TEXEL_BYTES ||
            (LINE_BYTES % TEXEL_BYTES)!=0 ||
            (CACHE_BYTES % (BANKS*WAYS*LINE_BYTES))!=0)
            $fatal(1,"Invalid data_array/cache geometry parameters");
    end
`endif
endmodule


