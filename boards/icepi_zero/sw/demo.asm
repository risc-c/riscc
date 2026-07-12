; RISC-C Icepi Zero SoC demo.
;
; UART hardware is intentionally tiny.  The ISR moves bytes between the
; hardware registers and software queues; the main loop owns command policy.

.vectors
    JMP16 start
    JMP16 isr_irq

.text
boot_msg:
.ifdef RISCC_ATUM_A3
    .asciz "RISC-C on Atum A3 Nano\r\n"
.else
    .asciz "RISC-C on icepi-zero\r\n"
.endif
    .align 2

; Queue byte r1 into the TX software queue.  Drops on full.
; Clobbers r0..r5.  Preserves r6/r7.
tx_push:
    LDI16 r2, tx_tail
    LDW   r3, [r2+0]       ; tail
    LDI16 r4, tx_head
    LDW   r5, [r4+0]       ; head
    MOV   r0, r3
    ADDI  r0, 1
    ANDI  r0, 63           ; next tail
    SUB   r5, r0, r5
    BEQZ  tx_push_done     ; full
    LDI16 r4, tx_q
    ADD   r4, r4, r3
    STB   r1, [r4]
    STW   r0, [r2+0]
tx_push_done:
    RETS

; Queue asciz string at r7 into TX queue.
; Clobbers r0..r6.  Preserves r7.
tx_puts:
    LDI   r6, 0
tx_puts_loop:
    LDB   r1, [r7+r6]
    OR    r0, r1, r1
    BEQZ  tx_puts_done
    CALL16 tx_push
    ADDI  r6, 1
    JMP8  tx_puts_loop
tx_puts_done:
    RETS

; Pop one RX byte into r1 if available and apply simple demo controls.
; Clobbers r0..r5.
process_rx:
    LDI16 r2, rx_head
    LDW   r3, [r2+0]       ; head
    LDI16 r4, rx_tail
    LDW   r5, [r4+0]       ; tail
    SUB   r0, r3, r5
    BEQZ  process_rx_done
    LDI16 r4, rx_q
    LDB   r1, [r4+r3]
    ADDI  r3, 1
    ANDI  r3, 15
    STW   r3, [r2+0]

    CMPI  r1, '1'
    BNEZ  pr_not_1
    LDI   r1, 0
    LDI16 r2, pattern
    STW   r1, [r2+0]
    JMP8  process_rx_done
pr_not_1:
    CMPI  r1, '2'
    BNEZ  pr_not_2
    LDI   r1, 1
    LDI16 r2, pattern
    STW   r1, [r2+0]
    JMP8  process_rx_done
pr_not_2:
    CMPI  r1, '3'
    BNEZ  pr_not_3
    LDI   r1, 2
    LDI16 r2, pattern
    STW   r1, [r2+0]
    JMP8  process_rx_done
pr_not_3:
    CMPI  r1, '+'
    BNEZ  pr_not_plus
    LDI16 r2, speed
    LDW   r1, [r2+0]
    ADDI  r1, 1
    STW   r1, [r2+0]
    JMP8  process_rx_done
pr_not_plus:
    CMPI  r1, '-'
    BNEZ  process_rx_done
    LDI16 r2, speed
    LDW   r1, [r2+0]
    ADDI  r1, -1
    STW   r1, [r2+0]
process_rx_done:
    RETS

; Render the Julia set inside the fixed border.  Four adjacent pixels pack into
; each 16-bit framebuffer word.  Clobbers r0..r7.
draw_frame:
    MFS   r1, S7           ; this routine calls helpers, so preserve caller link
    LDI16 r2, draw_link
    STW   r1, [r2+0]

    LDI16 r1, frame
    LDW   r2, [r1+0]
    LDI16 r3, speed
    LDW   r3, [r3+0]
    ADDI  r3, 1
    ADD   r2, r2, r3
    STW   r2, [r1+0]

    LDI16 r1, frame
    LDW   r1, [r1+0]
    LDI16 r2, pattern
    LDW   r2, [r2+0]
    ADD   r1, r1, r2
    LDI16 r3, 0xFFE8      ; LED register
    STW   r1, [r3+0]

    LDI   r1, 'F'         ; frame entered
    CALL16 tx_push
    CALL16 draw_ticker
    LDI   r1, 'T'         ; ticker completed
    CALL16 tx_push

    LDI16 r7, 0x8320      ; byte address of current framebuffer row
    LDI   r6, 10          ; y: 10..118, top rows are the ticker band
