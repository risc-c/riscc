.PHONY: test-vblank-timer
test-vblank-timer:
	mkdir -p build/test-vblank-timer
	iverilog -g2012 -s vblank_timer_tb -o build/test-vblank-timer/test.vvp \
	  boards/shared/rtl/riscc_timer_mmio.v boards/shared/test/vblank_timer_tb.v
	vvp build/test-vblank-timer/test.vvp

test-peripherals: test-vblank-timer
