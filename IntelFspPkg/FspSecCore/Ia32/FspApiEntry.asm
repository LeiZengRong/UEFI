;------------------------------------------------------------------------------
;
; Copyright (c) 2014, Intel Corporation. All rights reserved.<BR>
; This program and the accompanying materials
; are licensed and made available under the terms and conditions of the BSD License
; which accompanies this distribution.  The full text of the license may be found at
; http://opensource.org/licenses/bsd-license.php.
;
; THE PROGRAM IS DISTRIBUTED UNDER THE BSD LICENSE ON AN "AS IS" BASIS,
; WITHOUT WARRANTIES OR REPRESENTATIONS OF ANY KIND, EITHER EXPRESS OR IMPLIED.
;
; Abstract:
;
;   Provide FSP API entry points.
;
;------------------------------------------------------------------------------

    .586p
    .model  flat,C
    .code
    .xmm

INCLUDE    SaveRestoreSse.inc
INCLUDE    UcodeLoad.inc

;
; Following are fixed PCDs
;
EXTERN   PcdGet32(PcdTemporaryRamBase):DWORD
EXTERN   PcdGet32(PcdTemporaryRamSize):DWORD
EXTERN   PcdGet32(PcdFspTemporaryRamSize):DWORD

;
; Following functions will be provided in C
;
EXTERN   FspImageSizeOffset:DWORD
EXTERN   SecStartup:PROC
EXTERN   FspApiCallingCheck:PROC

;
; Following functions will be provided in PlatformSecLib
;
EXTERN   GetFspBaseAddress:PROC
EXTERN   GetBootFirmwareVolumeOffset:PROC
EXTERN   PlatformTempRamInit:PROC
EXTERN   Pei2LoaderSwitchStack:PROC
EXTERN   FspSelfCheck(FspSelfCheckDflt):PROC
EXTERN   PlatformBasicInit(PlatformBasicInitDflt):PROC
EXTERN   LoadUcode(LoadUcodeDflt):PROC

;
; Define the data length that we saved on the stack top
;
DATA_LEN_OF_PER0         EQU   18h
DATA_LEN_OF_MCUD         EQU   18h
DATA_LEN_AT_STACK_TOP    EQU   (DATA_LEN_OF_PER0 + DATA_LEN_OF_MCUD + 4)

;------------------------------------------------------------------------------
FspSelfCheckDflt PROC NEAR PUBLIC
   ; Inputs:
   ;   eax -> Return address
   ; Outputs:
   ;   eax -> 0 - Successful, Non-zero - Failed.
   ; Register Usage:
   ;   eax is cleared and ebp is used for return address.
   ;   All others reserved.

   ; Save return address to EBP
   mov   ebp, eax

   xor   eax, eax
exit:
   jmp   ebp
FspSelfCheckDflt   ENDP

;------------------------------------------------------------------------------
PlatformBasicInitDflt PROC NEAR PUBLIC
   ; Inputs:
   ;   eax -> Return address
   ; Outputs:
   ;   eax -> 0 - Successful, Non-zero - Failed.
   ; Register Usage:
   ;   eax is cleared and ebp is used for return address.
   ;   All others reserved.

   ; Save return address to EBP
   mov   ebp, eax

   xor   eax, eax
exit:
   jmp   ebp
PlatformBasicInitDflt   ENDP

;------------------------------------------------------------------------------
LoadUcodeDflt   PROC  NEAR PUBLIC
   ; Inputs:
   ;   esp -> LOAD_UCODE_PARAMS pointer
   ; Register Usage:
   ;   esp  Preserved
   ;   All others destroyed
   ; Assumptions:
   ;   No memory available, stack is hard-coded and used for return address
   ;   Executed by SBSP and NBSP
   ;   Beginning of microcode update region starts on paragraph boundary

   ;
   ;
   ; Save return address to EBP
   mov    ebp, eax

   cmp    esp, 0
   jz     paramerror
   mov    eax, dword ptr [esp]    ; Parameter pointer
   cmp    eax, 0
   jz     paramerror
   mov    esp, eax
   mov    esi, [esp].LOAD_UCODE_PARAMS.ucode_code_addr
   cmp    esi, 0
   jnz    check_main_header

