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
- [Tools](#tools)
- [Hello world](#hello-world)
- [Creating a synchronised game loop](#creating-a-synchronised-game-loop)
- [Reading keyboard input](#reading-keyboard-input)

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
prefix (PSP) data structure at (relative) address `0x00`, which contains the
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

1. Make sure the machine has enough RAM to boot. The BIOS already takes up
   ~32 KB, so if the program needs to use a non-trivial amount of ram, a 48 KB+
   machine is needed.
2. Add the `org 0x7C00` directive to the program.
3. Make sure the program is exactly 512 bytes long with the last two bytes
   containing the boot signature.
4. Don't use any OS services like `int 0x20` (BIOS services are ok to use).

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
a simple game loop that incrementally prints characters to the screen. No
keyboard input or game logic yet.

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
    ;   |||||||^---------16-bit binary mode (not BCD)
    ;   ||||^^^----------rate generator mode
    ;   ||^^-------------access mode hibyte/lobyte
    ;   ^^---------------channel 0
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

*Cumulative byte count: 68/512*

## Reading keyboard input
### Attempt 1: Going through the BIOS
The next step is to move a character around the screen in response to keyboard
input.

The BIOS manages a buffer in memory that stores each key press and provides a
service to obtain key presses (`INT 0x16`);
```
    mov ah,0x00 ; blocking read for next key press, removes key from buffer
    int 0x16

    mov ah,0x01 ; non-blocking read for next key press, does not remove key from buffer
    int 0x16
```

Both of the BIOS functions above will store a key scancode in `AH` and the
corresponding ASCII character in `AL`. The scancodes of interest are:


| code | key                    |
| ---- | ---------------------- |
| 0x48 | Up key pressed down    |
| 0x4B | Left Key pressed down  |
| 0x4D | Right key pressed down |
| 0x50 | Down key pressed down  |

The non-blocking read sets the Z flag when no key is available and clears it if
it detected a key press.

Initially, I tried using the following logic to display an 'X' on the screen
while any key was being held down, but it didn't work as expected. The screen
stayed blank.

```
mov cx,0x0000
print_key:
    mov [bx],cx
    mov ah,0x01     ; check if a key is pressed (non-blocking)
    int 0x16

    mov cx,0x0000   ; clear displayed character
    jz print_key    ; no key pressed

    mov ah,0x00     ; clear key buffer
    int 0x16

    mov cx,0x0758   ; 'X'
    jmp print_key
```

This was caused by the result coming from the `AH = 0x01, INT 0x16` being
throttled while a key is held down, resulting in an indication of no key press
most of the time and thus no character visible on the screen. The keybord
repeat rate, managed by the keyboard firmware and configurable through the
BIOS, is the cause of this behaviour. The repeat rate can be made as short as
possible like this:

```
mov ax,0x0305
mov bx,0x0000
int 0x16
```

This will set the repeat delay and typematic rate to their fastest values of
250ms and 30 Hz respectively. After banging my head against the wall for a
while, I realised that to make this have any effect in 86Box, I also need to
adjust the typematic rate on my host linux machine like this:

```
xset r rate 200 40
```

However, even with the repeat delay minimised and the typematic rate maximised,
it is still not responsive enough for some games and in my case the screen
remained black, save for the occaisonal shortlived flicker of a value on the
screen. To get around this limitation we need to go around the BIOS and
interact with the keyboard hardware directly.

### Attempt 2: Reading directly from keyboard hardware
It's not necessary to do anything about the typematic rate and repeat delay for
this simple boot sector game, but as a learning experience I wanted to read the
keyboard directly from the hardware and try and solve the problem above. It
turned out this was non-trivial:

- The keyboard hardware contains a 8048 microcontroller that is responsible for
  generating scancodes, key debouncing and buffering up to 20 keys scancodes.
- The 8048 communicates with the 8255A PPI (programmable peripheral interface),
  which is a general I/O controller for the PC. The cassette and speaker also
  connect to the PPI.
- The 8048 is also connected to the 8259A Programmable Interrupt Controller
  (PIC). This device receives interrupts from the hardware, prioritises them,
  and sends them on to the CPU.

Here's the rough idea:
```
key pressed -> [8048 keyboard] -----------scancode----------> [8255A PPI]
                     |                                            ^
                     |                                            |
                     |                                            |
                     `--> IRQ1 --> [8259A PIC] --interrupt--> [8088 CPU]
```

Keyboard interrupt requests are received by the PIC on IRQ1 which are mapped to
interrupt vector 9, since the BIOS configures the PIC with a vector offset of 8
when setting it up. See the ICW2 (Initialization Command Word 2) config in the
IBM PC BIOS listing below:

```
;--------------------------------------------
;	INITIALIZE THE 8259 INTERRUPT CONTROLLER CHIP
;--------------------------------------------
C21:
	MOV	AL,13H              ;ICW1 - EDGE, SNGL, ICW4
	OUT	INTA00,AL
	MOV	AL,8                ;SETUP ICW2 - INT TYPE 8 (8-F)
	OUT	INTA01,AL
	MOV	AL,9                ;SETUP ICW4 - BUFFRD,8086 MODE
	OUT	INTA01,AL
	SUB	AX,AX               ;POINT DS AND ES TO BEGIN
	MOV	ES,AX               ; OF R/W STORAGE
	MOV	SI,DATA             ;POINT DS TO DATA SEG
	MOV	DS,SI               ;
	MOV	RESET_FLAG,BX       ;RESTORE RESET_FLAG
	CMP	RESET_FLAG,1234H    ;RESET_FLAG SET?
	JE	C25                 ;YES - SKIP STG TEST
	MOV	DS,AX               ;POINT DS TO 1ST 16K OF STG
```

On power up the BIOS sets up a keyboard interrupt handler for these keyboard
events at vector 9 in the 8086 interrupt vector table. For my experiment, I
wanted to go around the BIOS and poll for keyboard events myself. This would
mean:

- disabling the interrupts being emitted by the PIC so that no interrupt
  routine is triggered in the BIOS,
- putting the PIC in *poll mode* and polling it for the IRQ1 signal,
- reading the keyboard scancodes from the PPI and signalling to it that keys
  have been processed successfully to flush its internal buffer, and
- resetting the PIC so that it's ready for the next interrupt.

I made an attempt at this, but it added quite a lot of code to the already
space-constrained boot sector binary and I got a bit lost in the weeds trying
to get it working correctly. I read through the BIOS source listing in the 5150
technical reference to see how it does things, but it wasn't much help as it
doesn't use the PIC in polling mode. Given that this isn't something that is
needed to complete the snake game I'm going to pause this investigation for
now. However, I would like to complete this as a follow-up exercise because
it's really interesting.

### Keyboard handling decision: simplicity wins
For simplicity and to preserve space in the boot sector, keyboard import will
be read using the BIOS keyboard service. The limitations described in the above
sections are not a problem for this game since we are only interested in
processing changes in direction rather than indicating in real-time which key
is currently being held down/released. Following this approach gives the
following result (source code [here][keyboard-code]):

<img src="./misc/assets/keyboard-input.gif" alt="responding to keyboard" width="500"/>

*Cumulative byte count: 135/512*

## Adding boundaries
### Drawing a border
Next some boundaries are added to the game. Hitting one should result in a
game-over message. First a boundary is drawn around the screen, which is
straightforward at this point:

```
draw_border:
    mov ax,0x0Fdb       ; solid block character in PC-850 charset
    mov cx,80
    rep stosw

    mov di,80*24*2
    mov cx,80
    rep stosw

    mov bx,0x00
    mov cx,25
col_loop:
    mov [bx],ax
    add bx,79*2
    mov [bx],ax
    add bx,2
    loop col_loop
    ret
```

### Adding collision detection
The video memory is used to check for collisions. The simplest way
to do this is to check if the next square that snake is about to move onto is
blank. But what does blank mean? I initially guessed that each 16-bit word in
video memory was initialised to `0x0000`. This does result in blank characters,
but my collision detection didn't work. In the BIOS listing we find that the
screen is blanked with the `0x0720` character (`' '` char with standard
monochrome character attribute):

```
;------ FILL REGEN AREA WITH BLANK

	XOR	DI,DI		; SET UP POINTER FOR REGEN
	MOV	CRT_START,DI	; START ADDRESS SAVED IN GLOBAL
	MOV	ACTIVE_PAGE,0	; SET PAGE VALUE
	MOV	CX,8192 	; NUMBER OF WORDS IN COLOR CARD
	CMP	AH,4		; TEST FOR GRAPHICS
	JC	M12		; NO_GRAPHICS_INIT
	CMP	AH,7		; TEST FOR BW CARD
	JE	M11		; BW_CARD_INIT
	XOR	AX,AX		; FILL FOR GRAPHICS MODE
	JMP	SHORT M13	; CLEAR_BUFFER
M11:				; BW_CARD_INIT
	MOV	CX,2048 	; BUFFER SIZE ON BW CARD
M12:				; NO_GRAPHICS_INIT
	MOV	AX,' '+7*256    ; FILL CHAR FOR ALPHA
M13:				; CLEAR BUFFER
	REP	STOSW		; FILL THE REGEN BUFFER WITH BLANKS
```

With this correction in place we arrive at the following collision detection
logic, which will also work later to detect self-collisions with the snake:

```
BIOS_BLANK_FILL_CHAR:   equ ' '+7*256   ; blank vid memory init char

;
; check_collision: Z=0 if there is a collision, Z=1 otherwise
;
check_collision:
    cmp word [bx],BIOS_BLANK_FILL_CHAR
    ret
```

### Gameover message
Adding a game over message on collision gives the finishing touch:

<img src="./misc/assets/boundaries.gif" alt="running into a boundary" width="500"/>

*Cumulative byte count: 226/512*

## Adding randomly placed power-ups
Next we add randomly places power-ups on the board for the snake to eat. Eating
them has no effect yet.

Experimentation revealed that using the time reported from the BIOS on `INT
0x1A` through TIMER 0 (channel 0) of the PIT does not produce much randomness
at all, even with the increase from 18.2 Hz to 200 Hz. The first spawned
powerup was always starting near the same place (top left corner) of screen.
The reason for this is the timer managed by the BIOS has been divided down from
1.19 Mhz to 18.2 Hz. However, as described earlier, the internal counter of the
PIT is always running at 1.19 MHz. Therefore, sampling the PIT's internal
counter instead of the BIOS managed timer value provides a value that changes
at 1.19 Mhz no matter what rollover (reload value) is configured.

In fact, according to the [8253 PIT data sheet][pit-datasheet] there are a
total of 3 identical timer blocks available. The 5150 Technical Reference
confirms that TIMER 0 is used for the main PC "clock" timer, TIMER 1 refreshes
the DRAM, and TIMER 2 is used for the PC speaker and cassette.

In order to generate psudorandom numbers that fit neatly into the `25*80` range
of the screen's character positions we can configure the TIMER 2 internal
counter to rollover at 25*80 and run it without interrupts, simplifying the
logic to obtain a suitable random number.

```
    ; set up TIMER 2 for a counter rollover of 25*80 so that we can use it
    ; to "randomly" generate screen positions.
    mov al,10111100b    ; TIMER 2, rate generator
    ;      |||||||^---------16-bit binary mode (not BCD)
    ;      ||||^^^----------rate generator mode
    ;      ||^^-------------access mode hibyte/lobyte
    ;      ^^---------------TIMER 2
    out 0x43,al

    mov ax,0x25*80      ; set counter rollover value to 25*80
    out 0x42,al
    mov al,ah
    out 0x42,al
```

A random power-up is then placed on the screen by checking the PIT TIMER 2
internal counter value directly (without going through the BIOS), grabbing more
values if needed until we have one that doesn't collide with something already
on the screen.

```
place_powerup:
    call random_pos
    mov bx,ax
    cmp word [bx],BIOS_BLANK_FILL_CHAR
    jnz place_powerup                   ; find another location

    mov word [bx], POWERUP_CHAR
    ret

;
; random_pos: returns a random screen position in AX
;
random_pos:
    mov ax,10000000b    ; read TIMER 2 counter value from PIT in latched mode
    out 0x43,ax
    in al,0x42
    mov ah,al
    in al,0x42
    xchg al,ah

    shl ax,1        ; video locations are 16 bits wide
    ret
```

Adding some calls to the `place_powerup` subroutine each time the up arrow is
pressed demonstrates that this works pretty well.

<img src="./misc/assets/random-powerups.gif" alt="running into a boundary" width="500"/>

*Cumulative byte count: 281/512*


## Making the snake grow
Next we add the logic the make the snake grow when eating a power-up.

## Extras
- Adding sound
- Adusting the speed
- Adding a score

## Surprises
TODO
## Follow-up
- Experiment with disabling servicing of IRQ1 in the PIC and handle keyboard
  events by polling.

## Useful links:
- https://www.ctyme.com/intr/int.htm
- https://github.com/philspil66/IBM-PC-BIOS
- https://wiki.osdev.org/Programmable_Interval_Timer
- https://cpcwiki.eu/imgs/e/e3/8253.pdf
- https://wiki.osdev.org/I8042_PS/2_Controller
- https://wiki.osdev.org/8259_PIC
- https://pdos.csail.mit.edu/6.828/2017/readings/hardware/8259A.pdf
- http://aturing.umcs.maine.edu/~meadow/courses/cos335/Intel8255A.pdf
- http://lh.ece.dal.ca/csteaching/pcdev.html

[weird-strobing]: ./misc/assets/video-mode-mystery1.gif
[weird-strobing-2]: ./misc/assets/video-mode-mystery2.gif
[strobing-solved]: ./misc/assets/video-mode-solved.gif
[strobing-solved-bw]: ./misc/assets/video-mode-solved-bw.gif
[underlines]: ./misc/assets/video-mode-underlined.gif
[cursor-zoom]: ./misc/assets/video-mode-cursor-zoom.gif
[hello]: ./misc/assets/video-mode-hello.gif
[hello-code]: ./src/hello.asm
[hello-code-boot]: ./src/hello-boot.asm
[ps2-keyboard]: https://wiki.osdev.org/I8042_PS/2_Controller
[keyboard-code]: ./src/3-keyboard.asm
[pit-datasheet]: https://cpcwiki.eu/imgs/e/e3/8253.pdf