draw_y_loop:
    LDI   r1, '.'         ; hardware progress heartbeat: one dot per Julia row
    CALL16 tx_push
    MOV   r5, r6          ; zy0 = (y - 60) * view_step
    ADDI  r5, -60
    LDI16 r1, view_step
    LDW   r1, [r1+0]
    MUL   r5, r5, r1
    LDI16 r1, zy0_var
    STW   r5, [r1+0]

    LDI   r4, 0           ; packed x word: 0..39
draw_x_loop:
    LDI16 r1, xblk
    STW   r4, [r1+0]
    LDI16 r1, yblk
    STW   r6, [r1+0]
    LDI16 r1, fb_row
    STW   r7, [r1+0]

    SHLI  r5, r4, 2       ; first pixel in this packed word
    LDI16 r1, xpix
    STW   r5, [r1+0]

    CALL16 julia_pixel     ; lane 0
    LDI16 r2, pack_word
    STW   r1, [r2+0]

    LDI16 r2, xpix         ; lane 1
    LDW   r5, [r2+0]
    ADDI  r5, 1
    STW   r5, [r2+0]
    CALL16 julia_pixel
    SHLI  r1, r1, 4
    LDI16 r2, pack_word
    LDW   r3, [r2+0]
    OR    r3, r3, r1
    STW   r3, [r2+0]

    LDI16 r2, xpix         ; lane 2
    LDW   r5, [r2+0]
    ADDI  r5, 1
    STW   r5, [r2+0]
    CALL16 julia_pixel
    SHLI  r1, r1, 8
    LDI16 r2, pack_word
    LDW   r3, [r2+0]
    OR    r3, r3, r1
    STW   r3, [r2+0]

    LDI16 r2, xpix         ; lane 3
    LDW   r5, [r2+0]
    ADDI  r5, 1
    STW   r5, [r2+0]
    CALL16 julia_pixel
    SHLI  r1, r1, 8
    SHLI  r1, r1, 4
    LDI16 r2, pack_word
    LDW   r3, [r2+0]
    OR    r1, r3, r1

    LDI16 r2, xblk
    LDW   r4, [r2+0]
    LDI16 r2, yblk
    LDW   r6, [r2+0]
    LDI16 r2, fb_row
    LDW   r7, [r2+0]

    CMPI  r4, 0
    BNEZ  draw_not_left_edge
    ORI   r1, 0x0F        ; preserve left border pixel
draw_not_left_edge:
    CMPI  r4, 39
    BNEZ  draw_store_word
    LDI16 r3, 0xF000      ; preserve right border pixel
    OR    r1, r1, r3
draw_store_word:
    SHL1  r2, r4
    ADD   r2, r2, r7
    STW   r1, [r2+0]

    ADDI  r4, 1
    CMPI  r4, 40
    BEQZ  draw_x_done
    LDI16 r1, draw_x_loop >> 1
    JMP   r1
draw_x_done:
    LDI16 r1, yblk
    STW   r6, [r1+0]
    LDI16 r1, fb_row
    STW   r7, [r1+0]
    CALL16 draw_ticker
    LDI16 r1, yblk
    LDW   r6, [r1+0]
    LDI16 r1, fb_row
    LDW   r7, [r1+0]

    LDI16 r2, 80          ; next framebuffer row
    ADD   r7, r7, r2
    ADDI  r6, 1
    CMPI  r6, 119
    BEQZ  draw_done
    LDI16 r1, draw_y_loop >> 1
    JMP   r1
