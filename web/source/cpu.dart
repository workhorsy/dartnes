/*
DartNES Copyright (c) 2013 Matthew Brennan Jones <matthew.brennan.jones@gmail.com>
JSNes Copyright (C) 2010 Ben Firshman
vNES Copyright (C) 2006-2011 Jamie Sanders

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

library dartnes_cpu;

import 'nes.dart';

class CPU {
    // IRQ Types
    static const int IRQ_NORMAL = 0;
    static const int IRQ_NMI = 1;
    static const int IRQ_RESET = 2;
    
    static final List<String> JSON_PROPERTIES = [
        'mem', 'cyclesToHalt', 'irqRequested', 'irqType',
        // Registers
        'REG_ACC', 'REG_X', 'REG_Y', 'REG_SP', 'REG_PC', 'REG_PC_NEW',
        'REG_STATUS',
        // Status
        'F_CARRY', 'F_DECIMAL', 'F_INTERRUPT', 'F_INTERRUPT_NEW', 'F_OVERFLOW', 
        'F_SIGN', 'F_ZERO', 'F_NOTUSED', 'F_NOTUSED_NEW', 'F_BRK', 'F_BRK_NEW'
    ];
  
    NES nes = null;
    List<int> mem = null;
    int REG_ACC = 0;
    int REG_X = 0;
    int REG_Y = 0;
    int REG_SP = 0;
    int REG_PC = 0;
    int REG_PC_NEW = 0;
    int REG_STATUS = 0;
    int F_CARRY = 0;
    int F_DECIMAL = 0;
    int F_INTERRUPT = 0;
    int F_INTERRUPT_NEW = 0;
    int F_OVERFLOW = 0;
    int F_SIGN = 0;
    int F_ZERO = 0;
    int F_NOTUSED = 0;
    int F_NOTUSED_NEW = 0;
    int F_BRK = 0;
    int F_BRK_NEW = 0;
    List<List<int>> opdata = null;
    int cyclesToHalt = 0;
    bool crash = false;
    bool irqRequested = false;
    int irqType = 0;
    
    CPU(NES nes) {
      assert(nes is NES);
      
      this.nes = nes;
      this.reset();
    }
    
    void reset() {
        // Main memory 
        this.mem = new List<int>.filled(0x10000, 0);
        
        for (int i=0; i < 0x2000; i++) {
            this.mem[i] = 0xFF;
        }
        for (int p=0; p < 4; p++) {
            int i = p*0x800;
            this.mem[i+0x008] = 0xF7;
            this.mem[i+0x009] = 0xEF;
            this.mem[i+0x00A] = 0xDF;
            this.mem[i+0x00F] = 0xBF;
        }
        for (int i=0x2001; i < this.mem.length; i++) {
            this.mem[i] = 0;
        }
        
        // CPU Registers:
        this.REG_ACC = 0;
        this.REG_X = 0;
        this.REG_Y = 0;
        // Reset Stack pointer:
        this.REG_SP = 0x01FF;
        // Reset Program counter:
        this.REG_PC = 0x8000-1;
        this.REG_PC_NEW = 0x8000-1;
        // Reset Status register:
        this.REG_STATUS = 0x28;
        
        this.setStatus(0x28);
        
        // Set flags:
        this.F_CARRY = 0;
        this.F_DECIMAL = 0;
        this.F_INTERRUPT = 1;
        this.F_INTERRUPT_NEW = 1;
        this.F_OVERFLOW = 0;
        this.F_SIGN = 0;
        this.F_ZERO = 1;

        this.F_NOTUSED = 1;
        this.F_NOTUSED_NEW = 1;
        this.F_BRK = 1;
        this.F_BRK_NEW = 1;
        
        this.opdata = CPU_OpData.createOpData();
        this.cyclesToHalt = 0;
        
        // Reset crash flag:
        this.crash = false;
        
        // Interrupt notification:
        this.irqRequested = false;
        this.irqType = null;

    }
    
    // Emulates a single CPU instruction, returns the number of cycles
    int emulate() {
        int temp = 0;
        int add = 0;
      
        // Check interrupts:
        if(this.irqRequested){
            temp =
                (this.F_CARRY)|
                ((this.F_ZERO==0?1:0)<<1)|
                (this.F_INTERRUPT<<2)|
                (this.F_DECIMAL<<3)|
                (this.F_BRK<<4)|
                (this.F_NOTUSED<<5)|
                (this.F_OVERFLOW<<6)|
                (this.F_SIGN<<7);

            this.REG_PC_NEW = this.REG_PC;
            this.F_INTERRUPT_NEW = this.F_INTERRUPT;
            switch(this.irqType){
                case 0:
                    // Normal IRQ:
                    if(this.F_INTERRUPT!=0){
                        ////System.out.println("Interrupt was masked.");
                        break;
                    }
                    this.doIrq(temp);
                    ////System.out.println("Did normal IRQ. I="+this.F_INTERRUPT);
                    break;
                case 1:
                    // NMI:
                    this.doNonMaskableInterrupt(temp);
                    break;

                case 2:
                    // Reset:
                    this.doResetInterrupt();
                    break;
            }

            this.REG_PC = this.REG_PC_NEW;
            this.F_INTERRUPT = this.F_INTERRUPT_NEW;
            this.F_BRK = this.F_BRK_NEW;
            this.irqRequested = false;
        }

        final List<int> opinf = this.opdata[this.nes.mmap.load(this.REG_PC+1)];
        int cycleCount = opinf[3];
        int cycleAdd = 0;

        // Find address mode:
        final int addrMode = opinf[1];

        // Increment PC by number of op bytes:
        final int opaddr = this.REG_PC;
        this.REG_PC += (opinf[2]);
        
        int addr = 0;
        switch(addrMode){
            case 0:
                // Zero Page mode. Use the address given after the opcode, 
                // but without high byte.
                addr = this.load(opaddr+2);
                break;

            case 1:
                // Relative mode.
                addr = this.load(opaddr+2);
                if(addr<0x80){
                    addr += this.REG_PC;
                }else{
                    addr += this.REG_PC-256;
                }
                break;
            case 2:
                // Ignore. Address is implied in instruction.
                break;
            case 3:
                // Absolute mode. Use the two bytes following the opcode as 
                // an address.
                addr = this.load16bit(opaddr+2);
                break;
            case 4:
                // Accumulator mode. The address is in the accumulator 
                // register.
                addr = this.REG_ACC;
                break;
            case 5:
                // Immediate mode. The value is given after the opcode.
                addr = this.REG_PC;
                break;
            case 6:
                // Zero Page Indexed mode, X as index. Use the address given 
                // after the opcode, then add the
                // X register to it to get the final address.
                addr = (this.load(opaddr+2)+this.REG_X)&0xFF;
                break;
            case 7:
                // Zero Page Indexed mode, Y as index. Use the address given 
                // after the opcode, then add the
                // Y register to it to get the final address.
                addr = (this.load(opaddr+2)+this.REG_Y)&0xFF;
                break;
            case 8:
                // Absolute Indexed Mode, X as index. Same as zero page 
                // indexed, but with the high byte.
                addr = this.load16bit(opaddr+2);
                if((addr&0xFF00)!=((addr+this.REG_X)&0xFF00)){
                    cycleAdd = 1;
                }
                addr+=this.REG_X;
                break;
            case 9:
                // Absolute Indexed Mode, Y as index. Same as zero page 
                // indexed, but with the high byte.
                addr = this.load16bit(opaddr+2);
                if((addr&0xFF00)!=((addr+this.REG_Y)&0xFF00)){
                    cycleAdd = 1;
                }
                addr+=this.REG_Y;
                break;
            case 10:
                // Pre-indexed Indirect mode. Find the 16-bit address 
                // starting at the given location plus
                // the current X register. The value is the contents of that 
                // address.
                addr = this.load(opaddr+2);
                if((addr&0xFF00)!=((addr+this.REG_X)&0xFF00)){
                    cycleAdd = 1;
                }
                addr+=this.REG_X;
                addr&=0xFF;
                addr = this.load16bit(addr);
                break;
            case 11:
                // Post-indexed Indirect mode. Find the 16-bit address 
                // contained in the given location
                // (and the one following). Add to that address the contents 
                // of the Y register. Fetch the value
                // stored at that adress.
                addr = this.load16bit(this.load(opaddr+2));
                if((addr&0xFF00)!=((addr+this.REG_Y)&0xFF00)){
                    cycleAdd = 1;
                }
                addr+=this.REG_Y;
                break;
            case 12:
                // Indirect Absolute mode. Find the 16-bit address contained 
                // at the given location.
                addr = this.load16bit(opaddr+2);// Find op
                if(addr < 0x1FFF) {
                    addr = this.mem[addr] + (this.mem[(addr & 0xFF00) | (((addr & 0xFF) + 1) & 0xFF)] << 8);// Read from address given in op
                }
                else{
                    addr = this.nes.mmap.load(addr) + (this.nes.mmap.load((addr & 0xFF00) | (((addr & 0xFF) + 1) & 0xFF)) << 8);
                }
                break;

        }
        // Wrap around for addresses above 0xFFFF:
        addr &= 0xFFFF;

        // ----------------------------------------------------------------------------------------------------
        // Decode & execute instruction:
        // ----------------------------------------------------------------------------------------------------

        // This should be compiled to a jump table.
        switch(opinf[0]){
            case 0:
                // *******
                // * ADC *
                // *******

                // Add with carry.
                temp = this.REG_ACC + this.load(addr) + this.F_CARRY;
                this.F_OVERFLOW = ((!(((this.REG_ACC ^ this.load(addr)) & 0x80)!=0) && (((this.REG_ACC ^ temp) & 0x80))!=0)?1:0);
                this.F_CARRY = (temp>255?1:0);
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp&0xFF;
                this.REG_ACC = (temp&255);
                cycleCount+=cycleAdd;
                break;

            case 1:
                // *******
                // * AND *
                // *******

                // AND memory with accumulator.
                this.REG_ACC = this.REG_ACC & this.load(addr);
                this.F_SIGN = (this.REG_ACC>>7)&1;
                this.F_ZERO = this.REG_ACC;
                //this.REG_ACC = temp;
                if(addrMode!=11)cycleCount+=cycleAdd; // PostIdxInd = 11
                break;
            case 2:
                // *******
                // * ASL *
                // *******

                // Shift left one bit
                if(addrMode == 4){ // ADDR_ACC = 4

                    this.F_CARRY = (this.REG_ACC>>7)&1;
                    this.REG_ACC = (this.REG_ACC<<1)&255;
                    this.F_SIGN = (this.REG_ACC>>7)&1;
                    this.F_ZERO = this.REG_ACC;

                }else{

                    temp = this.load(addr);
                    this.F_CARRY = (temp>>7)&1;
                    temp = (temp<<1)&255;
                    this.F_SIGN = (temp>>7)&1;
                    this.F_ZERO = temp;
                    this.write(addr, temp);

                }
                break;

            case 3:

                // *******
                // * BCC *
                // *******

                // Branch on carry clear
                if(this.F_CARRY == 0){
                    cycleCount += ((opaddr&0xFF00)!=(addr&0xFF00)?2:1);
                    this.REG_PC = addr;
                }
                break;

            case 4:

                // *******
                // * BCS *
                // *******

                // Branch on carry set
                if(this.F_CARRY == 1){
                    cycleCount += ((opaddr&0xFF00)!=(addr&0xFF00)?2:1);
                    this.REG_PC = addr;
                }
                break;

            case 5:

                // *******
                // * BEQ *
                // *******

                // Branch on zero
                if(this.F_ZERO == 0){
                    cycleCount += ((opaddr&0xFF00)!=(addr&0xFF00)?2:1);
                    this.REG_PC = addr;
                }
                break;

            case 6:

                // *******
                // * BIT *
                // *******

                temp = this.load(addr);
                this.F_SIGN = (temp>>7)&1;
                this.F_OVERFLOW = (temp>>6)&1;
                temp &= this.REG_ACC;
                this.F_ZERO = temp;
                break;

            case 7:

                // *******
                // * BMI *
                // *******

                // Branch on negative result
                if(this.F_SIGN == 1){
                    cycleCount++;
                    this.REG_PC = addr;
                }
                break;

            case 8:

                // *******
                // * BNE *
                // *******

                // Branch on not zero
                if(this.F_ZERO != 0){
                    cycleCount += ((opaddr&0xFF00)!=(addr&0xFF00)?2:1);
                    this.REG_PC = addr;
                }
                break;

            case 9:

                // *******
                // * BPL *
                // *******

                // Branch on positive result
                if(this.F_SIGN == 0){
                    cycleCount += ((opaddr&0xFF00)!=(addr&0xFF00)?2:1);
                    this.REG_PC = addr;
                }
                break;

            case 10:

                // *******
                // * BRK *
                // *******

                this.REG_PC+=2;
                this.push((this.REG_PC>>8)&255);
                this.push(this.REG_PC&255);
                this.F_BRK = 1;

                this.push(
                    (this.F_CARRY)|
                    ((this.F_ZERO==0?1:0)<<1)|
                    (this.F_INTERRUPT<<2)|
                    (this.F_DECIMAL<<3)|
                    (this.F_BRK<<4)|
                    (this.F_NOTUSED<<5)|
                    (this.F_OVERFLOW<<6)|
                    (this.F_SIGN<<7)
                );

                this.F_INTERRUPT = 1;
                //this.REG_PC = load(0xFFFE) | (load(0xFFFF) << 8);
                this.REG_PC = this.load16bit(0xFFFE);
                this.REG_PC--;
                break;

            case 11:

                // *******
                // * BVC *
                // *******

                // Branch on overflow clear
                if(this.F_OVERFLOW == 0){
                    cycleCount += ((opaddr&0xFF00)!=(addr&0xFF00)?2:1);
                    this.REG_PC = addr;
                }
                break;

            case 12:

                // *******
                // * BVS *
                // *******

                // Branch on overflow set
                if(this.F_OVERFLOW == 1){
                    cycleCount += ((opaddr&0xFF00)!=(addr&0xFF00)?2:1);
                    this.REG_PC = addr;
                }
                break;

            case 13:

                // *******
                // * CLC *
                // *******

                // Clear carry flag
                this.F_CARRY = 0;
                break;

            case 14:

                // *******
                // * CLD *
                // *******

                // Clear decimal flag
                this.F_DECIMAL = 0;
                break;

            case 15:

                // *******
                // * CLI *
                // *******

                // Clear interrupt flag
                this.F_INTERRUPT = 0;
                break;

            case 16:

                // *******
                // * CLV *
                // *******

                // Clear overflow flag
                this.F_OVERFLOW = 0;
                break;

            case 17:

                // *******
                // * CMP *
                // *******

                // Compare memory and accumulator:
                temp = this.REG_ACC - this.load(addr);
                this.F_CARRY = (temp>=0?1:0);
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp&0xFF;
                cycleCount+=cycleAdd;
                break;

            case 18:

                // *******
                // * CPX *
                // *******

                // Compare memory and index X:
                temp = this.REG_X - this.load(addr);
                this.F_CARRY = (temp>=0?1:0);
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp&0xFF;
                break;

            case 19:

                // *******
                // * CPY *
                // *******

                // Compare memory and index Y:
                temp = this.REG_Y - this.load(addr);
                this.F_CARRY = (temp>=0?1:0);
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp&0xFF;
                break;

            case 20:

                // *******
                // * DEC *
                // *******

                // Decrement memory by one:
                temp = (this.load(addr)-1)&0xFF;
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp;
                this.write(addr, temp);
                break;

            case 21:

                // *******
                // * DEX *
                // *******

                // Decrement index X by one:
                this.REG_X = (this.REG_X-1)&0xFF;
                this.F_SIGN = (this.REG_X>>7)&1;
                this.F_ZERO = this.REG_X;
                break;

            case 22:

                // *******
                // * DEY *
                // *******

                // Decrement index Y by one:
                this.REG_Y = (this.REG_Y-1)&0xFF;
                this.F_SIGN = (this.REG_Y>>7)&1;
                this.F_ZERO = this.REG_Y;
                break;

            case 23:

                // *******
                // * EOR *
                // *******

                // XOR Memory with accumulator, store in accumulator:
                this.REG_ACC = (this.load(addr)^this.REG_ACC)&0xFF;
                this.F_SIGN = (this.REG_ACC>>7)&1;
                this.F_ZERO = this.REG_ACC;
                cycleCount+=cycleAdd;
                break;

            case 24:

                // *******
                // * INC *
                // *******

                // Increment memory by one:
                temp = (this.load(addr)+1)&0xFF;
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp;
                this.write(addr, temp&0xFF);
                break;

            case 25:

                // *******
                // * INX *
                // *******

                // Increment index X by one:
                this.REG_X = (this.REG_X+1)&0xFF;
                this.F_SIGN = (this.REG_X>>7)&1;
                this.F_ZERO = this.REG_X;
                break;

            case 26:

                // *******
                // * INY *
                // *******

                // Increment index Y by one:
                this.REG_Y++;
                this.REG_Y &= 0xFF;
                this.F_SIGN = (this.REG_Y>>7)&1;
                this.F_ZERO = this.REG_Y;
                break;

            case 27:

                // *******
                // * JMP *
                // *******

                // Jump to new location:
                this.REG_PC = addr-1;
                break;

            case 28:

                // *******
                // * JSR *
                // *******

                // Jump to new location, saving return address.
                // Push return address on stack:
                this.push((this.REG_PC>>8)&255);
                this.push(this.REG_PC&255);
                this.REG_PC = addr-1;
                break;

            case 29:

                // *******
                // * LDA *
                // *******

                // Load accumulator with memory:
                this.REG_ACC = this.load(addr);
                this.F_SIGN = (this.REG_ACC>>7)&1;
                this.F_ZERO = this.REG_ACC;
                cycleCount+=cycleAdd;
                break;

            case 30:

                // *******
                // * LDX *
                // *******

                // Load index X with memory:
                this.REG_X = this.load(addr);
                this.F_SIGN = (this.REG_X>>7)&1;
                this.F_ZERO = this.REG_X;
                cycleCount+=cycleAdd;
                break;

            case 31:

                // *******
                // * LDY *
                // *******

                // Load index Y with memory:
                this.REG_Y = this.load(addr);
                this.F_SIGN = (this.REG_Y>>7)&1;
                this.F_ZERO = this.REG_Y;
                cycleCount+=cycleAdd;
                break;

            case 32:

                // *******
                // * LSR *
                // *******

                // Shift right one bit:
                if(addrMode == 4){ // ADDR_ACC

                    temp = (this.REG_ACC & 0xFF);
                    this.F_CARRY = temp&1;
                    temp >>= 1;
                    this.REG_ACC = temp;

                }else{

                    temp = this.load(addr) & 0xFF;
                    this.F_CARRY = temp&1;
                    temp >>= 1;
                    this.write(addr, temp);

                }
                this.F_SIGN = 0;
                this.F_ZERO = temp;
                break;

            case 33:

                // *******
                // * NOP *
                // *******

                // No OPeration.
                // Ignore.
                break;

            case 34:

                // *******
                // * ORA *
                // *******

                // OR memory with accumulator, store in accumulator.
                temp = (this.load(addr)|this.REG_ACC)&255;
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp;
                this.REG_ACC = temp;
                if(addrMode!=11)cycleCount+=cycleAdd; // PostIdxInd = 11
                break;

            case 35:

                // *******
                // * PHA *
                // *******

                // Push accumulator on stack
                this.push(this.REG_ACC);
                break;

            case 36:

                // *******
                // * PHP *
                // *******

                // Push processor status on stack
                this.F_BRK = 1;
                this.push(
                    (this.F_CARRY)|
                    ((this.F_ZERO==0?1:0)<<1)|
                    (this.F_INTERRUPT<<2)|
                    (this.F_DECIMAL<<3)|
                    (this.F_BRK<<4)|
                    (this.F_NOTUSED<<5)|
                    (this.F_OVERFLOW<<6)|
                    (this.F_SIGN<<7)
                );
                break;

            case 37:

                // *******
                // * PLA *
                // *******

                // Pull accumulator from stack
                this.REG_ACC = this.pull();
                this.F_SIGN = (this.REG_ACC>>7)&1;
                this.F_ZERO = this.REG_ACC;
                break;

            case 38:

                // *******
                // * PLP *
                // *******

                // Pull processor status from stack
                temp = this.pull();
                this.F_CARRY     = (temp   )&1;
                this.F_ZERO      = (((temp>>1)&1)==1)?0:1;
                this.F_INTERRUPT = (temp>>2)&1;
                this.F_DECIMAL   = (temp>>3)&1;
                this.F_BRK       = (temp>>4)&1;
                this.F_NOTUSED   = (temp>>5)&1;
                this.F_OVERFLOW  = (temp>>6)&1;
                this.F_SIGN      = (temp>>7)&1;

                this.F_NOTUSED = 1;
                break;

            case 39:

                // *******
                // * ROL *
                // *******

                // Rotate one bit left
                if(addrMode == 4){ // ADDR_ACC = 4

                    temp = this.REG_ACC;
                    add = this.F_CARRY;
                    this.F_CARRY = (temp>>7)&1;
                    temp = ((temp<<1)&0xFF)+add;
                    this.REG_ACC = temp;

                }else{

                    temp = this.load(addr);
                    add = this.F_CARRY;
                    this.F_CARRY = (temp>>7)&1;
                    temp = ((temp<<1)&0xFF)+add;    
                    this.write(addr, temp);

                }
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp;
                break;

            case 40:

                // *******
                // * ROR *
                // *******

                // Rotate one bit right
                if(addrMode == 4){ // ADDR_ACC = 4

                    add = this.F_CARRY<<7;
                    this.F_CARRY = this.REG_ACC&1;
                    temp = (this.REG_ACC>>1)+add;   
                    this.REG_ACC = temp;

                }else{

                    temp = this.load(addr);
                    add = this.F_CARRY<<7;
                    this.F_CARRY = temp&1;
                    temp = (temp>>1)+add;
                    this.write(addr, temp);

                }
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp;
                break;

            case 41:

                // *******
                // * RTI *
                // *******

                // Return from interrupt. Pull status and PC from stack.
                
                temp = this.pull();
                this.F_CARRY     = (temp   )&1;
                this.F_ZERO      = ((temp>>1)&1)==0?1:0;
                this.F_INTERRUPT = (temp>>2)&1;
                this.F_DECIMAL   = (temp>>3)&1;
                this.F_BRK       = (temp>>4)&1;
                this.F_NOTUSED   = (temp>>5)&1;
                this.F_OVERFLOW  = (temp>>6)&1;
                this.F_SIGN      = (temp>>7)&1;

                this.REG_PC = this.pull();
                this.REG_PC += (this.pull()<<8);
                if(this.REG_PC==0xFFFF){
                    return 0;
                }
                this.REG_PC--;
                this.F_NOTUSED = 1;
                break;

            case 42:

                // *******
                // * RTS *
                // *******

                // Return from subroutine. Pull PC from stack.
                
                this.REG_PC = this.pull();
                this.REG_PC += (this.pull()<<8);
                
                if(this.REG_PC==0xFFFF){
                    return 0; // return from NSF play routine:
                }
                break;

            case 43:

                // *******
                // * SBC *
                // *******

                temp = this.REG_ACC-this.load(addr)-(1-this.F_CARRY);
                this.F_SIGN = (temp>>7)&1;
                this.F_ZERO = temp&0xFF;
                this.F_OVERFLOW = ((((this.REG_ACC^temp)&0x80)!=0 && ((this.REG_ACC^this.load(addr))&0x80)!=0)?1:0);
                this.F_CARRY = (temp<0?0:1);
                this.REG_ACC = (temp&0xFF);
                if(addrMode!=11)cycleCount+=cycleAdd; // PostIdxInd = 11
                break;

            case 44:

                // *******
                // * SEC *
                // *******

                // Set carry flag
                this.F_CARRY = 1;
                break;

            case 45:

                // *******
                // * SED *
                // *******

                // Set decimal mode
                this.F_DECIMAL = 1;
                break;

            case 46:

                // *******
                // * SEI *
                // *******

                // Set interrupt disable status
                this.F_INTERRUPT = 1;
                break;

            case 47:

                // *******
                // * STA *
                // *******

                // Store accumulator in memory
                this.write(addr, this.REG_ACC);
                break;

            case 48:

                // *******
                // * STX *
                // *******

                // Store index X in memory
                this.write(addr, this.REG_X);
                break;

            case 49:

                // *******
                // * STY *
                // *******

                // Store index Y in memory:
                this.write(addr, this.REG_Y);
                break;

            case 50:

                // *******
                // * TAX *
                // *******

                // Transfer accumulator to index X:
                this.REG_X = this.REG_ACC;
                this.F_SIGN = (this.REG_ACC>>7)&1;
                this.F_ZERO = this.REG_ACC;
                break;

            case 51:

                // *******
                // * TAY *
                // *******

                // Transfer accumulator to index Y:
                this.REG_Y = this.REG_ACC;
                this.F_SIGN = (this.REG_ACC>>7)&1;
                this.F_ZERO = this.REG_ACC;
                break;

            case 52:

                // *******
                // * TSX *
                // *******

                // Transfer stack pointer to index X:
                this.REG_X = (this.REG_SP-0x0100);
                this.F_SIGN = (this.REG_SP>>7)&1;
                this.F_ZERO = this.REG_X;
                break;

            case 53:

                // *******
                // * TXA *
                // *******

                // Transfer index X to accumulator:
                this.REG_ACC = this.REG_X;
                this.F_SIGN = (this.REG_X>>7)&1;
                this.F_ZERO = this.REG_X;
                break;

            case 54:

                // *******
                // * TXS *
                // *******

                // Transfer index X to stack pointer:
                this.REG_SP = (this.REG_X+0x0100);
                this.stackWrap();
                break;

            case 55:

                // *******
                // * TYA *
                // *******

                // Transfer index Y to accumulator:
                this.REG_ACC = this.REG_Y;
                this.F_SIGN = (this.REG_Y>>7)&1;
                this.F_ZERO = this.REG_Y;
                break;

            default:

                // *******
                // * ??? *
                // *******

                this.nes.stop();
//                this.nes.crashMessage = "Game crashed, invalid opcode at address $"+opaddr.toString(16);
                break;

        }// end of switch

        return cycleCount;

    }
    
    int load(int addr) {
        if (addr < 0x2000) {
            return this.mem[addr & 0x7FF];
        }
        else {
            return this.nes.mmap.load(addr);
        }
    }
    
    int load16bit(int addr){
        assert(addr is int);
        
        if (addr < 0x1FFF) {
            return this.mem[addr&0x7FF] 
                | (this.mem[(addr+1)&0x7FF]<<8);
        }
        else {
            return this.nes.mmap.load(addr) | (this.nes.mmap.load(addr+1) << 8);
        }
    }
    
    void write(int addr, int val){
        assert(addr is int);
        assert(val is int);
        
        if(addr < 0x2000) {
            this.mem[addr&0x7FF] = val;
        }
        else {
            this.nes.mmap.write(addr,val);
        }
    }

    void requestIrq(int type){
        assert(type is int);
        
        if(this.irqRequested){
            if(type == CPU.IRQ_NORMAL){
                return;
            }
            ////System.out.println("too fast irqs. type="+type);
        }
        this.irqRequested = true;
        this.irqType = type;
    }

    void push(int value){
        assert(value is int);
        
        this.nes.mmap.write(this.REG_SP, value);
        this.REG_SP--;
        this.REG_SP = 0x0100 | (this.REG_SP&0xFF);
    }

    void stackWrap(){
        this.REG_SP = 0x0100 | (this.REG_SP&0xFF);
    }

    int pull(){
        this.REG_SP++;
        this.REG_SP = 0x0100 | (this.REG_SP&0xFF);
        return this.nes.mmap.load(this.REG_SP);
    }

    bool pageCrossed(int addr1, int addr2){
        assert(addr1 is int);
        assert(addr2 is int);
        
        return ((addr1&0xFF00) != (addr2&0xFF00));
    }

    void haltCycles(int cycles){
        assert(cycles is int);
        
        this.cyclesToHalt += cycles;
    }

    void doNonMaskableInterrupt(int status){
        assert(status is int);
        
        if((this.nes.mmap.load(0x2000) & 128) != 0) { // Check whether VBlank Interrupts are enabled
            this.REG_PC_NEW++;
            this.push((this.REG_PC_NEW>>8)&0xFF);
            this.push(this.REG_PC_NEW&0xFF);
            //this.F_INTERRUPT_NEW = 1;
            this.push(status);

            this.REG_PC_NEW = this.nes.mmap.load(0xFFFA) | (this.nes.mmap.load(0xFFFB) << 8);
            this.REG_PC_NEW--;
        }
    }

    void doResetInterrupt(){
        this.REG_PC_NEW = this.nes.mmap.load(0xFFFC) | (this.nes.mmap.load(0xFFFD) << 8);
        this.REG_PC_NEW--;
    }

    void doIrq(int status){
        assert(status is int);
        
        this.REG_PC_NEW++;
        this.push((this.REG_PC_NEW>>8)&0xFF);
        this.push(this.REG_PC_NEW&0xFF);
        this.push(status);
        this.F_INTERRUPT_NEW = 1;
        this.F_BRK_NEW = 0;

        this.REG_PC_NEW = this.nes.mmap.load(0xFFFE) | (this.nes.mmap.load(0xFFFF) << 8);
        this.REG_PC_NEW--;
    }

    int getStatus(){
        return (this.F_CARRY)
                |(this.F_ZERO<<1)
                |(this.F_INTERRUPT<<2)
                |(this.F_DECIMAL<<3)
                |(this.F_BRK<<4)
                |(this.F_NOTUSED<<5)
                |(this.F_OVERFLOW<<6)
                |(this.F_SIGN<<7);
    }

    void setStatus(int st){
        assert(st is int);
        
        this.F_CARRY     = (st   )&1;
        this.F_ZERO      = (st>>1)&1;
        this.F_INTERRUPT = (st>>2)&1;
        this.F_DECIMAL   = (st>>3)&1;
        this.F_BRK       = (st>>4)&1;
        this.F_NOTUSED   = (st>>5)&1;
        this.F_OVERFLOW  = (st>>6)&1;
        this.F_SIGN      = (st>>7)&1;
    }
/*
    String toJSON() {
        return Utils.toJSON(this);
    }
    
    void fromJSON(s) {
        Utils.fromJSON(this, s);
    }
*/
}


  // Generates and provides an array of details about instructions
