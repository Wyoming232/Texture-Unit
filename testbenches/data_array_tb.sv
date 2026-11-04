
`timescale 1ns/1ps
module data_array_tb;
    import cache_pkg::*;
    parameter integer L=1;
    localparam integer C=6;
    logic clk=0; always #5 clk=~clk;
    logic n_rst=0;
    logic [BANKS-1:0] rd_valid=0, rd_ready, rd_rsp_valid;
    logic [BANKS-1:0][SET_W-1:0] rd_set=0;
    logic [BANKS-1:0][WAY_W-1:0] rd_way=0;
    logic [BANKS-1:0][OFFSET_W-1:0] rd_byte_offset=0;
    logic [BANKS-1:0][C-1:0] rd_cookie=0, rd_rsp_cookie;
    logic [BANKS-1:0][TEXEL_BITS-1:0] rd_rsp_data;
    logic fill_valid=0, fill_ready;
    logic [BANK_W-1:0] fill_bank=0;
    logic [SET_W-1:0] fill_set=0;
    logic [WAY_W-1:0] fill_way=0;
    logic [LINE_BITS-1:0] fill_line=0;
    logic protocol_error;
    data_array #(.READ_LATENCY(L),.COOKIE_W(C)) dut(.*);
    logic [LINE_BITS-1:0] model [0:BANKS-1][0:SETS_PER_BANK-1][0:WAYS-1];
    bit expected_valid [0:BANKS-1][0:L-1];
    logic [TEXEL_BITS-1:0] expected_data [0:BANKS-1][0:L-1];
    logic [C-1:0] expected_cookie [0:BANKS-1][0:L-1];
    bit expected_error=0, coord_ok, expected_ready, expected_fill_ready;
    integer reads=0, fills=0, cycles=0, rng=32'h14f861ad;

    function automatic integer random_below(input integer n);
        rng=rng^(rng<<13); rng=rng^(rng>>17); rng=rng^(rng<<5);
        random_below=int'($unsigned(rng)%n);
    endfunction
    function automatic [LINE_BITS-1:0] make_line(input integer salt);
        for(integer j=0;j<LINE_BYTES;j=j+1)
            make_line[j*8 +: 8]=8'(salt*17+j*23);
    endfunction
    task automatic tick;
        begin
            #1;
            expected_fill_ready=int'(fill_bank)<BANKS &&
                int'(fill_set)<SETS_PER_BANK && int'(fill_way)<WAYS;
            if(fill_ready !== expected_fill_ready) $fatal(1,"Fill ready mismatch");
            if(fill_valid && !expected_fill_ready) expected_error=1;
            for(integer b=0;b<BANKS;b=b+1) begin
                coord_ok=int'(rd_set[b])<SETS_PER_BANK && int'(rd_way[b])<WAYS &&
                    int'(rd_byte_offset[b])<=LINE_BYTES-TEXEL_BYTES &&
                    int'(rd_byte_offset[b])%TEXEL_BYTES==0;
                expected_ready=coord_ok && !(fill_valid && expected_fill_ready && int'(fill_bank)==b);
                if(rd_ready[b] !== expected_ready) $fatal(1,"Bank arbitration mismatch");
                for(integer p=L-1;p>0;p=p-1) begin
                    expected_valid[b][p]=expected_valid[b][p-1];
                    expected_data[b][p]=expected_data[b][p-1];
                    expected_cookie[b][p]=expected_cookie[b][p-1];
                end
                expected_valid[b][0]=rd_valid[b] && expected_ready;
                if(rd_valid[b] && !coord_ok) expected_error=1;
                if(expected_valid[b][0]) begin
                    expected_data[b][0]=model[b][rd_set[b]][rd_way[b]]
                        [int'(rd_byte_offset[b])*8 +: TEXEL_BITS];
                    expected_cookie[b][0]=rd_cookie[b];
                    reads=reads+1;
                end
            end
            if(fill_valid && expected_fill_ready) begin
                model[fill_bank][fill_set][fill_way]=fill_line;
                fills=fills+1;
            end
            @(posedge clk); #1;
            for(integer b=0;b<BANKS;b=b+1) begin
                if(rd_rsp_valid[b] !== expected_valid[b][L-1])
                    $fatal(1,"Read valid latency mismatch bank %0d cycle %0d",b,cycles);
                if(expected_valid[b][L-1] &&
                    (rd_rsp_data[b] !== expected_data[b][L-1] ||
                     rd_rsp_cookie[b] !== expected_cookie[b][L-1]))
                    $fatal(1,"Read data/cookie mismatch bank %0d cycle %0d",b,cycles);
            end
            if(protocol_error !== expected_error) $fatal(1,"Array diagnostic mismatch");
            cycles=cycles+1;
            @(negedge clk);
        end
    endtask
    task automatic reset_pipe;
        begin
            n_rst=0; rd_valid=0; fill_valid=0; expected_error=0;
            for(integer b=0;b<BANKS;b=b+1)
                for(integer p=0;p<L;p=p+1) expected_valid[b][p]=0;
            repeat(2) @(negedge clk);
            if(rd_rsp_valid!=0 || protocol_error) $fatal(1,"Data reset failed");
            n_rst=1;
        end
    endtask
    initial begin
        reset_pipe();
        // Initialize every bank/set/way with a distinct line pattern.
        for(integer b=0;b<BANKS;b=b+1)
            for(integer s=0;s<SETS_PER_BANK;s=s+1)
                for(integer w=0;w<WAYS;w=w+1) begin
                    fill_valid=1; fill_bank=BANK_W'(b);
                    fill_set=SET_W'(s); fill_way=WAY_W'(w);
                    fill_line=make_line((b*SETS_PER_BANK+s)*WAYS+w);
                    tick();
                end
        fill_valid=0; rd_valid='1;
        // Every texel offset in every set and way, on all banks concurrently.
        for(integer s=0;s<SETS_PER_BANK;s=s+1)
            for(integer w=0;w<WAYS;w=w+1)
                for(integer t=0;t<LINE_BYTES/TEXEL_BYTES;t=t+1) begin
                    for(integer b=0;b<BANKS;b=b+1) begin
                        rd_set[b]=SET_W'(s); rd_way[b]=WAY_W'(w);
                        rd_byte_offset[b]=OFFSET_W'(t*TEXEL_BYTES);
                        rd_cookie[b]=C'(s+w+t+b);
                    end
                    tick();
                end
        // Overwrite while reading all banks; only target bank must stall.
        for(integer b=0;b<BANKS;b=b+1) begin
            fill_valid=1; fill_bank=BANK_W'(b); fill_set=0; fill_way=0;
            fill_line=make_line(1000+b); rd_set=0; rd_way=0; rd_byte_offset=0;
            tick();
            fill_valid=0; tick(); // retry the losing bank after the fill
        end
        for(integer c=0;c<1500;c=c+1) begin
            fill_valid=(random_below(100)<45);
            fill_bank=BANK_W'(random_below(BANKS));
            fill_set=SET_W'(random_below(SETS_PER_BANK));
            fill_way=WAY_W'(random_below(WAYS));
            fill_line=make_line(c+2000);
            for(integer b=0;b<BANKS;b=b+1) begin
                rd_valid[b]=(random_below(100)<85);
                rd_set[b]=SET_W'(random_below(SETS_PER_BANK));
                rd_way[b]=WAY_W'(random_below(WAYS));
                rd_byte_offset[b]=OFFSET_W'(random_below(LINE_BYTES/TEXEL_BYTES)*TEXEL_BYTES);
                rd_cookie[b]=C'(random_below(1<<C));
            end
            tick();
        end
        // Reset with pending reads flushes all response-valid pipeline stages.
        fill_valid=0; rd_valid='1; tick(); reset_pipe();
        repeat(L+1) tick();
        // Data storage retained; upstream tag-valid state remains its owner's job.
        rd_valid='1; rd_set=0; rd_way=0; rd_byte_offset=0; tick();
        rd_valid=0; repeat(L) tick();
        // Misaligned and crossing-end reads are blocked and flagged.
        rd_valid[0]=1; rd_byte_offset[0]=1; tick();
        rd_byte_offset[0]=OFFSET_W'(LINE_BYTES-1); tick();
        rd_valid=0; repeat(L) tick();
        $display("PASS data_array_tb latency=%0d reads=%0d fills=%0d cycles=%0d",
                 L,reads,fills,cycles);
        $finish;
    end
    initial begin #1000000; $fatal(1,"Data array timeout"); end
endmodule

