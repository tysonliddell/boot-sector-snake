video_buffer_segment:   equ 0xb000

    org 0x7c00
start:
    ; set up the PIT for a 200 Hz system timer (the default of 18.2 Hz is too slow)
    ;mov al,0x36
    ;out 0x42,al
    ;mov ax,5960
    ;out 0x40,al
    ;mov al,ah
    ;out 0x40,al

    mov ax,0x0002   ; text mode
    int 0x10

    ; disable the cursor
    mov ah,0x01
    mov cx,0x3F00
    int 0x10

    ; switch to the text video buffer segment of memory
    mov ax,video_buffer_segment
    mov ds,ax
    mov bx,0x00
    cld

    ;mov ax,0x0305  ; minimise typematic delay (not really needed)
    ;mov bx,0x0000
    ;int 0x16

mov ch,0x00     ; y velocity
mov cl,0x01     ; x velocity
main:
    call wait_for_tick
    mov ah,0x01         ; key pressed?
    int 0x16
    jz move_forward     ; no key pressed, continue in current direction

    mov ah,0x00         ; get key
    int 0x16

    cmp ah,0x48         ; up arrow pressed?
    jnz l1
    mov ch,-0x01
    mov cl,0x00
    jmp move_forward
l1:
    cmp ah,0x4B         ; left arrow pressed?
    jnz l2
    mov ch,0x00
    mov cl,-0x01
    jmp move_forward
l2:
    cmp ah,0x4D         ; right arrow pressed?
    jnz l3
    mov ch,0x00
    mov cl,0x01
    jmp move_forward
l3:
    cmp ah,0x50         ; down arrow pressed?
    jnz l4
    mov ch,0x01
    mov cl,0x00
    jmp move_forward
l4:
    jmp move_forward

move_forward:
    mov ax,0x0000   ; clear previous character
    mov [bx],ax

    mov al,ch   ; add/sub row (*2) to bx
    cbw
    mov dx,80*2
    mul dx
    add bx,ax

    mov al,cl   ; add/sub col (*2) to bx
    cbw
    add bx,ax
    add bx,ax

    ;mov ax,0x0758   ; add next character ('X')
    mov ax,0x0701   ; add next character (smiley face)
    mov [bx],ax
    
    jmp main

wait_for_tick:
    push cx
    push dx
    mov ah,0x00     ; get current value from timer
    int 0x1a
wait_loop:
    push dx
    mov ah,0x00
    int 0x1a
    pop cx
    cmp cx,dx
    jz wait_loop
    pop dx
    pop cx
    ret

    times 510-($-$$) db 0   ; pad rest of first sector with zeros
    dw 0xaa55               ; boot signature (little-endian)
