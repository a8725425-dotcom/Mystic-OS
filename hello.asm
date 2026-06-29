[bits 16]
[org 0x100]
    mov si, msg
.loop:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    int 0x10
    jmp .loop
.done:
    cli
    hlt
msg db "Hello from bare metal!", 13, 10, 0