class CPU_OpData {
  static const int INS_ADC = 0;
  static const int INS_AND = 1;
  static const int INS_ASL = 2;
  
  static const int INS_BCC = 3;
  static const int INS_BCS = 4;
  static const int INS_BEQ = 5;
  static const int INS_BIT = 6;
  static const int INS_BMI = 7;
  static const int INS_BNE = 8;
  static const int INS_BPL = 9;
  static const int INS_BRK = 10;
  static const int INS_BVC = 11;
  static const int INS_BVS = 12;
  
  static const int INS_CLC = 13;
  static const int INS_CLD = 14;
  static const int INS_CLI = 15;
  static const int INS_CLV = 16;
  static const int INS_CMP = 17;
  static const int INS_CPX = 18;
  static const int INS_CPY = 19;
  
  static const int INS_DEC = 20;
  static const int INS_DEX = 21;
  static const int INS_DEY = 22;
  
  static const int INS_EOR = 23;
  
  static const int INS_INC = 24;
  static const int INS_INX = 25;
  static const int INS_INY = 26;
  
  static const int INS_JMP = 27;
  static const int INS_JSR = 28;
  
  static const int INS_LDA = 29;
  static const int INS_LDX = 30;
  static const int INS_LDY = 31;
  static const int INS_LSR = 32;
  
