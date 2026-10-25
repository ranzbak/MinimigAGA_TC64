/* Machine-mode CSR access for the OSD host CPU (VexRiscv RV32IMC, the CSR
 * set of CsrPluginConfig.small: mstatus, mie, mip, mtvec (writable), mepc
 * (R/W), mcause and mtval (read only); no mscratch, no counters). */
#ifndef ARCH_CSR_H
#define ARCH_CSR_H

#include <stdint.h>

#define MSTATUS_MIE  0x00000008u    /* machine interrupt enable           */
#define MSTATUS_MPIE 0x00000080u    /* MIE before the trap (mret restores) */
#define MIE_MEIE     0x00000800u    /* machine external interrupt enable  */

#define MCAUSE_IRQ   0x80000000u    /* interrupt bit                      */
#define MCAUSE_MEI   0x8000000Bu    /* machine external interrupt (cfide) */
#define MCAUSE_ILL   2u             /* illegal instruction                */
#define MCAUSE_LMIS  4u             /* misaligned load                    */
#define MCAUSE_SMIS  6u             /* misaligned store                   */

#define csr_read(csr) ({ uint32_t v_; \
    __asm__ volatile("csrr %0, " #csr : "=r"(v_)); v_; })
#define csr_write(csr, val) \
    __asm__ volatile("csrw " #csr ", %0" : : "rK"((uint32_t)(val)) : "memory")
#define csr_set(csr, bits) \
    __asm__ volatile("csrs " #csr ", %0" : : "rK"((uint32_t)(bits)) : "memory")
#define csr_clear(csr, bits) \
    __asm__ volatile("csrc " #csr ", %0" : : "rK"((uint32_t)(bits)) : "memory")

#endif