paramerror:
   mov    eax, 080000002h
   jmp    exit

   mov    esi, [esp].LOAD_UCODE_PARAMS.ucode_code_addr

check_main_header:
   ; Get processor signature and platform ID from the installed processor
   ; and save into registers for later use
   ; ebx = processor signature
   ; edx = platform ID
   mov   eax, 1
   cpuid
   mov   ebx, eax
   mov   ecx, MSR_IA32_PLATFORM_ID
   rdmsr
   mov   ecx, edx
   shr   ecx, 50-32
   and   ecx, 7h
   mov   edx, 1
   shl   edx, cl

   ; Current register usage
   ; esp -> stack with paramters
   ; esi -> microcode update to check
   ; ebx = processor signature
   ; edx = platform ID

   ; Check for valid microcode header
   ; Minimal test checking for header version and loader version as 1
   mov   eax, dword ptr 1
   cmp   [esi].ucode_hdr.version, eax
   jne   advance_fixed_size
   cmp   [esi].ucode_hdr.loader, eax
   jne   advance_fixed_size

   ; Check if signature and plaform ID match
   cmp   ebx, [esi].ucode_hdr.processor
   jne   @f
   test  edx, [esi].ucode_hdr.flags
   jnz   load_check  ; Jif signature and platform ID match

@@:
   ; Check if extended header exists
   ; First check if total_size and data_size are valid
   xor   eax, eax
   cmp   [esi].ucode_hdr.total_size, eax
   je    next_microcode
   cmp   [esi].ucode_hdr.data_size, eax
   je    next_microcode

   ; Then verify total size - sizeof header > data size
   mov   ecx, [esi].ucode_hdr.total_size
   sub   ecx, sizeof ucode_hdr
   cmp   ecx, [esi].ucode_hdr.data_size
   jng   next_microcode    ; Jif extended header does not exist

   ; Set edi -> extended header
   mov   edi, esi
   add   edi, sizeof ucode_hdr
   add   edi, [esi].ucode_hdr.data_size

   ; Get count of extended structures
   mov   ecx, [edi].ext_sig_hdr.count

   ; Move pointer to first signature structure
   add   edi, sizeof ext_sig_hdr

check_ext_sig:
   ; Check if extended signature and platform ID match
   cmp   [edi].ext_sig.processor, ebx
   jne   @f
   test  [edi].ext_sig.flags, edx
   jnz   load_check     ; Jif signature and platform ID match
@@:
   ; Check if any more extended signatures exist
   add   edi, sizeof ext_sig
   loop  check_ext_sig

next_microcode:
   ; Advance just after end of this microcode
   xor   eax, eax
   cmp   [esi].ucode_hdr.total_size, eax
   je    @f
   add   esi, [esi].ucode_hdr.total_size
   jmp   check_address
@@:
   add   esi, dword ptr 2048
   jmp   check_address

advance_fixed_size:
   ; Advance by 4X dwords
   add   esi, dword ptr 1024

check_address:
   ; Is valid Microcode start point ?
   cmp   dword ptr [esi], 0ffffffffh
   jz    done

   ; Address >= microcode region address + microcode region size?
   mov   eax, [esp].LOAD_UCODE_PARAMS.ucode_code_addr
   add   eax, [esp].LOAD_UCODE_PARAMS.ucode_code_size
   cmp   esi, eax
   jae   done        ;Jif address is outside of ucode region
   jmp   check_main_header

load_check:
   ; Get the revision of the current microcode update loaded
   mov   ecx, MSR_IA32_BIOS_SIGN_ID
   xor   eax, eax               ; Clear EAX
   xor   edx, edx               ; Clear EDX
   wrmsr                        ; Load 0 to MSR at 8Bh

   mov   eax, 1
   cpuid
   mov   ecx, MSR_IA32_BIOS_SIGN_ID
   rdmsr                         ; Get current microcode signature

   ; Verify this microcode update is not already loaded
   cmp   [esi].ucode_hdr.revision, edx
   je    continue

