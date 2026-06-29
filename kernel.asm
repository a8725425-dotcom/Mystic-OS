; kernel.asm
; Ядро: парсит FAT32, ищет первый файл в корне, загружает как .COM и запускает.

[bits 16]
[org 0x0000]          ; будет загружено в сегмент 0x1000, поэтому org 0

KERNEL_SEG      equ 0x1000
DRIVE_INFO_ADDR equ 0x7E00   ; там номер диска, оставленный загрузчиком

; Адрес для загрузки пользовательской программы (.COM)
; COM-программы ожидают: CS=DS=ES=SS=сегмент, IP=0x100, перед этим PSP (256 байт)
PROG_SEG        equ 0x2000
PROG_OFFSET     equ 0x0100   ; начало кода COM-файла (сразу за PSP)

; Буферы
BOOT_BUF        equ 0x8000   ; 512 байт под boot-сектор
FAT_BUF         equ 0x8200   ; 512 байт под таблицу FAT
DIR_BUF         equ 0x8400   ; место для чтения каталога (один кластер)

start:
    ; настройка сегментов и стека
    mov ax, KERNEL_SEG
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0xFFFE

    ; получим номер диска
    mov dl, [DRIVE_INFO_ADDR]
    mov [drive_number], dl

    mov si, msg_kernel
    call print

    ; --- читаем boot-сектор (LBA 0) ---
    mov eax, 0
    mov bx, BOOT_BUF
    mov cx, 1
    call read_sectors
    jc fatal_error

    ; --- извлекаем параметры FAT32 из BPB ---
    mov ax, [BOOT_BUF + 0x0B]  ; BytesPerSector
    mov [bpbBytesPerSector], ax
    mov al, [BOOT_BUF + 0x0D]  ; SectorsPerCluster
    mov [bpbSectorsPerCluster], al
    mov ax, [BOOT_BUF + 0x0E]  ; ReservedSectors (word)
    mov [bpbReservedSectors], ax
    mov al, [BOOT_BUF + 0x10]  ; NumberOfFATs
    mov [bpbNumberOfFATs], al
    mov eax, [BOOT_BUF + 0x24] ; BPB_FATSz32 (sectors per FAT)
    mov [bpbFATSz32], eax
    mov eax, [BOOT_BUF + 0x2C] ; RootCluster
    mov [bpbRootCluster], eax

    ; вычислим начало FAT и данных
    xor eax, eax
    mov ax, [bpbReservedSectors]       ; EAX = ReservedSectors
    mov [fatStartLBA], eax

    mov eax, [bpbFATSz32]              ; EAX = SectorsPerFAT
    movzx ecx, byte [bpbNumberOfFATs]  ; ECX = NumberOfFATs
    mul ecx                            ; EAX = FATSz32 * NumFATs
    add eax, [fatStartLBA]             ; начало данных = Reserved + FATs
    mov [dataStartLBA], eax

    ; размер кластера в секторах
    movzx eax, byte [bpbSectorsPerCluster]
    mov [clusterSize], eax

    ; --- чтение корневого каталога ---
    mov eax, [bpbRootCluster]          ; первый кластер корня
    mov di, DIR_BUF                    ; куда читать
    call read_cluster                  ; читает один кластер в di
    jc fatal_error

    ; --- поиск первого обычного файла ---
    mov si, DIR_BUF
    mov cx, 0                          ; счётчик записей (на всякий случай, ограничим 512 записей)

.next_entry:
    cmp cx, 512
    je no_file_found
    cmp byte [si], 0x00               ; конец каталога
    je no_file_found
    cmp byte [si], 0xE5               ; удалённый файл
    je .skip
    ; проверим атрибуты (байт по смещению 11)
    mov al, [si + 11]
    test al, 0x08                     ; метка тома?
    jnz .skip
    test al, 0x10                     ; каталог?
    jnz .skip
    ; это обычный файл (архивный или нет – не важно)
    jmp file_found

.skip:
    add si, 32
    inc cx
    jmp .next_entry

no_file_found:
    mov si, msg_no_file
    call print
    cli
    hlt

file_found:
    ; сохраняем параметры файла
    mov ax, [si + 0x14]       ; старшее слово первого кластера
    shl eax, 16
    mov ax, [si + 0x1A]       ; младшее слово первого кластера
    mov [fileFirstCluster], eax
    mov eax, [si + 0x1C]      ; размер файла
    mov [fileSize], eax

    ; выводим сообщение
    mov si, msg_loading
    call print

    ; --- загрузка файла в память по адресу PROG_SEG:PROG_OFFSET ---
    ; перед загрузкой обнулим будущий PSP (256 байт)
    push es
    mov ax, PROG_SEG
    mov es, ax
    xor di, di
    mov cx, 256 / 2
    xor ax, ax
    rep stosw
    pop es

    ; начальный указатель для записи данных файла
    mov ax, PROG_SEG
    mov word [destSeg], ax
    mov word [destOff], PROG_OFFSET

    mov eax, [fileFirstCluster]
    mov ecx, [fileSize]       ; сколько байт осталось загрузить
    test ecx, ecx
    jz launch_program
    mov eax, [fileFirstCluster]
    mov [currentCluster], eax

.load_loop:
    push ecx
    ; читаем текущий кластер в DIR_BUF (переиспользуем буфер)
    mov di, DIR_BUF
    call read_cluster
    pop ecx
    jc fatal_error

    ; копируем данные из буфера в целевую область
    push ecx
    mov esi, DIR_BUF          ; источник
    ; сколько байт копировать: min(ecx, cluster_size_bytes)
    movzx edx, byte [bpbSectorsPerCluster]
    imul edx, [bpbBytesPerSector]   ; edx = байт в кластере
    cmp ecx, edx
    jbe .copy_all
    mov edx, ecx              ; если осталось меньше кластера
