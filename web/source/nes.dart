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

library dartnes_nes;
import 'dart:async';
import 'dart:core';

import 'cpu.dart';
import 'ppu.dart';
import 'papu.dart';
import 'mappers.dart';
import 'keyboard.dart';
import 'rom.dart';


class NES {    
    Map opts = null;
    double frameTime = 0.0;
    String crashMessage = null;
    
    CPU cpu = null;
    PPU ppu = null;
    PAPU papu = null;
    MapperDefault mmap = null;
    Keyboard keyboard = null;
    
    var status_cb = null;
    var frame_cb = null;
    var audio_cb = null;
    
    bool isRunning = false;
    int fpsFrameCount = 0;
    int lastFrameTime = 0;
    int lastFpsTime = 0;
    String romData = null;
    ROM rom = null;
    Timer frameInterval = null;
    Timer fpsInterval = null;
    
    NES(void status_cb(String m), void frame_cb(List<int> bytes), void audio_cb(List<int> samples)) {
      this.status_cb = status_cb;
      this.frame_cb = frame_cb;
      this.audio_cb = audio_cb;
      
      this.opts = {
          'swfPath': 'lib/',
          
          'preferredFrameRate': 60,
          'fpsInterval': 500, // Time between updating FPS in ms
          'showDisplay': true,
          
          'emulateSound': false,
          'sampleRate': 44100, // Sound sample rate in hz
          
          'CPU_FREQ_NTSC': 1789772.5, //1789772.72727272d;
          'CPU_FREQ_PAL': 1773447.4
      };
      
      this.frameTime = 1000 / this.opts['preferredFrameRate'];
      
      this.cpu = new CPU(this);
      this.ppu = new PPU(this);
      this.papu = new PAPU(this);
      this.mmap = null; // set in loadRom()
      this.keyboard = new Keyboard();
    }

    // Resets the system
    void reset() {
        if (this.mmap != null) {
            this.mmap.reset();
        }
        
        this.cpu.reset();
        this.ppu.reset();
        this.papu.reset();
    }
    
    void start() {
        if (this.rom != null && this.rom.valid) {
            if (!this.isRunning) {
                this.isRunning = true;
                
                Duration dur = new Duration(milliseconds: this.frameTime.toInt());
                this.frameInterval = new Timer.periodic(dur, (Timer timer) {
                  this.frame();
                });
                this.resetFps();
                this.printFps();
                dur = new Duration(milliseconds: this.opts['fpsInterval']);
                this.fpsInterval = new Timer.periodic(dur, (Timer timer) {
                  this.printFps();
                });
            }
        }
        else {
            this.status_cb("There is no ROM loaded, or it is invalid.");
        }
    }
    
    void frame() {
        this.ppu.startFrame();
        int cycles = 0;
        bool emulateSound = this.opts['emulateSound'];
        CPU cpu = this.cpu;
        PPU ppu = this.ppu;
        PAPU papu = this.papu;
        FRAMELOOP: for (;;) {
            if (cpu.cyclesToHalt == 0) {
                // Execute a CPU instruction
                cycles = cpu.emulate();
                if (emulateSound) {
                    papu.clockFrameCounter(cycles);
                }
                cycles *= 3;
            }
            else {
                if (cpu.cyclesToHalt > 8) {
                    cycles = 24;
                    if (emulateSound) {
                        papu.clockFrameCounter(8);
                    }
                    cpu.cyclesToHalt -= 8;
                }
                else {
                    cycles = cpu.cyclesToHalt * 3;
                    if (emulateSound) {
                        papu.clockFrameCounter(cpu.cyclesToHalt);
                    }
                    cpu.cyclesToHalt = 0;
                }
            }
            
            for (; cycles > 0; cycles--) {
                if(ppu.curX == ppu.spr0HitX &&
                        ppu.f_spVisibility == 1 &&
                        ppu.scanline - 21 == ppu.spr0HitY) {
                    // Set sprite 0 hit flag:
                    ppu.setStatusFlag(PPU.STATUS_SPRITE0HIT, true);
                }

                if (ppu.requestEndFrame) {
                    ppu.nmiCounter--;
                    if (ppu.nmiCounter == 0) {
                        ppu.requestEndFrame = false;
                        ppu.startVBlank();
                        break FRAMELOOP;
                    }
                }

                ppu.curX++;
                if (ppu.curX == 341) {
                    ppu.curX = 0;
                    ppu.endScanline();
                }
            }
        }
        this.fpsFrameCount++;
        this.lastFrameTime = new DateTime.now().millisecondsSinceEpoch;
    }
    
    void printFps() {
        int now = new DateTime.now().millisecondsSinceEpoch;
        String s = 'Running';
        if (this.lastFpsTime > 0) {
            s += ': ' + (
                this.fpsFrameCount / ((now - this.lastFpsTime) / 1000)
            ).toStringAsFixed(1) + ' FPS';
        }
        this.status_cb(s);
        this.fpsFrameCount = 0;
        this.lastFpsTime = now;
    }
    
    void stop() {
        this.frameInterval.cancel();
        this.fpsInterval.cancel();
        this.isRunning = false;
    }
    
    void reloadRom() {
        if (this.romData != null) {
            this.loadRom(this.romData);
        }
    }
    
    // Loads a ROM file into the CPU and PPU.
    // The ROM file is validated first.
    bool loadRom(String data) {
        assert(data is String);
        
        if (this.isRunning) {
            this.stop();
        }
        
        this.status_cb("Loading ROM...");
        
        // Load ROM file:
        this.rom = new ROM(this);
        this.rom.load(data);
        
        if (this.rom.valid) {
            this.reset();
            this.mmap = this.rom.createMapper();
            if (this.mmap == null) {
                return false;
            }
            this.mmap.loadROM();
            this.ppu.setMirroring(this.rom.getMirroringType());
            this.romData = data;
            
            this.status_cb("Successfully loaded. Ready to be started.");
        }
        else {
            this.status_cb("Invalid ROM!");
        }
        return this.rom.valid;
    }
    
    void resetFps() {
        this.lastFpsTime = 0;
        this.fpsFrameCount = 0;
    }
    
    void setFramerate(int rate) {
        assert(rate is int);
        
        this.opts['preferredFrameRate']= rate;
        this.frameTime = 1000 / rate;
//        this.papu.setSampleRate(this.opts['sampleRate'], false);
    }
/*    
    String toJSON() {
        return {
            'romData': this.romData,
            'cpu': this.cpu.toJSON(),
            'mmap': this.mmap.toJSON(),
            'ppu': this.ppu.toJSON()
        };
    }
    
    void fromJSON(String s) {
        this.loadRom(s.romData);
        this.cpu.fromJSON(s.cpu);
        this.mmap.fromJSON(s.mmap);
        this.ppu.fromJSON(s.ppu);
    }
*/
}


