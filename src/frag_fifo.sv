parameter FRAG_DEPTH = 32
parameter PTR_W = 5;

module frag_fifo (
    input logic clk,
    input logic n_rst,
    input logic push_en,
    input logic pop_en
    input frag_entry_t write_data,
    output logic head,
    output frag_entry_t head_entry,
);

    frag_entry_t frag_entries [32];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [PTR_W:0] count;

    always_comb begin
        head = !(count == 0);
        head_entry = frag_entries[rd_ptr];
    end

    always_ff @(posedge clk, negedge n_rst) begin
        if (!n_rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            count <= '0;
        end else begin
        if (push_en && (count != 32)) begin
            frag_entries[wr_ptr] <= write_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
        if (pop_en && !empty) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
        case ({push_en && !(count != 32), pop_en && (count != 0)})
        2'b10: count <= count + 1'b1;
        2'b01: count <= count - 1'b1;
        default: count <= count;
        endcase
        end
    end

endmodule
