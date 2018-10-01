; Sigma EF protocol compatibility fix
;
; Copyright 2018 Hector Martin "marcan" <marcan@marcan.st>
;
; Permission is hereby granted, free of charge, to any person obtaining a copy
; of this software and associated documentation files (the "Software"), to deal
; in the Software without restriction, including without limitation the rights
; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
; copies of the Software, and to permit persons to whom the Software is
; furnished to do so, subject to the following conditions:
;
; The above copyright notice and this permission notice shall be included in all
; copies or substantial portions of the Software.
;
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
; SOFTWARE.

.include "tn13def.inc"

; EF protocol pins. We don't need DLC.
.equ    DCL = 0
.equ    LCLK = 1

; debugging pins
.equ    CMD = 3
.equ    AWAKE = 4

.equ    F_CPU = 9600000

.equ    ARGCTAB = FLASHEND - 0x7f

; 700µs command timeout
.equ    TIMEOUT = 700 * (F_CPU / 64) / 1000000

.cseg
.org 0
    rjmp    reset   ; cold boot
    reti            ; INT0 - just wake up from SLEEP
    nop
    rjmp    reset   ; TIM0_OVF - on timeout, reset everything (incl. SPL)

reset:
    cli
    clr r1
    ldi r18, LOW(RAMEND)
    out SPL, r18

    ldi r18, 0x18    ; CMD+AWAKE outputs
    out DDRB, r18
    ldi r18, 0xe4    ; pull-up on all unused pins
    out PORTB, r18
    sbi PORTB, AWAKE

    ; set up low level IRQ (for LCLK), but disable it for now
    ; set sleep mode to power-down
    ldi r18, (1<<SE)|(2<<SM0)
    out MCUCR, r18
    ldi r20, (1<<INT0)
    out GIMSK, r1

waitcmd:
    ; stop timer 0 and prepare to use it as a command timeout
    out TCCR0A, r1
    out TCCR0B, r1
    ldi r17, (3 << CS00)
    ldi r18, 255 - TIMEOUT
    out TCNT0, r18
    ; clear IRQ flag and enable
    out TIMSK0, r1
    ldi r18, (1 << TOV0)
    out TIFR0, r18
    ldi r18, (1 << TOIE0)
    out TIMSK0, r18

    ; ensure LCLK is high (idle)
    sbis PINB, LCLK
    rjmp PC-1

    ldi zh, HIGH(ARGCTAB<<1)
    clr zl  ; command opcode

    ; LCLK is high, wait in SLEEP mode until the next command
    cbi PORTB, AWAKE
    out GIMSK, r20 ; (1 << INT0)
    sei
    ; note that AVR guarantees forward progress even if we never clear the IRQ
    ; source in the IRQ handler. Under normal conditions, the sleep instruction
    ; should execute with no IRQ pending, then when LCLK goes low the IRQ will
    ; be triggered, be returned from left pending, and then AVR guarantees that
    ; the out following the SLEEP will be executed, which should prevent the IRQ
    ; handler from firing again. In a pathological case where LCLK goes low
    ; before the sleep instruction, the handler may be entered more than once.
    sleep
    out GIMSK, r1   ; disable INT0 IRQ
    out TCCR0B, r17 ; start Timer 0 (command timeout)
    sbi PORTB, AWAKE
    sbi PORTB, CMD

    ; bit 7
    ; wait for LCLK rising edge (sample)
    sbis PINB, LCLK
    rjmp PC-1
    sbic PINB, DCL
    sbr zl, 0x80

.macro cbit
    ; wait for LCLK falling edge (drive)
    sbic PINB, LCLK
    rjmp PC-1
    ; wait for LCLK rising edge (sample)
    sbis PINB, LCLK
    rjmp PC-1
    sbic PINB, DCL
    sbr zl, @0
.endm

    cbit 0x40
    cbit 0x20
    cbit 0x10
    cbit 0x08
    cbit 0x04
    cbit 0x02

    cpi zl, 0x12   ; Aperture command (0x12 or 0x13)
    brne passthrough

    ; Aperture command, stomp on last bit!
    ; Prepare DDRB value
    in r18, DDRB
    sbr r18, (1<<DCL)
    ; Wait for LCLK falling edge (drive)
    sbic PINB, LCLK
    rjmp PC-1
    ; Stomp
    out DDRB, r18
    ; Wait for LCLK rising edge (sample)
    sbis PINB, LCLK
    rjmp PC-1
    ; Wait a bit (~1us) before releasing
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    ; Release
    cbi DDRB, DCL

    rjmp handle_command

passthrough:
    cbit 0x01

handle_command:

    ; Wait for LCLK falling edge (ACK)
    sbic PINB, LCLK
    rjmp PC-1

    ; transfer complete, stop timer and reset
    out TCCR0B, r1
    ldi r18, 255 - TIMEOUT
    out TCNT0, r18
    cbi PORTB, CMD

    lpm r16, Z  ; get argument count

next_argument:
    tst r16
    brne have_arg
    rjmp waitcmd

have_arg:
    dec r16

    ; Wait for LCLK rising edge (end of ACK)
    sbis PINB, LCLK
    rjmp PC-1

    ; wait for LCLK falling edge (drive)
    sbic PINB, LCLK
    rjmp PC-1

    ; enable timer
    out TCCR0B, r17 ; start Timer 0 (command timeout)
    ; wait for LCLK rising edge (sample)
    sbis PINB, LCLK
    rjmp PC-1

.macro abit
    ; wait for LCLK falling edge (drive)
    sbic PINB, LCLK
    rjmp PC-1
    ; wait for LCLK rising edge (sample)
    sbis PINB, LCLK
    rjmp PC-1
.endm

    abit ; bit 6
    abit ; bit 5
    abit ; bit 4
    abit ; bit 3
    abit ; bit 2
    abit ; bit 1
    abit ; bit 0

    ; Wait for LCLK falling edge (ACK)
    sbic PINB, LCLK
    rjmp PC-1

    ; transfer complete, stop timer and reset
    out TCCR0B, r1
    ldi r18, 255 - TIMEOUT
    out TCNT0, r18

    rjmp next_argument

.if (ARGCTAB & 0x7f)
.error "ARGCTAB not aligned!"
.endif
    .org ARGCTAB
_argctab:
    ; Table of command argument counts, to maintain protocol sync
    .db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;00
    .db 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1  ;10
    .db 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1  ;20
    .db 3, 2, 1, 3, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;30
    .db 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2  ;40
    .db 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1  ;50
    .db 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 5, 1, 1, 1, 1, 1  ;60
    .db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;70
    .db 7, 3, 0, 0, 0, 0, 4, 3, 0, 0, 0, 0, 0, 0, 0, 0  ;80
    .db 1, 2, 0, 3, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;90
    .db 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;a0
    .db 2, 1, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;b0
    .db 1, 1, 3, 0, 1, 1, 0, 1, 0, 5, 5, 0, 0, 0, 0, 1  ;c0
    .db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;d0
    .db 1, 0, 0, 0, 1, 0, 0, 0, 5, 0, 5, 0, 0, 0, 0, 0  ;e0
    .db 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  ;f0