load_microcode:
   ; EAX contains the linear address of the start of the Update Data
   ; EDX contains zero
   ; ECX contains 79h (IA32_BIOS_UPDT_TRIG)
   ; Start microcode load with wrmsr
   mov   eax, esi
   add   eax, sizeof ucode_hdr
   xor   edx, edx
   mov   ecx, MSR_IA32_BIOS_UPDT_TRIG
   wrmsr
   mov   eax, 1
   cpuid

continue:
   jmp   next_microcode

done:
   mov   eax, 1
   cpuid
   mov   ecx, MSR_IA32_BIOS_SIGN_ID
   rdmsr                         ; Get current microcode signature
   xor   eax, eax
   cmp   edx, 0
   jnz   exit
   mov   eax, 08000000Eh

exit:
   jmp   ebp

LoadUcodeDflt   ENDP

;----------------------------------------------------------------------------
; TempRamInit API
;
; This FSP API will load the microcode update, enable code caching for the
; region specified by the boot loader and also setup a temporary stack to be
; used till main memory is initialized.
;
;----------------------------------------------------------------------------
TempRamInitApi   PROC    NEAR    PUBLIC
  ;
  ; Ensure SSE is enabled
  ;
  ENABLE_SSE

  ;
  ; Save EBP, EBX, ESI, EDI & ESP in XMM7 & XMM6
  ;
  SAVE_REGS

  ;
  ; Save timestamp into XMM4 & XMM5
  ;
  rdtsc
  SAVE_EAX
  SAVE_EDX

  ;
  ; Check Parameter
  ;
  mov       eax, dword ptr [esp + 4]
  cmp       eax, 0
  mov       eax, 80000002h
  jz        NemInitExit

  ;
  ; CPUID/DeviceID check
  ;
  mov       eax, @F
  jmp       FspSelfCheck  ; Note: ESP can not be changed.
@@:
  cmp       eax, 0
  jnz       NemInitExit

  ;
  ; Platform Basic Init.
  ;
  mov       eax, @F
  jmp       PlatformBasicInit
@@:
  cmp       eax, 0
  jnz       NemInitExit

  ;
  ; Load microcode
  ;
  mov       eax, @F
  add       esp, 4
  jmp       LoadUcode
@@:
  LOAD_ESP
  cmp       eax, 0
  jnz       NemInitExit

  ;
  ; Call platform NEM init
  ;
  mov       eax, @F
  add       esp, 4
  jmp       PlatformTempRamInit
@@:
  LOAD_ESP
  cmp       eax, 0
  jnz       NemInitExit

  ;
  ; Save parameter pointer in edx
  ;
  mov       edx, dword ptr [esp + 4]

  ;
  ; Enable FSP STACK
  ;
  mov       esp, PcdGet32(PcdTemporaryRamBase)
  add       esp, PcdGet32(PcdTemporaryRamSize)

  push      DATA_LEN_OF_MCUD     ; Size of the data region
  push      4455434Dh            ; Signature of the  data region 'MCUD'
  push      dword ptr [edx +  4] ; Microcode size
  push      dword ptr [edx +  0] ; Microcode base
  push      dword ptr [edx + 12] ; Code size
  push      dword ptr [edx + 8]  ; Code base

  ;
  ; Save API entry/exit timestamp into stack
  ;
  push      DATA_LEN_OF_PER0     ; Size of the data region
  push      30524550h            ; Signature of the  data region 'PER0'
  rdtsc
  push      edx
  push      eax
  LOAD_EAX
  LOAD_EDX
  push      edx
  push      eax

  ;
  ; Terminator for the data on stack
  ;
  push      0

  ;
  ; Set ECX/EDX to the bootloader temporary memory range
  ;
  mov       ecx, PcdGet32(PcdTemporaryRamBase)
  mov       edx, ecx
  add       edx, PcdGet32(PcdTemporaryRamSize)
  sub       edx, PcdGet32(PcdFspTemporaryRamSize)

  xor       eax, eax

