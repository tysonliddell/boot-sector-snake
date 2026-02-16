VID_BUF_SEG:            equ 0xb000
BIOS_BLANK_FILL_CHAR:   equ ' '+7*256   ; blank vid memory init char
POWERUP_CHAR:           equ '@'+7*256

    org 0x7c00
start:
    ; set up the PIT for a 200 Hz system timer (the default of 18.2 Hz is too slow)
    ;mov al,0x36
    ;out 0x43,al
    ;mov ax,5960
    ;out 0x40,al
    ;mov al,ah
    ;out 0x40,al

    ; set up TIMER 2 for a counter rollover of 25*80 so that we can use it
    ; to "randomly" generate screen positions.
    mov al,10111100b    ; TIMER 2, rate generator
    out 0x43,al
    mov ax,0x25*80
    out 0x42,al
    mov al,ah
    out 0x42,al

    mov ax,0x0002   ; text mode
    int 0x10

    ; disable the cursor
    mov ah,0x01
    mov cx,0x3F00
    int 0x10

    ; switch to the text video buffer segment of memory
    mov ax,VID_BUF_SEG
    mov ds,ax
    mov es,ax
    mov di,0x00
    mov bx,0x00
    cld

    ;mov ax,0x0305  ; minimise typematic delay (not really needed)
    ;mov bx,0x0000
    ;int 0x16

    call draw_border

    mov bx,(80*12+40)*2    ; start in middle of screen
    push bx
    call place_powerup
    pop bx

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

    push bx
    call place_powerup
    pop bx

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
    mov ax,BIOS_BLANK_FILL_CHAR  ; clear previous character
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

    call check_collision
    jnz game_over

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

;
; check_collision: Z=0 if there is a collision, Z=1 otherwise
;
check_collision:
    cmp word [bx],BIOS_BLANK_FILL_CHAR
    ret

game_over:
    mov ax,cs
    mov ds,ax
    mov si,game_over_msg

    mov ax,VID_BUF_SEG
    mov es,ax
    mov di,(80*12+35)*2
    mov cx,10

    gmvr_msg:
        movsb
        inc di          ; skip character attribute
        loop gmvr_msg

    jmp $
game_over_msg:  db "GAME OVER!",0

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

    times 510-($-$$) db 0   ; pad rest of first sector with zeros
    dw 0xaa55               ; boot signature (little-endian)
