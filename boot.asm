; boot.asm
; Загрузчик 512 байт, загружает ядро (секторы 1..32) по адресу 0x1000:0x0000
; и передаёт управление. Номер диска сохраняется в 0x7E00.

[bits 16]
[org 0x7C00]

KERNEL_START_SECTOR equ 1          ; ядро начинается с сектора 1 (LBA)
KERNEL_SECTORS      equ 32         ; читаем 32 сектора (16 Кбайт) – подстрой под размер ядра
KERNEL_SEG          equ 0x1000
KERNEL_OFF          equ 0x0000
DRIVE_INFO_ADDR     equ 0x7E00     ; сюда сохраним номер загрузочного диска

boot:
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 0x7C00          ; стек ниже 0x7C00
    sti

    mov [DRIVE_INFO_ADDR], dl ; сохранить номер диска для ядра

    ; проверим поддержку LBA (Int13h AH=41h), если нет – уходим в ошибку
    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc disk_error
    cmp bx, 0xAA55
    jne disk_error

    ; загружаем ядро
    mov si, dap              ; адрес DAP
    mov ah, 0x42
    mov dl, [DRIVE_INFO_ADDR]
    int 0x13
    jc disk_error

    ; прыгаем на ядро
    jmp KERNEL_SEG:KERNEL_OFF

disk_error:
    mov si, msg_err
    call print_string
    cli
    hlt

print_string:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    int 0x10
    jmp print_string
.done:
    ret

msg_err db "Disk error!", 0

; Disk Address Packet (DAP) для LBA-чтения
dap:
    db 0x10          ; размер DAP
    db 0             ; зарезервировано
    dw KERNEL_SECTORS; количество секторов
    dw KERNEL_OFF    ; смещение в сегменте
    dw KERNEL_SEG    ; сегмент буфера
    dq KERNEL_START_SECTOR ; стартовый LBA (8 байт)

; Выравнивание до 510 байт и сигнатура
times 510-($-$$) db 0
dw 0xAA55
