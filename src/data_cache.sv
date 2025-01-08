//////////////////////////////////////////////////////////////////////////////////
// Author: Sadeem Zahid
// Create Date: 12/18/2024 11:02:27 PM
// Design Name: L1 Data Cache 
// Module Name: cache.sv
// Project Name: Memory_Arch
// Description: This module is meant to serve as a data cache for later implementation into a RISC-V Pipeline Arch.
//              The Cache is 2-Way Set Associative, has an LRU policy, and has prefetching
// 
// Dependencies: None
// 
// Revision: A
// Revision 0.01 - File Created
// Additional Comments: -
// 
//////////////////////////////////////////////////////////////////////////////////

`define TAG_BITS 31:13    // Position of tag in address
`define INDEX_BITS 12:3   // Position of index in address
`define OFFSET_BITS 2:0   // Position of offset in address

module data_cache #(
      parameter int CACHE_SIZE = 32*1024*8,     // Cache size in bits
      parameter int NUM_WAYS = 2,              // Number of ways
      parameter int NUM_SETS = 1024,           // Number of sets
      parameter int BLOCK_BITS = 64,           // Size of a cache block in bits
      parameter int BUS_WIDTH = 32,            // Data bus width
      parameter int MEM_BUS_WIDTH = 64,        // Memory bus width (should match block size)
      parameter int INDEX_LEN = 10,            // Width of index field
      parameter int TAG_LEN = 19,              // Width of tag field
      parameter int OFFSET_LEN = 3,            // Width of offset field
      parameter WORD_LOW = 3,
      parameter WORD_HIGH = 7
    ) (
      input  logic                         clk,
      input  logic                         rst,
      input  logic [BUS_WIDTH-1:0]         cpu_addr,    // Address from CPU
      input  logic [BUS_WIDTH-1:0]         cpu_din,     // Data from CPU (store instruction)
      input  logic                         rd_enable,   // Read enable
      input  logic                         wr_enable,   // Write enable
      output logic                         cache_hit,   // 1 if hit, 0 during miss
      output logic [BUS_WIDTH-1:0]         cpu_dout,    // Data to CPU
      output logic [MEM_BUS_WIDTH-1:0]     mem_dout,    // Data from cache to memory
      output logic [BUS_WIDTH-1:0]         mem_rd_addr, // Memory read address
      output logic                         mem_rd_en,   // Memory read enable
      output logic [BUS_WIDTH-1:0]         mem_wr_addr, // Memory write address
      output logic                         mem_wr_en,   // Memory write enable
      input  logic [MEM_BUS_WIDTH-1:0]     mem_din      // Data coming from memory
    );
    
    logic [MEM_BUS_WIDTH-1:0] prefetch_buf;   // Buffer to hold prefetched data
    logic [BUS_WIDTH-1:0] prefetch_addr;      // Address for the prefetched block
    logic prefetch_en;                        // Signal to initiate prefetch


    // Cache WAY A
    logic valid_wayA [0:NUM_SETS-1];
    logic dirty_wayA [0:NUM_SETS-1];
    logic [1:0] lru_wayA [0:NUM_SETS-1];
    logic [MEM_BUS_WIDTH-1:0] data_wayA [0:NUM_SETS-1];
    logic [TAG_LEN-1:0] tag_wayA [0:NUM_SETS-1];
    
    // Cache WAY B
    logic valid_wayB [0:NUM_SETS-1];
    logic dirty_wayB [0:NUM_SETS-1];
    logic [1:0] lru_wayB [0:NUM_SETS-1];
    logic [MEM_BUS_WIDTH-1:0] data_wayB [0:NUM_SETS-1];
    logic [TAG_LEN-1:0] tag_wayB [0:NUM_SETS-1];
    
    logic internal_hit = 1'b0;
    logic [BUS_WIDTH-1:0] internal_dout = {BUS_WIDTH{1'b0}};
    logic [MEM_BUS_WIDTH-1:0] internal_mdout = {MEM_BUS_WIDTH{1'b0}};
    logic [BUS_WIDTH-1:0] internal_wr_addr = {BUS_WIDTH{1'b0}};
    logic internal_wr_en = 1'b0;
    
    assign cache_hit = internal_hit;
    assign mem_rd_en = !((valid_wayA[cpu_addr[`INDEX_BITS]] && (tag_wayA[cpu_addr[`INDEX_BITS]] == cpu_addr[`TAG_BITS])) || 
                         (valid_wayB[cpu_addr[`INDEX_BITS]] && (tag_wayB[cpu_addr[`INDEX_BITS]] == cpu_addr[`TAG_BITS])));
    assign mem_wr_en = internal_wr_en;
    assign mem_dout = internal_mdout;
    assign mem_rd_addr = {cpu_addr[`TAG_BITS],cpu_addr[`INDEX_BITS]};
    assign mem_wr_addr = internal_wr_addr;
    assign cpu_dout = internal_dout;
    
    initial begin
        for(int i = 0; i < NUM_SETS; i++) begin
            valid_wayA[i] = 0;
            dirty_wayA[i] = 0;
            lru_wayA[i] = 0;
            valid_wayB[i] = 0;
            dirty_wayB[i] = 0;
            lru_wayB[i] = 0;
        end
     end

    // State parameters
    typedef enum logic [1:0] { IDLE, MISS } fsm_state_t;
    fsm_state_t curr_state, next_state;

    // Sequential logic for state transitions
    always_ff @(posedge clk or posedge rst) begin
        if (rst) 
            curr_state <= IDLE;
        else 
            curr_state <= next_state;
    end

    // Combinational logic for state machine
    always_comb begin
        case (curr_state)
            IDLE: begin
                internal_wr_en = 0;  // Default memory write enable

                internal_hit = ((valid_wayA[cpu_addr[`INDEX_BITS]] && (tag_wayA[cpu_addr[`INDEX_BITS]] == cpu_addr[`TAG_BITS])) || 
                               (valid_wayB[cpu_addr[`INDEX_BITS]] && (tag_wayB[cpu_addr[`INDEX_BITS]] == cpu_addr[`TAG_BITS])));

                if (~rd_enable && ~wr_enable) begin
                    next_state <= IDLE;
                end
                // WAY A
                else if (valid_wayA[cpu_addr[`INDEX_BITS]] && (tag_wayA[cpu_addr[`INDEX_BITS]] == cpu_addr[`TAG_BITS])) begin
                    if (rd_enable) begin
                        internal_dout = (cpu_addr[`OFFSET_BITS] <= WORD_LOW) ? data_wayA[cpu_addr[`INDEX_BITS]][BUS_WIDTH-1:0] : data_wayA[cpu_addr[`INDEX_BITS]][2*BUS_WIDTH-1:BUS_WIDTH];
                    end else if (wr_enable) begin
                        internal_dout = {BUS_WIDTH{1'b0}};
                        dirty_wayA[cpu_addr[`INDEX_BITS]] <= 1;
                        if (cpu_addr[`OFFSET_BITS] <= WORD_LOW) data_wayA[cpu_addr[`INDEX_BITS]][BUS_WIDTH-1:0] <= cpu_din;
                        else data_wayA[cpu_addr[`INDEX_BITS]][2*BUS_WIDTH-1:BUS_WIDTH] <= cpu_din;
                    end

                    if (lru_wayA[cpu_addr[`INDEX_BITS]] <= lru_wayB[cpu_addr[`INDEX_BITS]]) begin
                        lru_wayB[cpu_addr[`INDEX_BITS]] += 1;
                    end
                    lru_wayA[cpu_addr[`INDEX_BITS]] <= 0;

                    // Trigger prefetch
                    prefetch_en <= 1;
                    prefetch_addr <= {cpu_addr[`TAG_BITS], cpu_addr[`INDEX_BITS]} + BLOCK_BITS;
                end
                // WAY B
                else if (valid_wayB[cpu_addr[`INDEX_BITS]] && (tag_wayB[cpu_addr[`INDEX_BITS]] == cpu_addr[`TAG_BITS])) begin
                    if (rd_enable) begin
                        internal_dout = (cpu_addr[`OFFSET_BITS] <= WORD_LOW) ? data_wayB[cpu_addr[`INDEX_BITS]][BUS_WIDTH-1:0] : data_wayB[cpu_addr[`INDEX_BITS]][2*BUS_WIDTH-1:BUS_WIDTH];
                    end else if (wr_enable) begin
                        internal_dout = {BUS_WIDTH{1'b0}};
                        dirty_wayB[cpu_addr[`INDEX_BITS]] <= 1;
                        if (cpu_addr[`OFFSET_BITS] <= WORD_LOW) data_wayB[cpu_addr[`INDEX_BITS]][BUS_WIDTH-1:0] <= cpu_din;
                        else data_wayB[cpu_addr[`INDEX_BITS]][2*BUS_WIDTH-1:BUS_WIDTH] <= cpu_din;
                    end

                    if (lru_wayB[cpu_addr[`INDEX_BITS]] <= lru_wayA[cpu_addr[`INDEX_BITS]]) begin
                        lru_wayA[cpu_addr[`INDEX_BITS]] += 1;
                    end
                    lru_wayB[cpu_addr[`INDEX_BITS]] <= 0;

                    // Trigger prefetch
                    prefetch_en <= 1;
                    prefetch_addr <= {cpu_addr[`TAG_BITS], cpu_addr[`INDEX_BITS]} + BLOCK_BITS;
                end
                else next_state <= MISS;
            end

            MISS: begin
                // Handle cache miss
                if (~valid_wayA[cpu_addr[`INDEX_BITS]]) begin
                    data_wayA[cpu_addr[`INDEX_BITS]] <= mem_din;
                    tag_wayA[cpu_addr[`INDEX_BITS]] <= cpu_addr[`TAG_BITS];
                    dirty_wayA[cpu_addr[`INDEX_BITS]] <= 0;
                    valid_wayA[cpu_addr[`INDEX_BITS]] <= 1;
                end else if (~valid_wayB[cpu_addr[`INDEX_BITS]]) begin
                    data_wayB[cpu_addr[`INDEX_BITS]] <= mem_din;
                    tag_wayB[cpu_addr[`INDEX_BITS]] <= cpu_addr[`TAG_BITS];
                    dirty_wayB[cpu_addr[`INDEX_BITS]] <= 0;
                    valid_wayB[cpu_addr[`INDEX_BITS]] <= 1;
                end
                // Handle LRU eviction
                else if (lru_wayA[cpu_addr[`INDEX_BITS]] == 3) begin
                    if (dirty_wayA[cpu_addr[`INDEX_BITS]]) begin
                        internal_wr_addr <= {tag_wayA[cpu_addr[`INDEX_BITS]], cpu_addr[`INDEX_BITS]};
                        internal_wr_en <= 1;
                        internal_mdout <= data_wayA[cpu_addr[`INDEX_BITS]];
                    end
                    data_wayA[cpu_addr[`INDEX_BITS]] <= mem_din;
                    tag_wayA[cpu_addr[`INDEX_BITS]] <= cpu_addr[`TAG_BITS];
                    dirty_wayA[cpu_addr[`INDEX_BITS]] <= 0;
                    valid_wayA[cpu_addr[`INDEX_BITS]] <= 1;
                end else if (lru_wayB[cpu_addr[`INDEX_BITS]] == 3) begin
                    if (dirty_wayB[cpu_addr[`INDEX_BITS]]) begin
                        internal_wr_addr <= {tag_wayB[cpu_addr[`INDEX_BITS]], cpu_addr[`INDEX_BITS]};
                        internal_wr_en <= 1;
                        internal_mdout <= data_wayB[cpu_addr[`INDEX_BITS]];
                    end
                    data_wayB[cpu_addr[`INDEX_BITS]] <= mem_din;
                    tag_wayB[cpu_addr[`INDEX_BITS]] <= cpu_addr[`TAG_BITS];
                    dirty_wayB[cpu_addr[`INDEX_BITS]] <= 0;
                    valid_wayB[cpu_addr[`INDEX_BITS]] <= 1;
                end

                // Trigger prefetch after handling the miss
                prefetch_en <= 1;
                prefetch_addr <= {cpu_addr[`TAG_BITS], cpu_addr[`INDEX_BITS]} + BLOCK_BITS;

                next_state = IDLE;
            end

            default: next_state = IDLE;
        endcase
    end

    // Handle prefetch requests
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            prefetch_en <= 0;
        end else if (prefetch_en) begin
            // Issue memory read for prefetch address
            mem_rd_addr <= prefetch_addr;
            mem_rd_en <= 1;

            // Store prefetched data in the buffer
            prefetch_buf <= mem_din;
            prefetch_en <= 0;

            // Insert prefetched data into the cache if not already present
            if (!valid_wayA[prefetch_addr[`INDEX_BITS]]) begin
                data_wayA[prefetch_addr[`INDEX_BITS]] <= prefetch_buf;
                tag_wayA[prefetch_addr[`INDEX_BITS]] <= prefetch_addr[`TAG_BITS];
                valid_wayA[prefetch_addr[`INDEX_BITS]] <= 1;
            end else if (!valid_wayB[prefetch_addr[`INDEX_BITS]]) begin
                data_wayB[prefetch_addr[`INDEX_BITS]] <= prefetch_buf;
                tag_wayB[prefetch_addr[`INDEX_BITS]] <= prefetch_addr[`TAG_BITS];
                valid_wayB[prefetch_addr[`INDEX_BITS]] <= 1;
            end
        end
    end

endmodule