  static const int INS_NOP = 33;
  
  static const int INS_ORA = 34;
  
  static const int INS_PHA = 35;
  static const int INS_PHP = 36;
  static const int INS_PLA = 37;
  static const int INS_PLP = 38;
  
  static const int INS_ROL = 39;
  static const int INS_ROR = 40;
  static const int INS_RTI = 41;
  static const int INS_RTS = 42;
  
  static const int INS_SBC = 43;
  static const int INS_SEC = 44;
  static const int INS_SED = 45;
  static const int INS_SEI = 46;
  static const int INS_STA = 47;
  static const int INS_STX = 48;
  static const int INS_STY = 49;
  
  static const int INS_TAX = 50;
  static const int INS_TAY = 51;
  static const int INS_TSX = 52;
  static const int INS_TXA = 53;
  static const int INS_TXS = 54;
  static const int INS_TYA = 55;
  
  static const int INS_DUMMY = 56; // dummy instruction used for 'halting' the processor some cycles
  
  // -------------------------------- //
  
  // Addressing modes:
  static const int ADDR_ZP        = 0;
  static const int ADDR_REL       = 1;
  static const int ADDR_IMP       = 2;
  static const int ADDR_ABS       = 3;
  static const int ADDR_ACC       = 4;
  static const int ADDR_IMM       = 5;
  static const int ADDR_ZPX       = 6;
  static const int ADDR_ZPY       = 7;
  static const int ADDR_ABSX      = 8;
  static const int ADDR_ABSY      = 9;
  static const int ADDR_PREIDXIND = 10;
  static const int ADDR_POSTIDXIND= 11;
  static const int ADDR_INDABS    = 12;
  