.copy_all:
    mov ecx, edx              ; ecx = количество байт для этого кластера
    ; копируем ecx байт из esi в es:di (где es:di = destSeg:destOff)
    push ds
    pop es                    ; сейчас ds = сегмент ядра, но источник в ds (DIR_BUF в сегменте KERNEL_SEG)
    ; переключим es на целевой сегмент для записи
    mov ax, [destSeg]
    mov es, ax
    mov di, [destOff]

    ; у нас источник в ds:esi, приёмник es:di
    ; копируем побайтно (можно быстрее, но для наглядности)
    cld
    rep movsb

    ; обновим destOff и остаток размера файла
    mov [destOff], di
    pop ecx
    sub ecx, edx
    jbe launch_program        ; если всё загрузили

    ; получим следующий кластер из FAT
    mov eax, [fileCurrentCluster] ; пока нет такой переменной, надо хранить текущий кластер
    ; инициализируем currentCluster
    ; (небольшой костыль – заведём переменную)
    mov eax, [currentCluster]
    call next_fat_entry        ; возвращает EAX = следующий кластер или признак конца
    mov [currentCluster], eax
    cmp eax, 0x0FFFFFF8
    jae launch_program         ; конец цепочки
    jmp .load_loop

launch_program:
    mov si, msg_ok
    call print

    ; настройка сегментов для COM-программы
    mov ax, PROG_SEG
    mov ds, ax
    mov es, ax
    ; SS:SP обычно устанавливают так же, но COM-программы часто сами настраивают стек.
    ; Дадим им стандартный стек: SS = PROG_SEG, SP = 0xFFFE.
    mov ss, ax
    mov sp, 0xFFFE

    ; прыжок на COM-программу (CS = PROG_SEG, IP = 0x100)
    push ax
    mov ax, PROG_OFFSET
    push ax
    retf

; ---------- подпрограммы ----------

; read_sectors: читает CX секторов, начиная с LBA в EAX, в буфер ES:BX
; (ES у нас = KERNEL_SEG, но в момент вызова может быть другой; будем сохранять)
read_sectors:
    pusha
    mov [dap_lba], eax
    mov [dap_sectors], cx
    mov [dap_buffer_off], bx
    mov [dap_buffer_seg], es
    mov si, dap_struct
    mov ah, 0x42
    mov dl, [drive_number]
    int 0x13
    popa
    ret

; read_cluster: читает один кластер, номер в EAX, буфер в DI (ES:DI)
; использует read_sectors
read_cluster:
    pusha
    ; преобразовать номер кластера в LBA: dataStartLBA + (cluster-2)*SectorsPerCluster
    sub eax, 2
    movzx edx, byte [bpbSectorsPerCluster]
    mul edx
    add eax, [dataStartLBA]
    ; теперь EAX = стартовый LBA
    movzx cx, byte [bpbSectorsPerCluster] ; количество секторов для чтения
    mov bx, di                 ; буфер = DI
    ; ES уже указывает на сегмент ядра (KERNEL_SEG), где находится DIR_BUF
    call read_sectors
    popa
    ret

; next_fat_entry: по текущему кластеру EAX возвращает следующий кластер (EAX)
; использует FAT_BUF
next_fat_entry:
    push ebx
    push ecx
    push edx
    push esi
    ; адрес FAT-записи = cluster * 4
    mov ecx, eax
    shl ecx, 2                ; ecx = смещение в байтах от начала FAT
    mov eax, ecx
    xor edx, edx
    div dword [bpbBytesPerSector] ; eax = номер сектора FAT (от начала FAT)
    ; edx = смещение внутри сектора
    mov ebx, edx
    add eax, [fatStartLBA]    ; LBA нужного сектора FAT
    push ebx                  ; сохраним смещение
    mov cx, 1
    mov bx, FAT_BUF
    mov si, KERNEL_SEG
    mov es, si
    call read_sectors
    pop ebx
    ; читаем dword по смещению ebx в буфере
    mov esi, FAT_BUF
    add esi, ebx
    mov eax, [esi]
    and eax, 0x0FFFFFFF       ; маска FAT32
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; print: строка в DS:SI
print:
    lodsb
    or al, al
    jz .done
    mov ah, 0x0E
    int 0x10
    jmp print
.done:
    ret

fatal_error:
    mov si, msg_fatal
    call print
    cli
    hlt

; ---------- данные ----------
drive_number        db 0
bpbBytesPerSector   dw 0
bpbSectorsPerCluster db 0
bpbReservedSectors  dw 0
bpbNumberOfFATs     db 0
bpbFATSz32          dd 0
bpbRootCluster      dd 0
fatStartLBA         dd 0
dataStartLBA        dd 0
clusterSize         dd 0   ; секторов в кластере (dword для удобства)

fileFirstCluster    dd 0
fileSize            dd 0
currentCluster      dd 0   ; используется во время чтения файла
destSeg             dw 0
destOff             dw 0

dap_struct:
    db 0x10
    db 0
dap_sectors dw 0
dap_buffer_off dw 0
dap_buffer_seg dw 0
dap_lba dq 0

msg_kernel  db "Kernel started...", 13, 10, 0
msg_loading db "Loading first program...", 13, 10, 0
msg_ok      db "Launching!", 13, 10, 0
msg_no_file db "No file found in root directory.", 13, 10, 0
msg_fatal   db "Fatal error.", 13, 10, 0
