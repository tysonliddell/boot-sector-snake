# boot-sector-snake
This project is a bare-metal implementation of the classic Snake game in x86
assembly (real mode) contained entirely in the 512 byte boot sector. The
target architecture is the 16-bit 8086/8088 processor found on the original IBM
PCs.

## What makes this challenging
- Limited to a 512 byte binary.
- No access to OS services or libraries. Only minimal BIOS interrups are
  available.
- No device drivers. Every feature (graphics, timing, input, game logic) must
  be build directly on top of hardware.
- The stack needs to be managed manually.
- No heap or dynamic memory allocation.
- Potential undefined hardware states on boot (depending on the BIOS).

## Running/debugging the code
TODO

# Technical write-up
## Tools
- 86Box can be used for cycle-accurate emulation of the 8086. Since the game
  runs directly in the bootloader, we don't need to worry about sourcing an OS.
- Assembly code written in a non-frills text editor (vim).
- Bootloader assembled with `nasm -f bin <source>.asm -o <OUTNAME>.img`.
- Bootloader is turned into a bootable 160K disk image with
  `truncate -s 160K <file>`.

## Hello world
First things first. Let's start with a Hello World bootloader.

### Choosing a graphics mode
The IBM PC supports the following video cards (non-exhaustive list):
- The Monochrome Display Adaptor (MDA) for monochrome graphics. This card only
  support text graphics.
- The Color Graphics Adaptor (CGA) for color graphics. This card supports pixel
  graphics at the cost of a lower text-mode resolution.
- The aftermarket Hercules Graphics Card (HGC). This card provides the higher
  text-mode resolution of the MDA as well as support for pixel graphics found
  in the CGA. It's output is monochrome, not color.

To keep things simple and to gain an appreciation for the magic of colour
displays, we'll go with monochrome (MDA) and begin by producing a hello-world
program to run in the OS (PC-DOS). Once this is complete it will be made
bootable.

### Writing directly to hardware: memory-mapped video
The memory map for the IBM PC is as follows:

```
+--------+  0x00000
|        |  640K of base RAM
+--------+  0xA0000
|        |  EGA/VGA graphics mode
+--------+  0xB0000
|        |  Monochrome text 80x25x16 video mode
+--------+  0xB8000
|        |  Colour text mode
+--------+  0xC0000
|        |  Video card ROM and/or network cards
+--------+  0xE0000
|        |  ROM of BIOS
+--------+  0xFFFFF
```

The 8086 uses 16-bit registers, but can address a 20-bit address space by
changing the value of the segment registers:

```
physical address = segment*16 + offset
```

This allows for addressing up to 1MB of physical memory. As a consequence,
modern x86s are constrained to 1MB of memory when operating in real mode. No
memory is protected in the 8086 or in real mode. That is, we have direct access
to the raw memory addresses as they are laid out in physical hardware. To work
with memory mapped monochrome text video the `0x10` BIOS interrupt is used to
switch to the memory-mapped video mode and characters are then rendered by
writing to video memory.

#### Discovering hardware behavior by accident: Blinking characters
The program below was written to try and paint the screen with 'X' characters
with a black foreground and black background.

```
COLS:   equ 80
ROWS:   equ 25

    org 0x100
start:
    mov ax,0x0002   ; text mode
    int 0x10

    mov ax,0xb000   ; switch segment to text video buffer
    mov ds,ax
    mov es,ax

    mov cx,COLS*ROWS
    mov bx,0
lp:
    mov word [bx],0xF058  ; an X
    inc bx  ; words are 2 bytes wide
    inc bx
    loop lp

forever:
    jmp forever

    int 0x20
```

It almost worked, but resulted in some [unexpected strobing][weird-strobing].
The text appears amber because that his how the monochrome monitor is
configured. Amber is this monitor's white colour. However, as seem in the
image, the characters are blinking at around the same frequency as the cursor
does on boot.

Blitting the characters to [half of the screen][weird-strobing-2] shows that
it's only the characters that are being printed that are effected, so it wasn't
a video issue. The blinking reveals something important: the attribute byte is
interpreted differently by the MDA.

For a colour screen, each character is represented by a 16-bit word:

```
+-----------------------------------------------------------------+
| 4 bits (bg colour) | 4 bits (fg colour) | 8 bit ASCII character |
+-----------------------------------------------------------------+
```