NemInitExit:
  ;
  ; Load EBP, EBX, ESI, EDI & ESP from XMM7 & XMM6
  ;
  LOAD_REGS
  ret
TempRamInitApi   ENDP

;----------------------------------------------------------------------------
; FspInit API
;
; This FSP API will perform the processor and chipset initialization.
; This API will not return.  Instead, it transfers the control to the
; ContinuationFunc provided in the parameter.
;
;----------------------------------------------------------------------------
FspInitApi   PROC    NEAR    PUBLIC
  ;
  ; Stack must be ready
  ;
  push   087654321h
  pop    eax
  cmp    eax, 087654321h
  jz     @F
  mov    eax, 080000003h
  jmp    exit

@@:
  ;
  ; Additional check
  ;
  pushad
  push   1
  call   FspApiCallingCheck
  add    esp, 4
  mov    dword ptr [esp + 4 * 7],  eax
  popad
  cmp    eax, 0
  jz     @F
  jmp    exit

@@:
  ;
  ; Store the address in FSP which will return control to the BL
  ;
  push   offset exit

  ;
  ; Create a Task Frame in the stack for the Boot Loader
  ;
  pushfd     ; 2 pushf for 4 byte alignment
  cli
  pushad

  ; Reserve 8 bytes for IDT save/restore
  sub     esp, 8
  sidt    fword ptr [esp]

  ;
  ; Setup new FSP stack
  ;
  mov     eax, esp
  mov     esp, PcdGet32(PcdTemporaryRamBase)
  add     esp, PcdGet32(PcdTemporaryRamSize)
  sub     esp, (DATA_LEN_AT_STACK_TOP + 40h)

  ;
  ; Save the bootloader's stack pointer
  ;
  push    eax

  ;
  ; Pass entry point of the PEI core
  ;
  call    GetFspBaseAddress
  mov     edi, FspImageSizeOffset
  mov     edi, DWORD PTR [eax + edi]
  add     edi, eax
  sub     edi, 20h
  add     eax, DWORD PTR [edi]
  push    eax

  ;
  ; Pass BFV into the PEI Core
  ; It uses relative address to calucate the actual boot FV base
  ; For FSP impleantion with single FV, PcdFlashFvRecoveryBase and
  ; PcdFspAreaBaseAddress are the same. For FSP with mulitple FVs,
  ; they are different. The code below can handle both cases.
  ;
  call    GetFspBaseAddress
  mov     edi, eax
  call    GetBootFirmwareVolumeOffset
  add     eax, edi
  push    eax

  ;
  ; Pass stack base and size into the PEI Core
  ;
  mov     eax,  PcdGet32(PcdTemporaryRamBase)
  add     eax,  PcdGet32(PcdTemporaryRamSize)
  sub     eax,  PcdGet32(PcdFspTemporaryRamSize)
  push    eax
  push    PcdGet32(PcdFspTemporaryRamSize)

  ;
  ; Pass Control into the PEI Core
  ;
  call    SecStartup

exit:
  ret

FspInitApi   ENDP

;----------------------------------------------------------------------------
; NotifyPhase API
;
; This FSP API will notify the FSP about the different phases in the boot
; process
;
;----------------------------------------------------------------------------
NotifyPhaseApi   PROC C PUBLIC
  ;
  ; Stack must be ready
  ;
  push   087654321h
  pop    eax
  cmp    eax, 087654321h
  jz     @F
  mov    eax, 080000003h
  jmp    err_exit

@@:
  ;
  ; Verify the calling condition
  ;
  pushad
  push   2
  call   FspApiCallingCheck
  add    esp, 4
  mov    dword ptr [esp + 4 * 7],  eax
  popad

  cmp    eax, 0
  jz     @F

  ;
  ; Error return
  ;
err_exit:
  ret

@@:
  jmp    Pei2LoaderSwitchStack

NotifyPhaseApi   ENDP


END
