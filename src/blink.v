// DE0-Nano "hello world": divide the 50 MHz clock and drive the 8 LEDs.
// KEY[0] is an active-low async reset. SW XORs into the LED pattern so
// you can see the switches take effect without rebuilding.
module blink (
    input        CLOCK_50,
    input  [1:0] KEY,
    input  [3:0] SW,
    output [7:0] LED
);

    reg [31:0] counter = 32'd0;

    always @(posedge CLOCK_50 or negedge KEY[0]) begin
        if (!KEY[0])
            counter <= 32'd0;
        else
            counter <= counter + 32'd1;
    end

    assign LED = counter[25:18] ^ {4'b0000, SW};

endmodule