draw_done:
    LDI   r1, 13          ; one line per completed frame
    CALL16 tx_push
    LDI   r1, 10
    CALL16 tx_push
    CALL16 update_julia_param
    LDI16 r2, draw_link
    LDW   r1, [r2+0]
    MTS   S7, r1
    RETS

; Draw a one-framebuffer-pixel border once at boot.  The renderer preserves
; these pixels instead of repainting them every frame.
draw_border:
    LDI16 r1, 0xFFFF
    LDI16 r7, 0x8000
    LDI   r6, 0
border_top_loop:
    STW   r1, [r7+0]
    ADDI  r7, 2
    ADDI  r6, 1
    CMPI  r6, 40
    BEQZ  border_top_done
    LDI16 r2, border_top_loop >> 1
    JMP   r2
border_top_done:
    LDI16 r7, 0xA530
    LDI   r6, 0
border_bottom_loop:
    STW   r1, [r7+0]
    ADDI  r7, 2
    ADDI  r6, 1
    CMPI  r6, 40
    BEQZ  border_bottom_done
    LDI16 r2, border_bottom_loop >> 1
    JMP   r2
border_bottom_done:
    LDI16 r7, 0x8050
    LDI   r6, 1
    LDI   r3, 0x000F
    LDI16 r4, 0xF000
border_side_loop:
    LDW   r2, [r7+0]
    OR    r2, r2, r3
    STW   r2, [r7+0]

    LDI   r5, 78
    ADD   r5, r5, r7
    LDW   r2, [r5+0]
    OR    r2, r2, r4
    STW   r2, [r5+0]

    LDI   r5, 80
    ADD   r7, r7, r5
    ADDI  r6, 1
    CMPI  r6, 119
    BEQZ  border_done
    LDI16 r2, border_side_loop >> 1
    JMP   r2
border_done:
    RETS

; Signed fixed-point multiply, Q10 output.  Inputs in r1/r2, result in r1.
; Clobbers r0..r7.  Exact enough for the fractal path; the dropped low
; carry is below one Q10 unit.
fmul_q10:
    LDI   r0, 0
    SLT   r0, r1, r0
    MOV   r3, r0
    BEQZ  fmul_a_pos
    LDI   r0, 0
    SUB   r1, r0, r1
fmul_a_pos:
    LDI   r0, 0
    SLT   r0, r2, r0
    MOV   r4, r0
    BEQZ  fmul_b_pos
    LDI   r0, 0
    SUB   r2, r0, r2
fmul_b_pos:
    XOR   r3, r3, r4
    LDI16 r0, fmul_sign
    STW   r3, [r0+0]

    MOV   r4, r1          ; al
    ANDI  r4, 255
    SHRI  r5, r1, 8       ; ah
    MOV   r6, r2          ; bl
    ANDI  r6, 255
    SHRI  r7, r2, 8       ; bh

    MUL   r1, r4, r6      ; al * bl
    SHRI  r1, r1, 8
    SHRI  r1, r1, 2

    MUL   r2, r5, r6      ; ah * bl
    MUL   r3, r4, r7      ; al * bh
    ADD   r2, r2, r3
    SHRI  r2, r2, 2
    ADD   r1, r1, r2

    MUL   r2, r5, r7      ; ah * bh
    SHLI  r2, r2, 6
    ADD   r1, r1, r2

    LDI16 r0, fmul_sign
    LDW   r2, [r0+0]
    OR    r0, r2, r2
    BEQZ  fmul_done
    LDI   r0, 0
    SUB   r1, r0, r1
fmul_done:
    RETS

; Firmware title ticker.  Draws a 10-pixel-high band into the top framebuffer:
; two black guard rows, seven font rows, and one blank spacer row.
draw_ticker:
    MFS   r1, S7
    LDI16 r2, ticker_link
    STW   r1, [r2+0]

    LDI   r7, 1
ticker_row_loop:
    LDI16 r1, ticker_row
    STW   r7, [r1+0]

    MOV   r1, r7
    LDI   r2, 80
    MUL   r1, r1, r2
    LDI16 r2, 0x8000
    ADD   r1, r1, r2
    LDI16 r2, ticker_fb_addr
    STW   r1, [r2+0]

    LDI16 r1, ticker_scroll
    LDW   r3, [r1+0]
    LDI   r4, 0
