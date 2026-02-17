VID_BUF_SEG:            equ 0xb000
BIOS_BLANK_FILL_CHAR:   equ ' '+7*256       ; blank vid memory init char
POWERUP_CHAR:           equ '@'+7*256

SNAKE_HEAD_CHAR:        equ 0x01            ; smiley face
SNAKE_BODY_CHAR:        equ 0xE9            ; theta character
SNAKE_START_POS:        equ (80*12+40)*2    ; start in middle of screen

UP_DIR:                 equ 0x02    ; encodings that can be applied to a
LEFT_DIR:               equ 0x03    ; character attribute without missing up
RIGHT_DIR:              equ 0x04    ; the MDA display
DOWN_DIR:               equ 0x05

WHTFG_BLKBG:            equ 0x07    ; white fg with black bg char attribute

; use the 96 bytes of "off-screen" video memory for general storage
; this simplifies working with segmented memory
SNAKE_HEAD_POS:         equ 25*80*2
SNAKE_TAIL_POS:         equ SNAKE_HEAD_POS+2
SNAKE_LENGTH:           equ SNAKE_HEAD_POS+4

    org 0x7c00
start:
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
    mov si,0x00
    mov di,0x00

    cld     ; all memory operations are in the forward direction

    ; init snake of length 3
    mov word [SNAKE_HEAD_POS],SNAKE_START_POS

    mov ax,SNAKE_HEAD_CHAR+RIGHT_DIR*256    ; snake starts moving to the right
    mov [SNAKE_START_POS],ax

    mov ax,SNAKE_BODY_CHAR+RIGHT_DIR*256
    mov [SNAKE_START_POS-2],ax
    mov [SNAKE_START_POS-4],ax
    mov word [SNAKE_LENGTH],3

    mov word [SNAKE_TAIL_POS],SNAKE_START_POS-4

    call draw_border
    call place_powerup

main:
    call wait_for_tick
    call move_tail
    call move_head
    jmp main

move_tail:
    mov di,[SNAKE_TAIL_POS]
    mov cx,[di]
    mov ax,di

    cmp ch,RIGHT_DIR
    jnz tail2
    add ax,2
    jmp tail_end
tail2:
    cmp ch,UP_DIR
    jnz tail3
    sub ax,80*2
    jmp tail_end
tail3:
    cmp ch,DOWN_DIR
    jnz tail4
    add ax,80*2
    jmp tail_end
tail4:          ; must be LEFT_DIR
    sub ax,2
tail_end:
    mov [SNAKE_TAIL_POS],ax
    mov word [di],BIOS_BLANK_FILL_CHAR  ; clear previous character
    ret

move_head:
    mov ah,0x01         ; key pressed?
    int 0x16
    jz l4               ; no key pressed, continue in current direction

    mov ah,0x00         ; get key
    int 0x16

    cmp ah,0x48         ; up arrow pressed?
    jnz l1
    mov cx,UP_DIR
    jmp move_forward
l1:
    cmp ah,0x4B         ; left arrow pressed?
    jnz l2
    mov cx,LEFT_DIR
    jmp move_forward
l2:
    cmp ah,0x4D         ; right arrow pressed?
    jnz l3
    mov cx,RIGHT_DIR
    jmp move_forward
l3:
    cmp ah,0x50         ; down arrow pressed?
    jnz l4
    mov cx,DOWN_DIR
    jmp move_forward
l4:
    mov di,[SNAKE_HEAD_POS]     ; no arrow pressed
    mov cl,[di+1]               ; curr dir hidden in snake head vid mem
    xor ch,ch
    jmp move_forward

move_forward:
    mov bx,[SNAKE_HEAD_POS]
    push bx

    mov di, DIR_TABLE
    add di,cx               ; cx has dir encoding which indexes into table
    cs mov byte al,[di]
    cbw
    shl ax,1                ; double offset for 16-bit video memory
    add bx,ax               ; BX is position of new head

    call check_collision
    jnz game_over

    mov [SNAKE_HEAD_POS],bx     ; set new head position
    xchg ch,cl
    mov cl,SNAKE_HEAD_CHAR
    mov [bx],cx

    pop bx                      ; update old head
    mov cl,SNAKE_BODY_CHAR
    mov [bx],cx
    ret

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

    mov di,0x00
    mov cx,25
col_loop:
    mov [di],ax
    add di,79*2
    mov [di],ax
    add di,2
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

DIR_TABLE:
    db 0,0,-80,-1,1,80  ; up, left; right, down

    times 510-($-$$) db 0   ; pad rest of first sector with zeros
    dw 0xaa55               ; boot signature (little-endian)