Using `0xF058` I expected a "bright white" background colour, black foreground
colour and the character 'X'. But, thinking a bit more about it, given that the
output is going to the monchrome display adaptor, how is the encoding above
interpreted? It doesn't have colours! Perhaps the blinking effect observed
above was due to stumbling onto the encoding for a blinking character in
monochrome mode. Iterating through the first 80*25 = 200 "colour" encodings
[confirms this hypothesis][strobing-solved]. Some of the characters blink and
some do not. [Here][strobing-solved-bw] is the output of same code running on a
system using a black-and-white monitor for clarity.

The IBM PC Technical Reference manual confirms that the character attribute
(first 8 bits) of the 16-bit word is configured as follows for the monochrome
display adaptor:

- Bit 7: blink
- Bits 6-4: 000 = black background, 111 = white background
- Bit 3: Intensity
- Bits 2-0: 000 = black foreground, 111 = white foreground

The bits can also be set to `X000X001` to underline a character. From what I
can gather from the manual, using any other combination may not be defined for
a monochrome display adaptor. Since `BX` always contains an even numbered
address in the example above, no underlined characters are seen in the output.

#### Dealing with the cursor
[This is what results][underlines] when blitting the screen with a bunch
underlined 'X's. Notice the [small blinking cursor][cursor-zoom] on the top
row. After some trial and error I found that the cursor needs to be disabled
with a bios interrupt (AFTER entering the text video mode!):

```
    ; disable the cursor
    mov ah,0x01
    mov cx,0x3F00
    int 0x10
```

#### Hello, world!
Putting it all together into a ["Hello, world!" program][hello-code]
demonstrates the effect of the intensity bit, setting the "colour" bits for
underline and the blink bit.

![hello world][hello]

Success! But this program runs in the OS. We want it to run *instead* of the
operating system. When loading a COM program, DOS maintains the program segment
prefix (PSP) data structure at physical address `0x00`, which contains the
state of the running program for the OS. The COM binary is loaded into memory
immediatly after the PSP at address `0x100` and program execution starts
following a jump to that location. This is why the `org 0x100` assembly
directive is needed for COM programs. To have a program start at boot instead,
without running the OS, the boot process needs to be understood.

### PC Boot process
1. On power on/reset the processesor jumps immediately to address `0xFFFF0`
   (`FFFF:0000` using `CS:IP` notation). As shown in the memory map above,
   this is somewhere in the BIOS ROM.
2. Since this is right near the end of memory, the BIOS will contain a jump
   instruction to move execution to somewhere else in the ROM containing the
   logic to perform start-up checks and set things up for the boot program to
   run.
3. After setting the system up for boot the BIOS checks if the floppy drive is
   bootable. I.e. are the last two bytes of the first sector of the disk `0x55`
   followed by `0xAA` (equivalently the word `0xAA55` in x86 little-endian). If
   the disk is bootable the first sector (512 bytes) is loaded into address
   `0000:7C00`, the code segment (`CS`) is set to `0x0000` and the CPU jumps to
   instruction `0x7C00`. Note that the other segment registers DS/ES/SS/SP may
   not be defined and should be set up by the boot program.

```
power -> BIOS -> boot sector -> our code
```

Why are boot programs loaded at address `0x7C00`? It was selected by IBM so
that the boot sector does not trash the area of RAM used by the BIOS. On boot
the BIOS places the interrupt vector table, BIOS data area and BIOS
workspace/stack in the (absolute) address range `0x0000 - 0x7BFF`.

```
+--------+  0x00000
|        |  Interrupt vector table (IVT) (1 KB)
+--------+  0x00400
|        |  BIOS data area (BDA) (256 B)
+--------+  0x00500
|        |  BIOS workspace/stack (~30 KB)
+--------+  0x07C00
|        |  Free memory
+--------+  0xA0000
|        |  Hardware/BIOS ROM
+--------+  0xFFFFF
```

#### Booting hello world
The following steps will result in a self-booting program:
0. Make sure the machine has enough RAM to boot. The BIOS already takes up
   ~32 KB, so if the program needs to use a non-trivial amount of ram, a 48 KB+
   machine is needed.
1. Add the `org 0x7C00` to the program.
2. Make sure the program is exactly 512 bytes long with the last two bytes
   containing the boot signature.
3. Don't use any OS services like `int 0x20` (BIOS services are ok to use).

Therefore, the hello world program above is [made bootable][hello-code-boot]
with the following changes:

```diff
@@ -2,7 +2,7 @@ video_buffer_segment:   equ 0xb000
 width:                  equ 80
 message_row:            equ 5
 message_margin:         equ 15
-    org 0x100
+    org 0x7c00
 
 start:
     mov ax,0x0002   ; text mode
@@ -51,3 +51,6 @@ start:
 
 forever:
     jmp forever
+
+    times 510-($-$$) db 0   ; pad rest of first sector with zeros
+    dw 0xaa55               ; boot signature (little-endian)
```