ticker_init_pos:
    LDI   r5, 6
    SUB   r0, r3, r5
    BLTZ  ticker_init_done
    MOV   r3, r0
    ADDI  r4, 1
    JMP8  ticker_init_pos
ticker_init_done:
    LDI16 r1, ticker_col
    STW   r3, [r1+0]
    LDI16 r1, ticker_char
    STW   r4, [r1+0]

    LDI   r6, 0
ticker_word_loop:
    LDI   r1, 0
    LDI16 r2, ticker_word
    STW   r1, [r2+0]

    LDI   r1, 0
    LDI16 r2, ticker_lane
    STW   r1, [r2+0]
    CALL16 ticker_emit_pixel
    LDI   r1, 1
    LDI16 r2, ticker_lane
    STW   r1, [r2+0]
    CALL16 ticker_emit_pixel
    LDI   r1, 2
    LDI16 r2, ticker_lane
    STW   r1, [r2+0]
    CALL16 ticker_emit_pixel
    LDI   r1, 3
    LDI16 r2, ticker_lane
    STW   r1, [r2+0]
    CALL16 ticker_emit_pixel

    LDI16 r1, ticker_word
    LDW   r2, [r1+0]
    LDI16 r1, ticker_fb_addr
    LDW   r3, [r1+0]
    CMPI  r6, 0
    BNEZ  ticker_not_left_edge
    ORI   r2, 0x0F        ; preserve left border pixel
ticker_not_left_edge:
    CMPI  r6, 39
    BNEZ  ticker_store_word
    LDI16 r4, 0xF000      ; preserve right border pixel
    OR    r2, r2, r4
ticker_store_word:
    STW   r2, [r3+0]
    ADDI  r3, 2
    STW   r3, [r1+0]

    ADDI  r6, 1
    CMPI  r6, 40
    BEQZ  ticker_row_done
    LDI16 r1, ticker_word_loop >> 1
    JMP   r1
ticker_row_done:
    ADDI  r7, 1
    CMPI  r7, 10
    BEQZ  ticker_done_rows
    LDI16 r1, ticker_row_loop >> 1
    JMP   r1
ticker_done_rows:
    LDI16 r1, ticker_scroll
    LDW   r2, [r1+0]
    ADDI  r2, 1
    LDI   r3, 168
    SUB   r0, r2, r3
    BNEZ  ticker_scroll_store
    LDI   r2, 0
ticker_scroll_store:
    STW   r2, [r1+0]

    LDI16 r2, ticker_link
    LDW   r1, [r2+0]
    MTS   S7, r1
    RETS

ticker_emit_pixel:
    LDI16 r1, ticker_col
    LDW   r3, [r1+0]
    CMPI  r3, 5
    BEQZ  ticker_pixel_advance

    ; The font is 5x7 with two black guard rows above and a blank spacer below.
    LDI16 r1, ticker_row
    LDW   r2, [r1+0]
    CMPI  r2, 0
    BEQZ  ticker_pixel_advance
    CMPI  r2, 1
    BEQZ  ticker_pixel_advance
    ADDI  r2, -1
    ADDI  r2, -1
    CMPI  r2, 7
    BEQZ  ticker_pixel_advance

    LDI16 r1, ticker_char
    LDW   r4, [r1+0]
    SHLI  r5, r4, 3
    SUB   r5, r5, r4
    ADD   r5, r5, r2
    LDI16 r1, ticker_glyphs
    LDB   r5, [r1+r5]
    LDI16 r1, ticker_bit_masks
    LDB   r2, [r1+r3]
    AND   r0, r5, r2
    BEQZ  ticker_pixel_advance

    LDI16 r1, ticker_lane
    LDW   r2, [r1+0]
    SHL1  r2, r2
    LDI16 r1, ticker_nibble_masks
    LDWX  r5, [r1+r2]
    LDI16 r1, ticker_word
    LDW   r2, [r1+0]
    OR    r2, r2, r5
    STW   r2, [r1+0]

