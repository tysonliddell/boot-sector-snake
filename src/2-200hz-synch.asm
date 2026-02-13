video_buffer_segment:   equ 0xb000

    org 0x7c00
start:
    ; set up the PIT for a 200 Hz system timer (the default of 18.2 Hz is too slow)
    mov al,0x36
    out 0x42,al
    ;mov ax,11931
    mov ax,5960
    out 0x40,al
    mov al,ah
    out 0x40,al

    mov ax,0x0002   ; text mode
    int 0x10

    ; disable the cursor
    mov ah,0x01
    mov cx,0x3F00
    int 0x10

    ; switch to the text video buffer segment of memory
    mov ax,video_buffer_segment
    mov ds,ax
    mov es,ax
    xor di,di
    cld

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

    times 510-($-$$) db 0   ; pad rest of first sector with zeros
    dw 0xaa55               ; boot signature (little-endian)
