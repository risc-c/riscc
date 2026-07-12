; Real-hardware MUL smoke test. Output at 115200 baud:
;   MUL\r\n
;   0P\r\n ... 5P\r\n
; followed by one dot per heartbeat interval. Any F or missing heartbeat
; identifies a wrong result or a stuck multiplier.

.vectors
    JMP16 start
    JMP16 start

.text
uart_putc:
    LDI16 r2, 0xFFF4
uart_wait:
    LDW   r0, [r2+0]
    ANDI  r0, 1
    BEQZ  uart_wait
    LDI16 r2, 0xFFF0
    STW   r1, [r2+0]
    RETS

; r0 = actual-expected, r1 = test digit. Clobbers r0..r3 and S6/S7.
report:
    MFS   r3, S7
    MTS   S6, r3
    MOV   r3, r0
    CALL16 uart_putc
    OR    r0, r3, r3
    BEQZ  report_pass
    LDI   r1, 'F'
    JMP8  report_mark
report_pass:
    LDI   r1, 'P'
report_mark:
    CALL16 uart_putc
    LDI   r1, 13
    CALL16 uart_putc
    LDI   r1, 10
    CALL16 uart_putc
    MFS   r3, S6
    MTS   S7, r3
    RETS

start:
    ; Leave enough time to reconnect the FT231X after JTAG programming.
    LDI16 r5, 300
startup_outer:
    LDI16 r6, 0xFFFF
startup_inner:
    ADDI  r6, -1
    CMPI  r6, 0
    BNEZ  startup_inner
    ADDI  r5, -1
    CMPI  r5, 0
    BNEZ  startup_outer

    LDI   r1, 'M'
    CALL16 uart_putc
    LDI   r1, 'U'
    CALL16 uart_putc
    LDI   r1, 'L'
    CALL16 uart_putc
    LDI   r1, 13
    CALL16 uart_putc
    LDI   r1, 10
    CALL16 uart_putc

    LDI   r2, 0
    LDI   r3, 0
    LDI   r1, '0'
    CALL16 uart_putc
    MUL   r4, r2, r3
    LDI   r3, 0
    SUB   r0, r4, r3
    LDI   r1, '0'
    CALL16 report

    LDI   r2, 1
    LDI   r3, 1
    LDI   r1, '1'
    CALL16 uart_putc
    MUL   r4, r2, r3
    LDI   r3, 1
    SUB   r0, r4, r3
    LDI   r1, '1'
    CALL16 report

    LDI16 r2, 0xFFFF
    LDI   r3, 2
    LDI   r1, '2'
    CALL16 uart_putc
    MUL   r4, r2, r3
    LDI16 r3, 0xFFFE
    SUB   r0, r4, r3
    LDI   r1, '2'
    CALL16 report

    LDI16 r2, 0x1234
    LDI16 r3, 0x5678
    LDI   r1, '3'
    CALL16 uart_putc
    MUL   r4, r2, r3
    LDI16 r3, 0x0060
    SUB   r0, r4, r3
    LDI   r1, '3'
    CALL16 report

    LDI16 r2, 0x8000
    LDI16 r3, 0x8000
    LDI   r1, '4'
    CALL16 uart_putc
    MUL   r4, r2, r3
    LDI   r3, 0
    SUB   r0, r4, r3
    LDI   r1, '4'
    CALL16 report

    LDI   r2, 255
    LDI16 r3, 0x0101
    LDI   r1, '5'
    CALL16 uart_putc
    MUL   r4, r2, r3
    LDI16 r3, 0xFFFF
    SUB   r0, r4, r3
    LDI   r1, '5'
    CALL16 report

heartbeat:
    LDI16 r2, 0xFFFF
heartbeat_delay:
    ADDI  r2, -1
    CMPI  r2, 0
    BNEZ  heartbeat_delay
    LDI   r1, '.'
    CALL16 uart_putc
    JMP8  heartbeat