ticker_pixel_advance:
    LDI16 r1, ticker_col
    LDW   r3, [r1+0]
    ADDI  r3, 1
    CMPI  r3, 6
    BNEZ  ticker_col_store
    LDI   r3, 0
    LDI16 r2, ticker_char
    LDW   r4, [r2+0]
    ADDI  r4, 1
    CMPI  r4, 28
    BNEZ  ticker_char_store
    LDI   r4, 0
ticker_char_store:
    STW   r4, [r2+0]
ticker_col_store:
    STW   r3, [r1+0]
    RETS

; Compute one Julia sample for xpix/zy0_var.  r1 returns one 4-bit color.
julia_pixel:
    MFS   r1, S7
    LDI16 r2, fractal_link
    STW   r1, [r2+0]

    LDI16 r6, xpix
    LDW   r6, [r6+0]
    ADDI  r6, -80         ; zx0 = (x - 80) * view_step
    LDI16 r7, view_step
    LDW   r7, [r7+0]
    MUL   r7, r6, r7
    LDI16 r6, zx_var
    STW   r7, [r6+0]

    LDI16 r1, zy0_var
    LDW   r1, [r1+0]
    LDI16 r2, zy_var
    STW   r1, [r2+0]
    LDI   r1, 0
    LDI16 r2, iter_var
    STW   r1, [r2+0]
julia_iter:
    LDI16 r0, zx_var
    LDW   r1, [r0+0]
    MOV   r2, r1
    CALL16 fmul_q10
    LDI16 r0, zx2_var
    STW   r1, [r0+0]

    LDI16 r0, zy_var
    LDW   r1, [r0+0]
    MOV   r2, r1
    CALL16 fmul_q10
    LDI16 r0, zy2_var
    STW   r1, [r0+0]

    LDI16 r0, zx2_var
    LDW   r4, [r0+0]
    LDI16 r0, zy2_var
    LDW   r5, [r0+0]
    ADD   r0, r4, r5
    LDI16 r6, 4095
    SLTU  r0, r6, r0      ; escape when zx2 + zy2 >= 4096 (radius 2)
    BNEZ  julia_done
    LDI16 r0, iter_var
    LDW   r3, [r0+0]
    CMPI  r3, 31
    BEQZ  julia_done

    LDI16 r0, zx_var
    LDW   r1, [r0+0]
    LDI16 r0, zy_var
    LDW   r2, [r0+0]
    CALL16 fmul_q10
    SHL1  r7, r1          ; new zy = 2*zx*zy + julia_cy
    LDI16 r6, julia_cy
    LDW   r6, [r6+0]
    ADD   r7, r7, r6
    LDI16 r0, new_zy_var
    STW   r7, [r0+0]

    LDI16 r0, zx2_var
    LDW   r4, [r0+0]
    LDI16 r0, zy2_var
    LDW   r5, [r0+0]
    SUB   r1, r4, r5      ; new zx = zx2 - zy2 + julia_cx
    LDI16 r6, julia_cx
    LDW   r6, [r6+0]
    ADD   r1, r1, r6
    LDI16 r0, zx_var
    STW   r1, [r0+0]
    LDI16 r0, new_zy_var
    LDW   r2, [r0+0]
    LDI16 r0, zy_var
    STW   r2, [r0+0]

    LDI16 r0, iter_var
    LDW   r3, [r0+0]
    ADDI  r3, 1
    STW   r3, [r0+0]
    JMP8  julia_iter
julia_done:
    LDI16 r0, iter_var
    LDW   r3, [r0+0]
    CMPI  r3, 31
    BNEZ  julia_color
    LDI   r3, 0           ; inside the set: black
    JMP8  julia_pixel_done
julia_color:
    LDI16 r6, pattern
    LDW   r6, [r6+0]
    ADD   r3, r3, r6
    ANDI  r3, 15
julia_pixel_done:
    MOV   r1, r3
    LDI16 r2, fractal_link
    LDW   r0, [r2+0]
    MTS   S7, r0
    RETS

