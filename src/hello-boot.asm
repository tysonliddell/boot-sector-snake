video_buffer_segment:   equ 0xb000
width:                  equ 80
message_row:            equ 5
message_margin:         equ 15
    org 0x7c00

start:
    mov ax,0x0002   ; text mode
    int 0x10

    ; disable the cursor
    mov ah,0x01
    mov cx,0x3F00
    int 0x10

    ; switch to the text video buffer segment of memory
    mov ax,video_buffer_segment
    cld     ; clear direction flag for STOS instructions
    mov es,ax

    ; Render "Hello, "
    mov di,(message_row*width+message_margin)*2
    mov ax,0x0F48    ; 'H'
    stosw
    mov ax,0x0F65  ; 'e'
    stosw
    mov ax,0x0F6C  ; 'l'
    stosw
    mov ax,0x0F6C  ; 'l'
    stosw
    mov ax,0x0F6F  ; 'o'
    stosw
    mov ax,0x0F2C  ; ','
    stosw
    mov ax,0x0F20  ; ' '
    stosw

    ; Render "world!" with blinking/underlined text
    mov ax,0x0177  ; 'w'
    stosw
    mov ax,0x096F  ; 'o'
    stosw
    mov ax,0x0172  ; 'r'
    stosw
    mov ax,0x096C  ; 'l'
    stosw
    mov ax,0x0164  ; 'd'
    stosw
    mov ax,0x8F21  ; '!'
    stosw

forever:
    jmp forever

    times 510-($-$$) db 0   ; pad rest of first sector with zeros
    dw 0xaa55               ; boot signature (little-endian)
