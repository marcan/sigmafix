# DIY Sigma Canon AF lens compatibility fix ("rechip")

Older Sigma lenses with Canon EF lens mounts do not work on newer Canon bodies,
because Sigma incompletely reverse engineered the EF protocol and did not
implement all required commands. This is a DIY fix using an ATtiny13
microcontroller to modify the protocol, making the lens compatible again.

Some people like to call this a "rechip", but that really refers to official
fixes that involve replacing the chips in the lens. Since this fix is an add-on
instead and does not replace the existing chips in the lens, it should be more
properly called a "modchip".

## Features

* **Low power**: this fix consumes about 500µA in active mode (e.g. when
shooting, autofocusing, in Live View mode, or changing lens settings) and less
than 1µA in sleep mode (automatically entered after a few seconds of inactivity
when in standard mode, or when the camera is off). Thus, it will have no
measurable impact on battery life.

* **Passive**: instead of routing the DCL line through the MCU like other
implementations, this one uses a resistor and only actively overrides DCL where
necessary. Therefore, it has zero impact in the normal operation of the protocol
and only changes the one bit that needs changing.

* **Robust EF protocol**: unlike other versions, this one properly parses the EF
protocol and keeps track of command lengths. It also has a time-out to re-sync
with the command stream if something goes wrong.

## Programming

Type `make` to build the project (requires the avra assembler), or `make flash`
to flash it with avrdude (defaults to the `usbtiny` programmer, but you can
use `make PROGRAMMER=foo` to change the programmer type). Don't forget to flash
the fuses too if you use another programming method (`LFUSE=0x72 HFUSE=0xfb`).

## Installation

To use it, you need to cut the DCL line from the camera to the lens and insert
a 220Ω resistor in line, then attach the programmed ATtiny13 as follows:

```
                                   Camera side
                    =========================================
                    DGND  LCLK  DLC  DCL  VDD  PGND/DET  VBAT
                     |     |     |    |    |      |       |
      ATtiny13    ,------------------------+      |       |
     __________   |  |     |     |    |    |      |       |
    |o         |  |  |     |     |    \    |      |       |
   1|RESET  VCC|8-'  |     |     | 220/    |      |       |
   2|PB3    PB2|7    |     |     |  Ω \    |      |       |
   3|PB4    PB1|6----------+     |    /    |      |       |
 ,-4|GND    PB0|5---------------------+    |      |       |
 |  |__________|     |     |     |    |    |      |       |
 `-------------------+     |     |    |    |      |       |
                     |     |     |    |    |      |       |
                    DGND  LCLK  DLC  DCL  VDD  PGND/DET  VBAT
                    =========================================
                                    Lens side
```

## The problem

Canon EF lenses accept both commands `12 YY` and `13 YY` to change the aperture
by `YY` steps (signed uint8). Older Canon bodies used `12 YY`, while newer ones
use `13 YY`. It seems Sigma did not completely reverse engineer the protocol
by trying all possible commands, but merely implemented the commands used by
Canon bodies at the time. Therefore, older Sigma lenses only supported `12 YY`.
If such a lens is used on a newer body, the aperture will never move. There is
one bit of feedback from the aperture to the camera: whether it is at the fully
open position or not. The camera checks this bit against where it expects the
aperture to be. Therefore, these older lenses behave as follows: if the aperture
is wide open (the common case), the lens will only shoot with the camera
aperture set to fully open (matching), otherwise the camera will throw an
error. If the aperture is not wide open (e.g. it was manually moved or the lens
was removed while stopped down), then the camera will allow photos with other
aperture settings, but the aperture will of course not move either.

## The solution

Patch command `13` into command `12`. This is a single bit difference. Since
the protocol is MSB first, this can be done as soon as all 7 previous bits are
received, which means there is no need to delay or buffer the protocol, but it
can be done "live".

## How it works

The code spends most of its time in sleep (power down) mode. When LCLK goes low
(at the start of a command), it wakes up the chip via the low-level INT0
interrupt. The interrupt handler does nothing, but merely returns from the
power-down mode. The main program then disables the interrupt to prevent it from
re-firing, and receives the command byte. The wake-up latency is such that the
chip is ready to sample the first command bit just about exactly when LCLK is
going high, which is the expected sample timing.

After receiving 7 command bits, the code checks for command 0x12/0x13. If the
command matches, it waits for the next bit period, then forces DCL low. This
rewrites any 0x13 commands into 0x12. It then waits for the lens to ACK the
command via an LCLK pulse.

Since commands can have arguments, and there is no explicit framing to
differentiate the arguments from commands, the code contains a table of all
256 possible commands along with expected argument lengths (checked against a
Canon lens). If there are any argument bytes, it reads those bytes without
performing any further processing, before going back to sleep mode waiting for
the next command.

To implement time-outs in case something goes wrong, Timer 0 is set up with a
~700µs time-out and started at the beginning of each command, with its interrupt
enabled. It is only stopped when the lens ACKs a command. If the timer expires,
it fires an interrupt which does not return, but rather restarts the entire
program from the reset vector. This is similar behavior to Canon lenses, which
will initiate a protocol reset if a command byte takes longer than 700µs.

See [this gist](https://gist.github.com/marcan/858c242db2fc595da1e0bb70a05192fc)
for more details about the Canon EF protocol.