; Move the Julia parameter c around a Q10 approximation of the classic
; c = 0.7885*exp(i*a) animation path.  No zoom: all precision stays in pixels.
update_julia_param:
    LDI16 r1, julia_target
    LDW   r2, [r1+0]
    SHLI  r2, r2, 2       ; two 16-bit words per path point
    LDI16 r3, julia_path
    ADD   r3, r3, r2
    LDW   r4, [r3+0]      ; target cx
    LDW   r5, [r3+2]      ; target cy

    LDI   r7, 1           ; still-at-target flag

    LDI16 r1, julia_cx
    LDW   r2, [r1+0]
    SUB   r0, r4, r2
    BEQZ  update_julia_x_done
    LDI   r7, 0
    BLTZ  update_julia_x_dec
    ADDI  r2, 8
    SUB   r0, r4, r2
    BGEZ  update_julia_x_store
    MOV   r2, r4
    JMP8  update_julia_x_store
update_julia_x_dec:
    ADDI  r2, -8
    SUB   r0, r2, r4
    BGEZ  update_julia_x_store
    MOV   r2, r4
update_julia_x_store:
    STW   r2, [r1+0]
update_julia_x_done:

    LDI16 r1, julia_cy
    LDW   r2, [r1+0]
    SUB   r0, r5, r2
    BEQZ  update_julia_y_done
    LDI   r7, 0
    BLTZ  update_julia_y_dec
    ADDI  r2, 8
    SUB   r0, r5, r2
    BGEZ  update_julia_y_store
    MOV   r2, r5
    JMP8  update_julia_y_store
update_julia_y_dec:
    ADDI  r2, -8
    SUB   r0, r2, r5
    BGEZ  update_julia_y_store
    MOV   r2, r5
update_julia_y_store:
    STW   r2, [r1+0]
update_julia_y_done:

    OR    r0, r7, r7
    BEQZ  update_julia_done
    LDI16 r1, julia_target
    LDW   r2, [r1+0]
    ADDI  r2, 1
    CMPI  r2, 16
    BNEZ  update_julia_target_store
    LDI   r2, 0
update_julia_target_store:
    STW   r2, [r1+0]
update_julia_done:
    RETS

isr_irq:
    MTS   S1, r0
    MTS   S2, r1
    MTS   S3, r2
    MTS   S4, r3
    MTS   S5, r4
    MTS   S6, r5

    ; RX ready: read the hardware byte and enqueue it if space exists.
    LDI16 r1, 0xFFF4
    LDW   r2, [r1+0]
    MOV   r0, r2
    ANDI  r0, 2
    BEQZ  isr_rx_done
    LDI16 r1, 0xFFF2
    LDW   r1, [r1+0]
    LDI16 r2, rx_tail
    LDW   r3, [r2+0]
    LDI16 r4, rx_head
    LDW   r5, [r4+0]
    MOV   r0, r3
    ADDI  r0, 1
    ANDI  r0, 15
    SUB   r5, r0, r5
    BEQZ  isr_rx_done
    LDI16 r4, rx_q
    ADD   r4, r4, r3
    STB   r1, [r4]
    STW   r0, [r2+0]
isr_rx_done:

    ; TX ready: drain one software queue byte, or disable TX-ready IRQ.
    LDI16 r1, 0xFFF4
    LDW   r2, [r1+0]
    MOV   r0, r2
    ANDI  r0, 1
    BEQZ  isr_done
    LDI16 r1, tx_head
    LDW   r2, [r1+0]
    LDI16 r3, tx_tail
    LDW   r4, [r3+0]
    SUB   r0, r2, r4
    BEQZ  isr_tx_empty
    LDI16 r5, tx_q
    LDB   r4, [r5+r2]
    LDI16 r5, 0xFFF0
    STW   r4, [r5+0]
    ADDI  r2, 1
    ANDI  r2, 63
    STW   r2, [r1+0]
    LDI16 r5, 0xFFF6
    LDI   r4, 3
    STW   r4, [r5+0]
    JMP8  isr_done