Since the boot sector of a floppy disk occurs at the very first 512 bytes, no
filesystem information (FAT table) is needed. Creating a bootable image for a
160K floppy for 86Box is as simple as writing the assembled 512 bytes to a file
and padding the rest of the file up to 160K:

```
truncate -s 160K hello-boot.img
```

### What we have achieved
This results in the hello world program running successfully on boot. The code
runs without the support of a runtime, libraries or kernel. We satisfied the
BIOS boot protocol, interfaced directly with the hardware through memory mapped
video (no device driver), and worked with real mode addressing.

## Creating a synchronised game loop
With "Hello, world!" out of the way, work begins on the game. Let's start with
a simple game loop incrementally prints characters to the screen. No keyboard
input or game logic yet.

To control the FPS of the output the `int 0x1a` BIOS interrupt is used to read
the real-time clock. The value of this counter increases at a rate of `18.2
Hz` by default. The following code will demonstrate the max speed the snake
could move under this configuration.

```
main_loop:
    mov ax,0x0000   ; Remove the previous `X` from the display
    stosw
    mov ax,0x0758   ; Write a new `X` to the display
    mov word [di],0x0758

    call wait_for_tick
    jmp main_loop

    ; keep polling the timer until it changes (ticks)
wait_for_tick:
    mov ah,0x00     ; get current value from 18.2 Hz timer
    int 0x1a
wait_loop:
    push dx
    mov ah,0x00
    int 0x1a
    pop cx
    cmp cx,dx
    jz wait_loop
    ret
```

This renders the following:

<img src="./misc/assets/timer-interrupt-default.gif" alt="slow snake" width="500"/>

This isn't fast enough for the higher levels of a game of snake. One way around
this would be to have the snake jump multiple spaces on a single game tick, but
a better solution is to speed up the rate at which the clock is updated.

### The Programmable Interval Timer (PIT)
In the assembly above, the BIOS system-timer clock service is used to poll the
value of the system-timer time counter.

```
    mov ah,0x00     ; get current value of the system-timer counter
    int 0x1a        ; and store the result in CX:DX
```

We're not stuck with the default 18.2 Hz update frequency of this counter. We
can reprogram the PIT to speed it up. The CPU runs at a frequency of 4.77 MHz,
which is reduced to 1.19 MHz by a hardware frequency divider. This lower
frequency is fed to a 16-bit counter that starts at value RELOAD_VALUE and is
decremented on each falling edge. When the counter gets to 0 it outputs the
next "tick" for the system-timer time counter.

```
4.77 MHz ---freq-divider---> 1.19 MHz --->counter---> (1193182 / reload_value) Hz ---> [system-timer counter]
```

The RELOAD_VALUE is set the 0xFFFF on boot, which results in a system-timer
frequency of `1193182 / 65535 = 18.2 Hz`. The PIT can be configured and the
RELOAD_VALUE changed by writing to the appropriate PIT I/O ports.

```
    ; set up the PIT for a 200 Hz system timer
    ;   00111100 = 0x36
        |||||||^---------16-bit binary mode (not BCD)
        ||||^^^----------rate generator mode
        ||^^-------------access mode hibyte/lobyte
        ^^---------------channel 0
    mov al,0x36
    out 0x42,al

    mov ax,5960     ; 1193182 / 5960 = 200 Hz
    out 0x40,al
    mov al,ah
    out 0x40,al
```

This results in a snake with a much higher top speed.

<img src="./misc/assets/timer-interrupt-200hz.gif" alt="slow snake" width="500"/>

This is will be used as the basis for the sychronised game loop.

## Reading keyboard input
The next step is to move the 'X' around the screen in response to keyboard
input.



## How input works
TODO
## Debugging challenges
TODO
## Surprises
TODO

## Useful links:
- https://wiki.osdev.org/Programmable_Interval_Timer

[weird-strobing]: ./misc/assets/video-mode-mystery1.gif
[weird-strobing-2]: ./misc/assets/video-mode-mystery2.gif
[strobing-solved]: ./misc/assets/video-mode-solved.gif
[strobing-solved-bw]: ./misc/assets/video-mode-solved-bw.gif
[underlines]: ./misc/assets/video-mode-underlined.gif
[cursor-zoom]: ./misc/assets/video-mode-cursor-zoom.gif
[hello]: ./misc/assets/video-mode-hello.gif
[hello-code]: ./src/hello.asm
[hello-code-boot]: ./src/hello-boot.asm
