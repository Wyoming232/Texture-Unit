module tag_array (
	input logic clk, n_rst,
	input logic look_en0, look_en1, look_en2, look_en3,
	input logic [INDEX_W-1:0]look_idx0, look_idx1, look_idx2, look_idx3,
	input logic [TAG_W-1:0]look_tag0, look_tag1, look_tag2, look_tag3,

	input logic fill_en0, fill_en1, fill_en2, fill_en3,
    input logic [INDEX_W-1:0]fill_idx0, fill_idx1, fill_idx2, fill_idx3,
    input logic [WAY_W-1:0]fill_way0, fill_way1, fill_way2, fill_way3,

	output tag_out out0, out1, out2, out3
);

tag_bank bank0( .clk(clk), .n_rst(n_rst), look_en(look_en0),
		.look_idx(look_idx0), .look_tag(look_tag0), .out(out0),
		.fill_en(fill_en0), .fill_idx(fill_idx0), .fill_way(fill_way0));

tag_bank bank1( .clk(clk), .n_rst(n_rst), look_en(look_en1),
                .look_idx(look_idx1), .look_tag(look_tag1), .out(out1),
                .fill_en(fill_en1), .fill_idx(fill_idx1), .fill_way(fill_way1));

tag_bank bank2( .clk(clk), .n_rst(n_rst), look_en(look_en2),
                .look_idx(look_idx2), .look_tag(look_tag2), .out(out2),
                .fill_en(fill_en2), .fill_idx(fill_idx2), .fill_way(fill_way2));

tag_bank bank3( .clk(clk), .n_rst(n_rst), look_en(look_en3),
                .look_idx(look_idx3), .look_tag(look_tag3), .out(out3),
                .fill_en(fill_en3), .fill_idx(fill_idx3), .fill_way(fill_way3));
endmodule



module tag_bank (
	input logic clk, n_rst,
	input logic look_en,
	input logic [INDEX-1:0] look_idx,
	input logic [TAG_W-1:0] look_tag,
	input logic [INDEX-1:0] fill_idx,
	input logic [WAYS_W-1:0] fill_way,
	output tag_out out
);		

    logic [WAYS-1:0] valid[SETS_PER_BANK];
    logic [WAYS-1:0] ready[SETS_PER_BANK];
    logic [TAG_W-1:0] tag[SETS_PER_BANK][WAYS];
    logic [2:0] lru[SETS_PER_BANK];

    logic [WAYS-1:0] v, r;
    logic [2:0] lru_set;

    assign v = valid[look_idx];
    assign r = ready[look_idx];
    assign lru_set = lru[look_idx];

    logic [WAYS-1:0]match;

    assign match[0] = v[0] && (tag[look_idx][0] == look_tag);
    assign match[1] = v[1] && (tag[look_idx][1] == look_tag);
    assign match[2] = v[2] && (tag[look_idx][2] == look_tag);
    assign match[3]	= v[3] && (tag[look_idx][3] == look_tag);

    logic hit;
    logic [WAY_W-1:0] hit_way;

    assign hit = |match;
    assign hit_way = {match[3] | match[2], match[3] | match[1]};

    //for a miss
    logic [WAYS-1:0] replace;
    assign replace = ~v | r;

    //lru logic
    logic [WAY_W-1:0]lru_way;
    always_comb begin
        if(lru_set[0]) begin
            if(lru_set[1]) begin
                lru_way = 2'b01;
            end
            else begin
                lru_way = 2'b0;
            end
        end
        else begin
            if(lru_set[2]) begin
                lru_way = 2'b11;
            end
            else begin
                lru_way = 2'b10;
            end
        end
    end

    logic [WAY_W-1:0]alloc_way;
    always_comb begin
        if (!v[0]) begin
            alloc_way = 2'b0;
        end
        else if (!v[1]) begin
            alloc_way = 2'b01;
        end
        else if	(!v[2])	begin
                    alloc_way = 2'b10;
            end
        else if	(!v[3])	begin
                    alloc_way = 2'b11;
            end
        else if	(replace[lru_way])begin
                    alloc_way = lru_way;
            end
            else if (replace[0]) begin
                    alloc_way = 2'b0;
            end
            else if (replace[1]) begin
                    alloc_way = 2'b01;
            end
        else if (replace[2]) begin
                    alloc_way = 2'b11;
            end
        else begin
            alloc_way = 2'b11;
        end
    end

    logic busy;
    assign busy = !hit && !(|replace);

    logic[WAY_W-1:0]used_way;
    assign used_way = hit ? hit_way:alloc_way;

    logic [2:0]next_lru;
    always_comb begin
        next_lru = lru_set;

        case (used_way)
            2'b00: begin
                next_lru[0] = 1'b0; // Prefer evicting ways 2–3
                next_lru[1] = 1'b1; // Within ways 0–1, prefer way 1
            end

            2'b01: begin
                next_lru[0] = 1'b0;
                next_lru[1] = 1'b0;
            end

            2'b10: begin
                next_lru[0] = 1'b1;
                next_lru[2] = 1'b1;
            end

            2'b11: begin
                next_lru[0] = 1'b1;
                next_lru[2] = 1'b0;
            end

            default: begin
            end
        endcase
    end

    always_comb begin
        look_res.hit = hit;
        look_res.ready = |(match & r);
        look_res.way = hit ? hit_way : alloc_way;
        look_res.busy = busy;
    end

    always_ff @(posedge clk, negedge n_rst) begin
        if(!n_rst) begin
                valid <= '0;
                ready <= '0;
                lru <= '0;
        end
	    else begin
                if (look_en && !busy) begin
                        lru[look_idx] <= next_lru;
                end
                if (look_en && !hit && !busy) begin
                        valid[look_idx][alloc_way] <= 1'b1;
                        ready[look_idx][alloc_way] <= 1'b0;
                end
                if (fill_en) begin
                        ready[fill_idx][fill_way] <= 1'b1;
                end
                if(look_en && !hit && !busy)
                        tag[look_idx][alloc_way] <= look_tag;
                end
    end
endmodule