isr_tx_empty:
    LDI16 r5, 0xFFF6
    LDI   r4, 1
    STW   r4, [r5+0]

isr_done:
    MFS   r5, S6
    MFS   r4, S5
    MFS   r3, S4
    MFS   r2, S3
    MFS   r1, S2
    MFS   r0, S1
    ERET

start:
    LDI16 r7, boot_msg
    LDI   r6, 0
boot_queue_loop:
    LDB   r1, [r7+r6]
    OR    r0, r1, r1
    BEQZ  boot_queue_done
    CALL16 tx_push
    ADDI  r6, 1
    JMP8  boot_queue_loop
boot_queue_done:
    CALL16 draw_border
    LDI16 r1, 0xFFF6
    LDI   r2, 3
    STW   r2, [r1+0]
    STI

main_loop:
    CALL16 process_rx
    CALL16 draw_frame
    JMP8  main_loop

.data
rx_head: .word 0
rx_tail: .word 0
tx_head: .word 0
tx_tail: .word 0
pattern: .word 0
speed:   .word 0
frame:   .word 0
draw_link: .word 0
fractal_link: .word 0
julia_cx: .word -571
julia_cy: .word 571
julia_target: .word 1
view_step: .word 20
zy0_var: .word 0
zx_var:  .word 0
zy_var:  .word 0
zx2_var: .word 0
zy2_var: .word 0
new_zy_var: .word 0
iter_var: .word 0
fmul_sign: .word 0
xblk:    .word 0
yblk:    .word 0
fb_row:  .word 0
xpix:    .word 0
pack_word: .word 0
ticker_link: .word 0
ticker_scroll: .word 0
ticker_row: .word 0
ticker_col: .word 0
ticker_char: .word 0
ticker_lane: .word 0
ticker_word: .word 0
ticker_fb_addr: .word 0
ticker_nibble_masks:
    .word 0x000F, 0x00F0, 0x0F00, 0xF000
ticker_bit_masks:
    .byte 0x10, 0x08, 0x04, 0x02, 0x01
    .align 2
ticker_glyphs:
    ; R
    .byte 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11
    ; I
    .byte 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F
    ; S
    .byte 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E
    ; C
    .byte 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E
    ; -
    .byte 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00
    ; C
    .byte 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E
    ; space
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    ; o
    .byte 0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E
    ; n
    .byte 0x00, 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11
    ; space
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.ifdef RISCC_ATUM_A3
    ; Atum A3 Nano
    .byte 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11  ; A
    .byte 0x04, 0x04, 0x1F, 0x04, 0x04, 0x04, 0x03  ; t
    .byte 0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0D  ; u
    .byte 0x00, 0x00, 0x1A, 0x15, 0x15, 0x15, 0x15  ; m
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00  ; space
    .byte 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11  ; A
    .byte 0x1E, 0x01, 0x01, 0x0E, 0x01, 0x01, 0x1E  ; 3
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00  ; space
    .byte 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11  ; N
    .byte 0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F  ; a
    .byte 0x00, 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11  ; n
    .byte 0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E  ; o
    ; six spaces
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.else
    ; icepi-zero
    .byte 0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E  ; i
    .byte 0x00, 0x00, 0x0E, 0x10, 0x10, 0x10, 0x0E  ; c
    .byte 0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E  ; e
    .byte 0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10  ; p
    .byte 0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E  ; i
    .byte 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00  ; -
    .byte 0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F  ; z
    .byte 0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E  ; e
    .byte 0x00, 0x00, 0x16, 0x18, 0x10, 0x10, 0x10  ; r
    .byte 0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E  ; o
    ; eight spaces
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
.endif
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
    .align 2
julia_path:
    .word -571, 571
    .word -746, 309
    .word -807, 0
    .word -746, -309
    .word -571, -571
    .word -309, -746
    .word 0, -807
    .word 309, -746
    .word 571, -571
    .word 746, -309
    .word 807, 0
    .word 746, 309
    .word 571, 571
    .word 309, 746
    .word 0, 807
    .word -309, 746
rx_q:    .space 16
tx_q:    .space 64
