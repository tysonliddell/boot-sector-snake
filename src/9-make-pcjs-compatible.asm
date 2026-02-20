PIT_CHAN_0              equ 0x40
PIT_CHAN_2              equ 0x42
PIT_COMMAND             equ 0x43
PPI_PORT_B              equ 0x61

VID_BUF_SEG:            equ 0xb000
BIOS_BLANK_FILL_CHAR:   equ ' '+7*256       ; blank vid memory init char
POWERUP_CHAR:           equ '@'+7*256
SCORE_POS               equ (80-1)*2

SNAKE_HEAD_CHAR:        equ 0x01            ; smiley face
SNAKE_BODY_CHAR:        equ 0xE9            ; theta character
SNAKE_START_POS:        equ (80*12+40)*2    ; start in middle of screen

UP_DIR:                 equ 0x02    ; encodings that can be applied to a
LEFT_DIR:               equ 0x03    ; character attribute without missing up
RIGHT_DIR:              equ 0x04    ; the MDA display
DOWN_DIR:               equ 0x05

WHTFG_BLKBG:            equ 0x07    ; white fg with black bg char attribute
BLKFG_WHTBG:            equ 0x70

PRNG_P                  equ 1999    ; choose prime p s.t. p < 80*25
PRNG_M                  equ 20

; use the 96 bytes of "off-screen" video memory for general storage
; this simplifies working with segmented memory
SNAKE_HEAD_POS:         equ 25*80*2
SNAKE_TAIL_POS:         equ SNAKE_HEAD_POS+2
SNAKE_LENGTH:           equ SNAKE_HEAD_POS+4
PRNG_SEQ:               equ SNAKE_HEAD_POS+6


    org 0x7c00
start:
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
    mov word [SNAKE_LENGTH],3

    call seed_prng

    call draw_border
    call place_powerup

main:
    call print_score
    call wait_for_tick
    call grow_head
    jz inc_score            ; powerup consumed, no need to shrink tail
    call shrink_tail
    jmp main
inc_score:
    inc word [SNAKE_LENGTH]
    mov bx,500
    mov cx,0x0F
    call bit_bang_sound
    jmp main

;
; bit_bang_sound: oscillate the PC speaker manually
;                 (TIMER 2 is not available)
; BX: freq control (num cpu cycles between speaker cone in/out)
; CX: duration (how many oscillations)
bit_bang_sound:
    in ax,PPI_PORT_B
    mov dx,ax           ; save current port state in DX
flip_cone:
    push cx
    mov cx,bx
    loop $              ; wait for cycles
    pop cx
    xor ax,00000011b    ; invert speaker cone
    out PPI_PORT_B,ax
    loop flip_cone

    mov ax,dx           ; restore port
    out PPI_PORT_B,ax
    ret

print_score:
    mov ax,[SNAKE_LENGTH]
    mov cx,10
    mov bx,SCORE_POS
div_loop:
    cmp ax,0
    jnz do_div
    ret
do_div:
    mov dx,0
    div cx
    add dl,'0'
    mov dh,BLKFG_WHTBG
    mov [bx],dx
    dec bx
    dec bx
    jmp div_loop

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
    call prng_next  ; result in DX (value in range 0-2000)
    mov ax,dx
    shl ax,1        ; chars on screen are 16-bit
    mov bx,ax
    cmp word [bx],BIOS_BLANK_FILL_CHAR
    jnz pp_loop                         ; find another location

    mov word [bx], POWERUP_CHAR
    pop bx
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

seed_prng:
    mov ax,00000000b    ; read TIMER 0 counter value from PIT in latched mode
    out PIT_COMMAND,ax
    in al,PIT_CHAN_0
    mov ah,al
    in al,PIT_CHAN_0
    xchg al,ah
    xor ah,ah       ; make seed < 256 < PRNG_P
    mov [PRNG_SEQ],ax
    ret

; compute m*x mod p
; sets DX to next number in sequence
prng_next:
    push ax
    push cx
    mov ax,[PRNG_SEQ]
    mov dx,PRNG_M
    mul dx          ; mx
    mov dx,0
    mov cx,PRNG_P   ; mod p
    div cx
    mov [PRNG_SEQ],dx
    pop cx
    pop ax
    ret

DIR_TABLE:
    db 0,0,-80,-1,1,80  ; NA, NA, up, left, right, down

    ;times 510-($-$$) db 0   ; pad rest of first sector with zeros
    ;dw 0xaa55               ; boot signature (little-endian)
