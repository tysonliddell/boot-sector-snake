VID_BUF_SEG:            equ 0xb000
BIOS_BLANK_FILL_CHAR:   equ ' '+7*256       ; blank vid memory init char
POWERUP_CHAR:           equ '@'+7*256
SCORE_POS               equ (80-4)*2

SNAKE_HEAD_CHAR:        equ 0x01            ; smiley face
SNAKE_BODY_CHAR:        equ 0xE9            ; theta character
SNAKE_START_POS:        equ (80*12+40)*2    ; start in middle of screen

UP_DIR:                 equ 0x02    ; encodings that can be applied to a
LEFT_DIR:               equ 0x03    ; character attribute without missing up
RIGHT_DIR:              equ 0x04    ; the MDA display
DOWN_DIR:               equ 0x05

WHTFG_BLKBG:            equ 0x07    ; white fg with black bg char attribute
BLKFG_WHTBG:            equ 0x70    ; white fg with black bg char attribute

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
    mov ax,25*80-1      ; counter value can include its upper bound
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

    mov word [SNAKE_TAIL_POS],SNAKE_START_POS-4
    mov word [SNAKE_LENGTH],3-1     ; will be incremented to 3 shortly

    call draw_border
    call place_powerup
    jmp inc_score_then_main

main:
    call wait_for_tick
    call grow_head
    jz inc_score_then_main      ; powerup consumed, no need to shrink tail
    call shrink_tail
    jmp main

inc_score_then_main:
    mov ax,[SNAKE_LENGTH]
    inc ax
    mov [SNAKE_LENGTH],ax
    mov dx,0
    mov bx,1000
    div bx
    add al,'0'
    mov ah,BLKFG_WHTBG
    mov [SCORE_POS],ax

    mov ax,dx
    mov dx,0
    mov bx,100
    div bx
    add al,'0'
    mov ah,BLKFG_WHTBG
    mov [SCORE_POS+2],ax

    mov ax,dx
    mov dx,0
    mov bx,10
    div bx
    add al,'0'
    mov ah,BLKFG_WHTBG
    mov [SCORE_POS+4],ax

    add dl,'0'
    mov dh,BLKFG_WHTBG
    mov [SCORE_POS+6],dx
    jmp main

shrink_tail:
    mov bx,[SNAKE_TAIL_POS]
    push bx

    mov al,[bx+1]           ; get DIR enum from position
    xor ah,ah
    call next_position      ; make BX position of new tail

    mov [SNAKE_TAIL_POS],bx
    pop bx
    mov word [bx],BIOS_BLANK_FILL_CHAR  ; clear previous character
    ret

;
; grow_head: sets Z=1 if powerup consumed, otherwise Z=0
;
grow_head:
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

    mov ax,cx
    call next_position          ; make BX position of new head
    call eat_powerup
    pushf                       ; save Z flag for return value
    call check_collision
    jnz game_over

    mov [SNAKE_HEAD_POS],bx     ; set new head position
    xchg ch,cl
    mov cl,SNAKE_HEAD_CHAR
    mov [bx],cx

    popf
    pop bx                      ; update old head
    mov cl,SNAKE_BODY_CHAR
    mov [bx],cx
    ret                         ; return Z flag

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

;
; eat_powerup: Z=1 if powerup was consumed, Z=0 otherwise
;
eat_powerup:
    cmp word [bx],POWERUP_CHAR
    jnz powerup_ret
    call place_powerup
    mov word [bx],BIOS_BLANK_FILL_CHAR
powerup_ret:
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
    push bx
pp_loop:
    call random_pos
    mov bx,ax
    cmp word [bx],BIOS_BLANK_FILL_CHAR
    jnz pp_loop                         ; find another location

    mov word [bx], POWERUP_CHAR
    pop bx
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

;
; next_position: given a DIR enum in AX, moves BX to the
;                next position on the screen.
;
;                trashes DI
;
next_position:
    mov di,DIR_TABLE
    add di,ax
    cs mov byte al,[di]
    cbw
    shl ax,1                ; double offset for 16-bit video memory
    add bx,ax               ; move BX to new position
    ret

DIR_TABLE:
    db 0,0,-80,-1,1,80  ; NA, NA, up, left, right, down

    times 510-($-$$) db 0   ; pad rest of first sector with zeros
    dw 0xaa55               ; boot signature (little-endian)