  static List<List<int>> createOpData() {
    List<List<int>> opdata = new List<List<int>>(256);
      
      // Now fill in all valid opcodes:
      
      // ADC:
      opdata[0x69] = [INS_ADC, ADDR_IMM, 2, 2];
      opdata[0x65] = [INS_ADC, ADDR_ZP, 2, 3];
      opdata[0x75] = [INS_ADC, ADDR_ZPX, 2, 4];
      opdata[0x6D] = [INS_ADC, ADDR_ABS, 3, 4];
      opdata[0x7D] = [INS_ADC, ADDR_ABSX, 3, 4];
      opdata[0x79] = [INS_ADC, ADDR_ABSY, 3, 4];
      opdata[0x61] = [INS_ADC, ADDR_PREIDXIND, 2, 6];
      opdata[0x71] = [INS_ADC, ADDR_POSTIDXIND, 2, 5];
      
      // AND:
      opdata[0x29] = [INS_AND, ADDR_IMM, 2, 2];
      opdata[0x25] = [INS_AND, ADDR_ZP, 2, 3];
      opdata[0x35] = [INS_AND, ADDR_ZPX, 2, 4];
      opdata[0x2D] = [INS_AND, ADDR_ABS, 3, 4];
      opdata[0x3D] = [INS_AND, ADDR_ABSX, 3, 4];
      opdata[0x39] = [INS_AND, ADDR_ABSY, 3, 4];
      opdata[0x21] = [INS_AND, ADDR_PREIDXIND, 2, 6];
      opdata[0x31] = [INS_AND, ADDR_POSTIDXIND, 2, 5];
      
      // ASL:
      opdata[0x0A] = [INS_ASL, ADDR_ACC, 1, 2];
      opdata[0x06] = [INS_ASL, ADDR_ZP, 2, 5];
      opdata[0x16] = [INS_ASL, ADDR_ZPX, 2, 6];
      opdata[0x0E] = [INS_ASL, ADDR_ABS, 3, 6];
      opdata[0x1E] = [INS_ASL, ADDR_ABSX, 3, 7];
      
      // BCC:
      opdata[0x90] = [INS_BCC, ADDR_REL, 2, 2];
      
      // BCS:
      opdata[0xB0] = [INS_BCS, ADDR_REL, 2, 2];
      
      // BEQ:
      opdata[0xF0] = [INS_BEQ, ADDR_REL, 2, 2];
      
      // BIT:
      opdata[0x24] = [INS_BIT, ADDR_ZP, 2, 3];
      opdata[0x2C] = [INS_BIT, ADDR_ABS, 3, 4];
      
      // BMI:
      opdata[0x30] = [INS_BMI, ADDR_REL, 2, 2];
      
      // BNE:
      opdata[0xD0] = [INS_BNE, ADDR_REL, 2, 2];
      
      // BPL:
      opdata[0x10] = [INS_BPL, ADDR_REL, 2, 2];
      
      // BRK:
      opdata[0x00] = [INS_BRK, ADDR_IMP, 1, 7];
      
      // BVC:
      opdata[0x50] = [INS_BVC, ADDR_REL, 2, 2];
      
      // BVS:
      opdata[0x70] = [INS_BVS, ADDR_REL, 2, 2];
      
      // CLC:
      opdata[0x18] = [INS_CLC, ADDR_IMP, 1, 2];
      
      // CLD:
      opdata[0xD8] = [INS_CLD, ADDR_IMP, 1, 2];
      
      // CLI:
      opdata[0x58] = [INS_CLI, ADDR_IMP, 1, 2];
      
      // CLV:
      opdata[0xB8] = [INS_CLV, ADDR_IMP, 1, 2];
      
      // CMP:
      opdata[0xC9] = [INS_CMP, ADDR_IMM, 2, 2];
      opdata[0xC5] = [INS_CMP, ADDR_ZP, 2, 3];
      opdata[0xD5] = [INS_CMP, ADDR_ZPX, 2, 4];
      opdata[0xCD] = [INS_CMP, ADDR_ABS, 3, 4];
      opdata[0xDD] = [INS_CMP, ADDR_ABSX, 3, 4];
      opdata[0xD9] = [INS_CMP, ADDR_ABSY, 3, 4];
      opdata[0xC1] = [INS_CMP, ADDR_PREIDXIND, 2, 6];
      opdata[0xD1] = [INS_CMP, ADDR_POSTIDXIND, 2, 5];
      
      // CPX:
      opdata[0xE0] = [INS_CPX, ADDR_IMM, 2, 2];
      opdata[0xE4] = [INS_CPX, ADDR_ZP, 2, 3];
      opdata[0xEC] = [INS_CPX, ADDR_ABS, 3, 4];
      
      // CPY:
      opdata[0xC0] = [INS_CPY, ADDR_IMM, 2, 2];
      opdata[0xC4] = [INS_CPY, ADDR_ZP, 2, 3];
      opdata[0xCC] = [INS_CPY, ADDR_ABS, 3, 4];
      
      // DEC:
      opdata[0xC6] = [INS_DEC, ADDR_ZP, 2, 5];
      opdata[0xD6] = [INS_DEC, ADDR_ZPX, 2, 6];
      opdata[0xCE] = [INS_DEC, ADDR_ABS, 3, 6];
      opdata[0xDE] = [INS_DEC, ADDR_ABSX, 3, 7];
      
      // DEX:
      opdata[0xCA] = [INS_DEX, ADDR_IMP, 1, 2];
      
      // DEY:
      opdata[0x88] = [INS_DEY, ADDR_IMP, 1, 2];
      
      // EOR:
      opdata[0x49] = [INS_EOR, ADDR_IMM, 2, 2];
      opdata[0x45] = [INS_EOR, ADDR_ZP, 2, 3];
      opdata[0x55] = [INS_EOR, ADDR_ZPX, 2, 4];
      opdata[0x4D] = [INS_EOR, ADDR_ABS, 3, 4];
      opdata[0x5D] = [INS_EOR, ADDR_ABSX, 3, 4];
      opdata[0x59] = [INS_EOR, ADDR_ABSY, 3, 4];
      opdata[0x41] = [INS_EOR, ADDR_PREIDXIND, 2, 6];
      opdata[0x51] = [INS_EOR, ADDR_POSTIDXIND, 2, 5];
      
      // INC:
      opdata[0xE6] = [INS_INC, ADDR_ZP, 2, 5];
      opdata[0xF6] = [INS_INC, ADDR_ZPX, 2, 6];
      opdata[0xEE] = [INS_INC, ADDR_ABS, 3, 6];
      opdata[0xFE] = [INS_INC, ADDR_ABSX, 3, 7];
      
      // INX:
      opdata[0xE8] = [INS_INX, ADDR_IMP, 1, 2];
      
      // INY:
      opdata[0xC8] = [INS_INY, ADDR_IMP, 1, 2];
      
      // JMP:
      opdata[0x4C] = [INS_JMP, ADDR_ABS, 3, 3];
      opdata[0x6C] = [INS_JMP, ADDR_INDABS, 3, 5];
      
      // JSR:
      opdata[0x20] = [INS_JSR, ADDR_ABS, 3, 6];
      
      // LDA:
      opdata[0xA9] = [INS_LDA, ADDR_IMM, 2, 2];
      opdata[0xA5] = [INS_LDA, ADDR_ZP, 2, 3];
      opdata[0xB5] = [INS_LDA, ADDR_ZPX, 2, 4];
      opdata[0xAD] = [INS_LDA, ADDR_ABS, 3, 4];
      opdata[0xBD] = [INS_LDA, ADDR_ABSX, 3, 4];
      opdata[0xB9] = [INS_LDA, ADDR_ABSY, 3, 4];
      opdata[0xA1] = [INS_LDA, ADDR_PREIDXIND, 2, 6];
      opdata[0xB1] = [INS_LDA, ADDR_POSTIDXIND, 2, 5];
      
      
      // LDX:
      opdata[0xA2] = [INS_LDX, ADDR_IMM, 2, 2];
      opdata[0xA6] = [INS_LDX, ADDR_ZP, 2, 3];
      opdata[0xB6] = [INS_LDX, ADDR_ZPY, 2, 4];
      opdata[0xAE] = [INS_LDX, ADDR_ABS, 3, 4];
      opdata[0xBE] = [INS_LDX, ADDR_ABSY, 3, 4];
      
      // LDY:
      opdata[0xA0] = [INS_LDY, ADDR_IMM, 2, 2];
      opdata[0xA4] = [INS_LDY, ADDR_ZP, 2, 3];
      opdata[0xB4] = [INS_LDY, ADDR_ZPX, 2, 4];
      opdata[0xAC] = [INS_LDY, ADDR_ABS, 3, 4];
      opdata[0xBC] = [INS_LDY, ADDR_ABSX, 3, 4];
      
      // LSR:
      opdata[0x4A] = [INS_LSR, ADDR_ACC, 1, 2];
      opdata[0x46] = [INS_LSR, ADDR_ZP, 2, 5];
      opdata[0x56] = [INS_LSR, ADDR_ZPX, 2, 6];
      opdata[0x4E] = [INS_LSR, ADDR_ABS, 3, 6];
      opdata[0x5E] = [INS_LSR, ADDR_ABSX, 3, 7];
      
      // NOP:
      opdata[0xEA] = [INS_NOP, ADDR_IMP, 1, 2];
      
      // ORA:
      opdata[0x09] = [INS_ORA, ADDR_IMM, 2, 2];
      opdata[0x05] = [INS_ORA, ADDR_ZP, 2, 3];
      opdata[0x15] = [INS_ORA, ADDR_ZPX, 2, 4];
      opdata[0x0D] = [INS_ORA, ADDR_ABS, 3, 4];
      opdata[0x1D] = [INS_ORA, ADDR_ABSX, 3, 4];
      opdata[0x19] = [INS_ORA, ADDR_ABSY, 3, 4];
      opdata[0x01] = [INS_ORA, ADDR_PREIDXIND, 2, 6];
      opdata[0x11] = [INS_ORA, ADDR_POSTIDXIND, 2, 5];
      
      // PHA:
      opdata[0x48] = [INS_PHA, ADDR_IMP, 1, 3];
      
      // PHP:
      opdata[0x08] = [INS_PHP, ADDR_IMP, 1, 3];
      
      // PLA:
      opdata[0x68] = [INS_PLA, ADDR_IMP, 1, 4];
      
      // PLP:
      opdata[0x28] = [INS_PLP, ADDR_IMP, 1, 4];
      
      // ROL:
      opdata[0x2A] = [INS_ROL, ADDR_ACC, 1, 2];
      opdata[0x26] = [INS_ROL, ADDR_ZP, 2, 5];
      opdata[0x36] = [INS_ROL, ADDR_ZPX, 2, 6];
      opdata[0x2E] = [INS_ROL, ADDR_ABS, 3, 6];
      opdata[0x3E] = [INS_ROL, ADDR_ABSX, 3, 7];
      
      // ROR:
      opdata[0x6A] = [INS_ROR, ADDR_ACC, 1, 2];
      opdata[0x66] = [INS_ROR, ADDR_ZP, 2, 5];
      opdata[0x76] = [INS_ROR, ADDR_ZPX, 2, 6];
      opdata[0x6E] = [INS_ROR, ADDR_ABS, 3, 6];
      opdata[0x7E] = [INS_ROR, ADDR_ABSX, 3, 7];
      
      // RTI:
      opdata[0x40] = [INS_RTI, ADDR_IMP, 1, 6];
      
      // RTS:
      opdata[0x60] = [INS_RTS, ADDR_IMP, 1, 6];
      
      // SBC:
      opdata[0xE9] = [INS_SBC, ADDR_IMM, 2, 2];
      opdata[0xE5] = [INS_SBC, ADDR_ZP, 2, 3];
      opdata[0xF5] = [INS_SBC, ADDR_ZPX, 2, 4];
      opdata[0xED] = [INS_SBC, ADDR_ABS, 3, 4];
      opdata[0xFD] = [INS_SBC, ADDR_ABSX, 3, 4];
      opdata[0xF9] = [INS_SBC, ADDR_ABSY, 3, 4];
      opdata[0xE1] = [INS_SBC, ADDR_PREIDXIND, 2, 6];
      opdata[0xF1] = [INS_SBC, ADDR_POSTIDXIND, 2, 5];
      
      // SEC:
      opdata[0x38] = [INS_SEC, ADDR_IMP, 1, 2];
      
      // SED:
      opdata[0xF8] = [INS_SED, ADDR_IMP, 1, 2];
      
      // SEI:
      opdata[0x78] = [INS_SEI, ADDR_IMP, 1, 2];
      
      // STA:
      opdata[0x85] = [INS_STA, ADDR_ZP, 2, 3];
      opdata[0x95] = [INS_STA, ADDR_ZPX, 2, 4];
      opdata[0x8D] = [INS_STA, ADDR_ABS, 3, 4];
      opdata[0x9D] = [INS_STA, ADDR_ABSX, 3, 5];
      opdata[0x99] = [INS_STA, ADDR_ABSY, 3, 5];
      opdata[0x81] = [INS_STA, ADDR_PREIDXIND, 2, 6];
      opdata[0x91] = [INS_STA, ADDR_POSTIDXIND, 2, 6];
      
      // STX:
      opdata[0x86] = [INS_STX, ADDR_ZP, 2, 3];
      opdata[0x96] = [INS_STX, ADDR_ZPY, 2, 4];
      opdata[0x8E] = [INS_STX, ADDR_ABS, 3, 4];
      
      // STY:
      opdata[0x84] = [INS_STY, ADDR_ZP, 2, 3];
      opdata[0x94] = [INS_STY, ADDR_ZPX, 2, 4];
      opdata[0x8C] = [INS_STY, ADDR_ABS, 3, 4];
      
      // TAX:
      opdata[0xAA] = [INS_TAX, ADDR_IMP, 1, 2];
      
      // TAY:
      opdata[0xA8] = [INS_TAY, ADDR_IMP, 1, 2];
      
      // TSX:
      opdata[0xBA] = [INS_TSX, ADDR_IMP, 1, 2];
      
      // TXA:
      opdata[0x8A] = [INS_TXA, ADDR_IMP, 1, 2];
      
      // TXS:
      opdata[0x9A] = [INS_TXS, ADDR_IMP, 1, 2];
      
      // TYA:
      opdata[0x98] = [INS_TYA, ADDR_IMP, 1, 2];
      
      return opdata;
  }
}
