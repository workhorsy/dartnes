/*
JSNES, based on Jamie Sanders' vNES
Copyright (C) 2010 Ben Firshman

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

import 'dart:async';

import 'ui.dart';
import 'cpu.dart';
import 'ppu.dart';
import 'papu.dart';
import 'mappers.dart';
import 'keyboard.dart';
import 'rom.dart';

class JSNES_NES {
//JSNES.VERSION = "<%= version %>";
  
    Map opts;
    double frameTime;
    String crashMessage;
    
    JSNES_UI ui;
    JSNES_CPU cpu;
    JSNES_PPU ppu;
    JSNES_PAPU papu;
    JSNES_Mapper mmap;
    JSNES_Keyboard keyboard;
    
    bool isRunning;
    int fpsFrameCount;
    bool limitFrames;
    lastFrameTime;
    lastFpsTime;
    romData = null;
    JSNES_ROM rom;
    Future frameInterval;
    Future fpsInterval;
    
    
    JSNES_NES(Map opts) {
      this.opts = {
          'ui': JSNES_DummyUI,
          'swfPath': 'lib/',
          
          'preferredFrameRate': 60,
          'fpsInterval': 500, // Time between updating FPS in ms
          'showDisplay': true,
  
          'emulateSound': false,
          'sampleRate': 44100, // Sound sample rate in hz
          
          'CPU_FREQ_NTSC': 1789772.5, //1789772.72727272d;
          'CPU_FREQ_PAL': 1773447.4
      };
      if (opts != null) {
          var key;
          for (key in this.opts) {
              if (opts[key] != null) {
                  this.opts[key] = opts[key];
              }
          }
      }
      
      this.frameTime = 1000 / this.opts['preferredFrameRate'];
      
      this.ui = new JSNES_UI(this);
      this.cpu = new JSNES_CPU(this);
      this.ppu = new JSNES_PPU(this);
      this.papu = new JSNES_PAPU(this);
      this.mmap = null; // set in loadRom()
      this.keyboard = new JSNES_Keyboard();
      
      this.ui.updateStatus("Ready to load a ROM.");
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
        var self = this;
        
        if (this.rom != null && this.rom.valid) {
            if (!this.isRunning) {
                this.isRunning = true;
                
                this.frameInterval = new Future.delayed(const Duration(milliseconds: this.frameTime / 2), () {
                    self.frame();
                });
                this.resetFps();
                this.printFps();
                this.fpsInterval = new Future.delayed(const Duration(milliseconds: this.opts['fpsInterval']), () {
                    self.printFps();
                });
            }
        }
        else {
            this.ui.updateStatus("There is no ROM loaded, or it is invalid.");
        }
    }
    
    void frame() {
        this.ppu.startFrame();
        var cycles = 0;
        var emulateSound = this.opts['emulateSound'];
        var cpu = this.cpu;
        var ppu = this.ppu;
        var papu = this.papu;
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
                    ppu.setStatusFlag(ppu.STATUS_SPRITE0HIT, true);
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
        if (this.limitFrames) {
            if (this.lastFrameTime) {
                while (DateTime.now().value - this.lastFrameTime < this.frameTime) {
                    // twiddle thumbs
                }
            }
        }
        this.fpsFrameCount++;
        this.lastFrameTime = DateTime.now();
    }
    
    void printFps() {
        var now = DateTime.now();
        var s = 'Running';
        if (this.lastFpsTime) {
            s += ': '+(
                this.fpsFrameCount / ((now - this.lastFpsTime) / 1000)
            ).toFixed(2)+' FPS';
        }
        this.ui.updateStatus(s);
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
    void loadRom(data) {
        if (this.isRunning) {
            this.stop();
        }
        
        this.ui.updateStatus("Loading ROM...");
        
        // Load ROM file:
        this.rom = new JSNES_ROM(this);
        this.rom.load(data);
        
        if (this.rom.valid) {
            this.reset();
            this.mmap = this.rom.createMapper();
            if (!this.mmap) {
                return;
            }
            this.mmap.loadROM();
            this.ppu.setMirroring(this.rom.getMirroringType());
            this.romData = data;
            
            this.ui.updateStatus("Successfully loaded. Ready to be started.");
        }
        else {
            this.ui.updateStatus("Invalid ROM!");
        }
        return this.rom.valid;
    }
    
    void resetFps() {
        this.lastFpsTime = null;
        this.fpsFrameCount = 0;
    }
    
    void setFramerate(rate) {
        this.opts['preferredFrameRate']= rate;
        this.frameTime = 1000 / rate;
        this.papu.setSampleRate(this.opts.sampleRate, false);
    }
    
    void setLimitFrames(limit) {
        this.limitFrames = limit;
        this.lastFrameTime = null;
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
