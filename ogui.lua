--[[
╔══════════════════════════════════════════════════════════════════╗
║  OGui  —  Original Game UI Control                              ║
║  by Ferris                                                       ║
║  https://github.com/ferri                                        ║
╚══════════════════════════════════════════════════════════════════╝

  Granular per-element visibility control for native FFXI UI frames.
  Toggle party lists, target UI, and chat windows individually with
  a clean ImGui menu or simple slash commands.

  Derived from the original hideparty addon by atom0s, extended with:
    • Per-element granular control (party, target, chat1, chat2)
    • Fishing HP bar workaround (party0 auto-shows on hook, hides on end)
    • Chat window toggle support (discovered via live memory scan)
    • Target bar layout pinning (prevents shift when party is hidden)
    • Custom 3D sprite cursors when the native target bar is hidden
      (D3D8 world-to-screen overlay, adapted from customtarget by Jyouya)
    • Diagnostic scan/test tools for future pointer discovery
    • Settings persistence across sessions

  POINTER MAP  (FFXiMain.dll — discovered via live memory scan)
  ─────────────────────────────────────────────────────────────
  Pattern 1: '66C78182000000????C7818C000000????????C781900000'
    ptr1+0x0F  chat1   Main chat / log window
    ptr1+0x19  party0  Native party list A  +  fishing HP bar  (bundled)
    ptr1+0x23  target  Target bar, subtarget bar, selection cursors,
                       conquest / imperial standing, and misc elements
    ptr1+0x2D  unk2D   Unidentified
    ptr1+0x37  chat2   Second chat / log window
    ptr1+0x41  unk41   Unidentified
    ptr1+0x4B  unk4B   Unidentified
    ptr1+0x55  unk55   Unidentified
    ptr1+0x5F  unk5F   Unidentified
    ptr1+0x69  unk69   Unidentified
    ptr1+0x73  unk73   Unidentified
    ptr1+0x7D  unk7D   Unidentified
    ptr1+0x87  unk87   Unidentified
    ptr1+0x91  unk91   Unidentified

  Pattern 2: 'A1????????8B0D????????89442424A1????????33DB89'
    ptr2+0x01  party1  Alliance party B
    ptr2+0x07  party2  Alliance party C

  FISHING WORKAROUND
  ─────────────────────────────────────────────────────────────
  The fishing HP bar is owned by the party0 primitive container and
  cannot be addressed independently. When a hook message is detected
  via text_in (using anglin's exact message list and color-strip
  method), party0 is forced visible so the bar appears. It re-hides
  automatically once the player's entity status returns to 0.

  COMMANDS
  ─────────────────────────────────────────────────────────────
  /ogui               Open / close the settings window
  /ogui on            Activate hiding (applies your configured choices)
  /ogui off           Deactivate hiding (all elements visible)
  /ogui info          Print current pointer addresses and state
  /ogui scan          Scan ptr1 area for primitive pointers (debug)
  /ogui test <N>      Toggle visibility of Nth scanned pointer (debug)
  /ogui testall       Restore all debug-hidden pointers

  License: GNU General Public License v3
  Original hideparty: Copyright (c) 2023 Ashita Development Team
--]]

addon.name    = 'ogui';
addon.author  = 'Ferris';
addon.version = '1.0';
addon.desc    = 'OGui - Per-element visibility control for native FFXI UI frames.';
addon.link    = 'https://github.com/ferri';

require('common');
local chat     = require('chat');
local imgui    = require('imgui');
local settings = require('settings');
local d3d      = require('d3d8');
local ffi      = require('ffi');
local C        = ffi.C;
local d3d8dev  = d3d.get_device();
local _, _vp   = d3d8dev:GetViewport();
local _SCR_W   = _vp.Width;
local _SCR_H   = _vp.Height;

-- ─────────────────────────────────────────────────────────────────────────────
-- Configuration defaults
-- ─────────────────────────────────────────────────────────────────────────────

local defaults = T{
    active      = false,   -- is hiding currently enabled?
    hide_party  = true,    -- party frames A / B / C
    hide_target = false,   -- target bar + conquest + misc
    hide_chat1  = false,   -- main chat window
    hide_chat2  = false,   -- second chat window
    -- Unidentified ptr1 elements — toggle to discover what each controls
    hide_unk2D  = false,
    hide_unk41  = false,
    hide_unk4B  = false,
    hide_unk55  = false,
    hide_unk5F  = false,
    hide_unk69  = false,
    hide_unk73  = false,
    hide_unk7D  = false,
    hide_unk87  = false,
    hide_unk91  = false,
    -- Custom cursor overlay (only active when hide_target = true)
    show_cursors = true,
};

-- ─────────────────────────────────────────────────────────────────────────────
-- Runtime state
-- ─────────────────────────────────────────────────────────────────────────────

local ogui = T{
    settings         = defaults:copy(),
    show_window      = T{ false },
    fishing_active   = false,
    cursor_sprite    = nil,
    cursor_tex       = nil,
    cursor_tex_sub   = nil,

    ptrs = T{
        chat1  = 0,   -- ptr1+0x0F
        party0 = 0,   -- ptr1+0x19  (owns fishing HP bar)
        target = 0,   -- ptr1+0x23
        unk2D  = 0,   -- ptr1+0x2D  (unidentified)
        chat2  = 0,   -- ptr1+0x37
        unk41  = 0,   -- ptr1+0x41  (unidentified)
        unk4B  = 0,   -- ptr1+0x4B  (unidentified)
        unk55  = 0,   -- ptr1+0x55  (unidentified)
        unk5F  = 0,   -- ptr1+0x5F  (unidentified)
        unk69  = 0,   -- ptr1+0x69  (unidentified)
        unk73  = 0,   -- ptr1+0x73  (unidentified)
        unk7D  = 0,   -- ptr1+0x7D  (unidentified)
        unk87  = 0,   -- ptr1+0x87  (unidentified)
        unk91  = 0,   -- ptr1+0x91  (unidentified)
        party1 = 0,   -- ptr2+0x01
        party2 = 0,   -- ptr2+0x07
    },
};

-- Diagnostic scan state (session only, not persisted)
local diag = T{
    ptr1   = 0,
    found  = T{},
    hidden = T{},
};

-- ─────────────────────────────────────────────────────────────────────────────
-- Primitive visibility
-- ─────────────────────────────────────────────────────────────────────────────

local function get_prim(p)
    if (p == 0) then return 0; end
    local ptr = ashita.memory.read_uint32(p);
    if (ptr == 0) then return 0; end
    return ashita.memory.read_uint32(ptr + 0x08);
end

local function set_vis(p, v)
    local prim = get_prim(p);
    if (prim == 0) then return; end
    ashita.memory.write_uint8(prim + 0x69, v);
    ashita.memory.write_uint8(prim + 0x6A, v);
end

--[[
    set_party_vis: visibility for party containers.
    NOTE: +3C (layout bounds) write was attempted here to collapse the
    party list height so the target bar doesn't shift when members join/leave,
    but writing that field caused the target bar to be hidden as a side effect
    (the game appears to use it for child/neighbour culling, not just bounds).
    Layout pinning requires further investigation — see dumpptr notes.
--]]
local function set_party_vis(p, v)
    local prim = get_prim(p);
    if (prim == 0) then return; end
    ashita.memory.write_uint8(prim + 0x69, v);
    ashita.memory.write_uint8(prim + 0x6A, v);
end

local function show_all()
    set_vis(ogui.ptrs.chat1,  1);
    set_vis(ogui.ptrs.target, 1);
    set_vis(ogui.ptrs.chat2,  1);
    set_vis(ogui.ptrs.unk2D,  1);
    set_vis(ogui.ptrs.unk41,  1);
    set_vis(ogui.ptrs.unk4B,  1);
    set_vis(ogui.ptrs.unk55,  1);
    set_vis(ogui.ptrs.unk5F,  1);
    set_vis(ogui.ptrs.unk69,  1);
    set_vis(ogui.ptrs.unk73,  1);
    set_vis(ogui.ptrs.unk7D,  1);
    set_vis(ogui.ptrs.unk87,  1);
    set_vis(ogui.ptrs.unk91,  1);
    set_party_vis(ogui.ptrs.party0, 1);
    set_party_vis(ogui.ptrs.party1, 1);
    set_party_vis(ogui.ptrs.party2, 1);
end

local function apply()
    local s = ogui.settings;
    if (not s.active) then
        show_all();
        return;
    end

    -- party0: forced visible while fishing so the HP bar shows
    local p0 = (s.hide_party and not ogui.fishing_active) and 0 or 1;
    local tv = s.hide_target and 0 or 1;

    set_vis(ogui.ptrs.chat1,  s.hide_chat1  and 0 or 1);
    set_party_vis(ogui.ptrs.party0, p0);
    set_vis(ogui.ptrs.target, tv);
    set_vis(ogui.ptrs.chat2,  s.hide_chat2  and 0 or 1);
    set_vis(ogui.ptrs.unk2D,  s.hide_unk2D  and 0 or 1);
    set_vis(ogui.ptrs.unk41,  s.hide_unk41  and 0 or 1);
    set_vis(ogui.ptrs.unk4B,  s.hide_unk4B  and 0 or 1);
    set_vis(ogui.ptrs.unk55,  s.hide_unk55  and 0 or 1);
    set_vis(ogui.ptrs.unk5F,  s.hide_unk5F  and 0 or 1);
    set_vis(ogui.ptrs.unk69,  s.hide_unk69  and 0 or 1);
    set_vis(ogui.ptrs.unk73,  s.hide_unk73  and 0 or 1);
    set_vis(ogui.ptrs.unk7D,  s.hide_unk7D  and 0 or 1);
    set_vis(ogui.ptrs.unk87,  s.hide_unk87  and 0 or 1);
    set_vis(ogui.ptrs.unk91,  s.hide_unk91  and 0 or 1);
    set_party_vis(ogui.ptrs.party1, s.hide_party and 0 or 1);
    set_party_vis(ogui.ptrs.party2, s.hide_party and 0 or 1);
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Custom target cursor overlay
-- Draws PNG sprite cursors over the target / subtarget in 3D world space.
-- Only active when hide_target is true AND show_cursors is true.
-- Adapted from customtarget by Jyouya (MIT).
-- Assets: cursor.png (main), subcursor.png (sub/blue) in the ogui folder.
-- ─────────────────────────────────────────────────────────────────────────────

local CURSOR_W   = 30;
local CURSOR_H   = 20;
local _cr_rect   = ffi.new('RECT',        { 0, 0, CURSOR_W, CURSOR_H });
local _cr_white  = d3d.D3DCOLOR_ARGB(255, 255, 255, 255);
local _cr_pos    = ffi.new('D3DXVECTOR2', { 0, 0 });
local _cr_pos_s  = ffi.new('D3DXVECTOR2', { 0, 0 });
local _cr_scale  = ffi.new('D3DXVECTOR2', { 1.0, 1.0 });

local function _cr_mat_mul(m1, m2)
    return ffi.new('D3DXMATRIX', {
        m1._11*m2._11 + m1._12*m2._21 + m1._13*m2._31 + m1._14*m2._41,
        m1._11*m2._12 + m1._12*m2._22 + m1._13*m2._32 + m1._14*m2._42,
        m1._11*m2._13 + m1._12*m2._23 + m1._13*m2._33 + m1._14*m2._43,
        m1._11*m2._14 + m1._12*m2._24 + m1._13*m2._34 + m1._14*m2._44,
        m1._21*m2._11 + m1._22*m2._21 + m1._23*m2._31 + m1._24*m2._41,
        m1._21*m2._12 + m1._22*m2._22 + m1._23*m2._32 + m1._24*m2._42,
        m1._21*m2._13 + m1._22*m2._23 + m1._23*m2._33 + m1._24*m2._43,
        m1._21*m2._14 + m1._22*m2._24 + m1._23*m2._34 + m1._24*m2._44,
        m1._31*m2._11 + m1._32*m2._21 + m1._33*m2._31 + m1._34*m2._41,
        m1._31*m2._12 + m1._32*m2._22 + m1._33*m2._32 + m1._34*m2._42,
        m1._31*m2._13 + m1._32*m2._23 + m1._33*m2._33 + m1._34*m2._43,
        m1._31*m2._14 + m1._32*m2._24 + m1._33*m2._34 + m1._34*m2._44,
        m1._41*m2._11 + m1._42*m2._21 + m1._43*m2._31 + m1._44*m2._41,
        m1._41*m2._12 + m1._42*m2._22 + m1._43*m2._32 + m1._44*m2._42,
        m1._41*m2._13 + m1._42*m2._23 + m1._43*m2._33 + m1._44*m2._43,
        m1._41*m2._14 + m1._42*m2._24 + m1._43*m2._34 + m1._44*m2._44,
    });
end

local function _cr_vec4_xform(v, m)
    return ffi.new('D3DXVECTOR4', {
        m._11*v.x + m._21*v.y + m._31*v.z + m._41*v.w,
        m._12*v.x + m._22*v.y + m._32*v.z + m._42*v.w,
        m._13*v.x + m._23*v.y + m._33*v.z + m._43*v.w,
        m._14*v.x + m._24*v.y + m._34*v.z + m._44*v.w,
    });
end

local function cursor_world_to_screen(x, y, z, view, proj)
    local p  = _cr_vec4_xform(
                    ffi.new('D3DXVECTOR4', { x, y, z, 1 }),
                    _cr_mat_mul(view, proj));
    local rw = 1 / p.w;
    return math.floor((p.x * rw + 1) * 0.5 * _SCR_W),
           math.floor((1 - p.y * rw) * 0.5 * _SCR_H),
           p.z * rw;
end

local function cursor_get_bone(actor_ptr, bone)
    local bx  = ashita.memory.read_float(actor_ptr + 0x678);
    local by  = ashita.memory.read_float(actor_ptr + 0x680);
    local bz  = ashita.memory.read_float(actor_ptr + 0x67C);
    local sk  = ashita.memory.read_uint32(actor_ptr + 0x6B8);
    local sko = ashita.memory.read_uint32(sk + 0x0C);
    local ska = ashita.memory.read_uint32(sko);
    local cnt = ashita.memory.read_uint16(ska + 0x32);
    local gen = ska + 0x30 + 0x04 + 0x1E * cnt + 4;
    return bx + ashita.memory.read_float(gen + bone * 0x1A + 0x0E + 0x0),
           by + ashita.memory.read_float(gen + bone * 0x1A + 0x0E + 0x8),
           bz + ashita.memory.read_float(gen + bone * 0x1A + 0x0E + 0x4);
end

local function cursor_get_pos(tidx)
    local e      = AshitaCore:GetMemoryManager():GetEntity();
    local etype  = e:GetType(tidx);
    local rflags = e:GetRenderFlags0(tidx);
    local tx, ty, tz;
    if (etype == 3) then
        tx = e:GetLocalPositionX(tidx);
        ty = e:GetLocalPositionY(tidx);
        tz = e:GetLocalPositionZ(tidx);
    elseif (rflags == 0 and etype == 0) then
        tx = e:GetLastPositionX(tidx);
        ty = e:GetLastPositionY(tidx);
        tz = e:GetLastPositionZ(tidx);
    else
        local aptr = e:GetActorPointer(tidx);
        tx, ty, tz = cursor_get_bone(aptr, 2);
    end
    local _, view = d3d8dev:GetTransform(C.D3DTS_VIEW);
    local _, proj = d3d8dev:GetTransform(C.D3DTS_PROJECTION);
    local sx, sy, nz = cursor_world_to_screen(tx, tz, ty, view, proj);
    sx = sx - CURSOR_W / 2;
    sy = sy - CURSOR_H;
    if (etype == 3) then sy = sy - 8; end
    return sx, sy, nz;
end

local function cursor_load_tex(filename)
    local tp = ffi.new('IDirect3DTexture8*[1]');
    if (C.D3DXCreateTextureFromFileA(d3d8dev, addon.path .. filename, tp) ~= C.S_OK) then
        return nil;
    end
    return d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', tp[0]));
end

local function cursor_init_sprite()
    local sp = ffi.new('ID3DXSprite*[1]');
    if (C.D3DXCreateSprite(d3d8dev, sp) ~= C.S_OK) then return nil; end
    return d3d.gc_safe_release(ffi.cast('ID3DXSprite*', sp[0]));
end

--[[
    pin_target_layout  —  prevent target bar from shifting when party is hidden
    ───────────────────────────────────────────────────────────────────────────
    The party0 layout engine runs every game tick and:
      1. Writes a shifted value to party0 prim +3C based on member count
         (low word decreases by 20 per extra member above 1)
      2. Propagates that shift to the target prim's +3C, +40, +54 fields

    We run this correction in d3d_beginscene, which fires between the game's
    logic tick (when the layout engine ran) and the actual draw calls (when
    the renderer reads these fields). This is the only safe write window.

    Approach A  (party0 +3C lock):
      Write the solo layout value to party0 +3C every frame so the game's
      layout engine computes the correct target position on the normal path
      that reads party0 as positional input.

    Approach B  (derived absolute target pin):
      Write directly-computed solo Y values to target prim +3C/+40/+54.
      Uses fixed offsets from party0 +54 (the constant full-party anchor):
        target +3C low = anchor + 54
        target +40 low = anchor + 98
        target +54     = anchor + 54
      No load-time capture — purely derived from live memory every frame.
      Handles any code path that bypasses party0 (e.g. auto-targeting).
--]]
local function pin_target_layout()
    if (not (ogui.settings.active and ogui.settings.hide_party
             and not ogui.fishing_active)) then return; end

    local p0_prim = get_prim(ogui.ptrs.party0);
    if (p0_prim == 0) then return; end

    local p0_3C  = ashita.memory.read_uint32(p0_prim + 0x3C);
    local anchor = ashita.memory.read_uint32(p0_prim + 0x54);  -- constant ~0x03A2

    -- A) Lock party0 +3C to the solo (1-member) value
    ashita.memory.write_uint32(p0_prim + 0x3C,
        bit.bor(bit.band(p0_3C, 0xFFFF0000), anchor + 100));

    -- B) Pin target bar Y fields to solo positions derived from the same anchor.
    --    Preserve each field's high word (may vary by game state); replace only
    --    the low word (Y coordinate) with the fixed solo-layout value.
    local prim_t = get_prim(ogui.ptrs.target);
    if (prim_t == 0) then return; end

    local cur_3C = ashita.memory.read_uint32(prim_t + 0x3C);
    local cur_40 = ashita.memory.read_uint32(prim_t + 0x40);
    ashita.memory.write_uint32(prim_t + 0x3C,
        bit.bor(bit.band(cur_3C, 0xFFFF0000), anchor + 54));
    ashita.memory.write_uint32(prim_t + 0x40,
        bit.bor(bit.band(cur_40, 0xFFFF0000), anchor + 98));
    ashita.memory.write_uint32(prim_t + 0x54, anchor + 54);
end

ashita.events.register('d3d_beginscene', 'beginscene_cb', pin_target_layout);
ashita.events.register('d3d_endscene',   'endscene_cb',   pin_target_layout);

-- ─────────────────────────────────────────────────────────────────────────────
-- Fishing detection  (method + message list adapted from anglin by Astika2)
-- ─────────────────────────────────────────────────────────────────────────────

local HOOK_MESSAGES = T{
    'Something caught the hook!!!',
    'Something caught the hook!',
    'You feel something pulling at your line.',
    'Something clamps onto your line ferociously!',
};

local function strip_codes(raw)
    -- Strip Ashita color tags  |cAARRGGBB| / |r|  and control characters
    return raw:gsub('|[cC]%x+|', ''):gsub('[%z\1-\31\127]', '');
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Diagnostic helpers
-- ─────────────────────────────────────────────────────────────────────────────

local KNOWN_OFFSETS = T{
    [0x0F] = 'chat1   (main chat window)',
    [0x19] = 'party0  (party list A + fishing HP bar)',
    [0x23] = 'target  (target bar / conquest / misc)',
    [0x2D] = 'unk2D   (unidentified)',
    [0x37] = 'chat2   (second chat window)',
};

local function cmd_scan()
    local ptr1 = ashita.memory.find('FFXiMain.dll', 0, '66C78182000000????C7818C000000????????C781900000', 0, 0);
    if (ptr1 == 0) then
        print(chat.header(addon.name):append(chat.error('scan: pattern not found.')));
        return;
    end

    diag.ptr1  = ptr1;
    diag.found = T{};
    diag.hidden= T{};

    local scan_offsets = T{ 0x0F, 0x19, 0x23, 0x2D, 0x37, 0x41, 0x4B, 0x55, 0x5F, 0x69, 0x73, 0x7D, 0x87, 0x91 };

    print(chat.header(addon.name):append(chat.message(
        string.format('scan  ptr1=0x%08X', ptr1))));

    scan_offsets:ieach(function(off)
        local val = ashita.memory.read_uint32(ptr1 + off);
        if (val ~= 0) then
            diag.found:append(T{ off = off, val = val });
            local label = KNOWN_OFFSETS[off] or '???';
            print(chat.header(addon.name):append(chat.message(
                string.format('[%2d]  +0x%02X  0x%08X  %s', #diag.found, off, val, label))));
        end
    end);

    print(chat.header(addon.name):append(chat.message(
        string.format('%d pointers found.  /ogui test <N> to toggle.', #diag.found))));
end

local function cmd_test(idx)
    if (#diag.found == 0) then
        print(chat.header(addon.name):append(chat.error('Run /ogui scan first.'))); return;
    end
    if (idx < 1 or idx > #diag.found) then
        print(chat.header(addon.name):append(chat.error(
            string.format('Index out of range. Use 1-%d.', #diag.found)))); return;
    end
    local e      = diag.found[idx];
    local hidden = diag.hidden[idx] or false;
    local newv   = hidden and 1 or 0;
    set_vis(e.val, newv);
    diag.hidden[idx] = not hidden;
    print(chat.header(addon.name):append(chat.message(
        string.format('[test %d]  +0x%02X  ->  %s', idx, e.off, newv == 0 and 'HIDDEN' or 'SHOWN'))));
end

local function cmd_testall()
    for i, e in ipairs(diag.found) do
        set_vis(e.val, 1);
        diag.hidden[i] = false;
    end
    print(chat.header(addon.name):append(chat.message('All test-hidden pointers restored.')));
end

--[[
    /ogui dumpptr <name>
    Dumps 0x80 bytes of the primitive struct for a named pointer so we can
    identify size/position fields by comparing party at 1 member vs more.
    Run it solo, then in a party of 2+, and look for bytes that changed.
--]]
local function cmd_dumpptr(name)
    local p = ogui.ptrs[name];
    if (p == nil or p == 0) then
        print(chat.header(addon.name):append(chat.error(
            'Unknown pointer name. Use: chat1 party0 target chat2 party1 party2')));
        return;
    end

    local ptr = ashita.memory.read_uint32(p);
    if (ptr == 0) then print(chat.header(addon.name):append(chat.error('ptr lvl1 = 0'))); return; end
    local prim = ashita.memory.read_uint32(ptr + 0x08);
    if (prim == 0) then print(chat.header(addon.name):append(chat.error('prim = 0'))); return; end

    print(chat.header(addon.name):append(chat.message(
        string.format('dumpptr [%s]  prim=0x%08X', name, prim))));

    -- Print 0x80 bytes as hex, 16 per row, with float interpretation
    for row = 0, 7 do
        local base = row * 0x10;
        local hex  = string.format('  +%02X: ', base);
        local flt  = '  ';
        for col = 0, 3 do
            local off = base + col * 4;
            local u   = ashita.memory.read_uint32(prim + off);
            local f   = ashita.memory.read_float(prim + off);
            hex = hex .. string.format('%08X ', u);
            -- Only show float if it looks plausible as a screen coord or size (0 to 4096)
            if (f >= 0 and f <= 4096 and f ~= 0) then
                flt = flt .. string.format('+%02X=%.1f ', off, f);
            end
        end
        print(chat.header(addon.name):append(chat.message(hex .. flt)));
    end
end

local function cmd_info()
    print(chat.header(addon.name):append(chat.message(
        string.format('v%s  |  hiding: %s  |  fishing: %s',
            addon.version,
            ogui.settings.active and 'ON' or 'OFF',
            ogui.fishing_active and 'active' or 'inactive'))));
    local names = T{ 'chat1', 'party0', 'target', 'unk2D', 'chat2',
                     'unk41', 'unk4B', 'unk55', 'unk5F', 'unk69',
                     'unk73', 'unk7D', 'unk87', 'unk91', 'party1', 'party2' };
    names:ieach(function(n)
        local p = ogui.ptrs[n];
        print(chat.header(addon.name):append(chat.message(
            string.format('  %-7s  0x%08X', n, p))));
    end);
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Events
-- ─────────────────────────────────────────────────────────────────────────────

ashita.events.register('load', 'load_cb', function ()
    -- Load settings and register a callback so ogui.settings stays in sync
    -- if the addon was loaded before login, or if the character switches.
    ogui.settings = settings.load(defaults);
    settings.register('settings', 'ogui_settings_cb', function (s)
        ogui.settings = s;
    end);

    local ptr1 = ashita.memory.find('FFXiMain.dll', 0, '66C78182000000????C7818C000000????????C781900000', 0, 0);
    local ptr2 = ashita.memory.find('FFXiMain.dll', 0, 'A1????????8B0D????????89442424A1????????33DB89',   0, 0);

    if (ptr1 == 0) then error(chat.header(addon.name):append(chat.error('Failed to locate pointer (1).'))); end
    if (ptr2 == 0) then error(chat.header(addon.name):append(chat.error('Failed to locate pointer (2).'))); end

    ogui.ptrs.chat1  = ashita.memory.read_uint32(ptr1 + 0x0F);
    ogui.ptrs.party0 = ashita.memory.read_uint32(ptr1 + 0x19);
    ogui.ptrs.target = ashita.memory.read_uint32(ptr1 + 0x23);
    ogui.ptrs.unk2D  = ashita.memory.read_uint32(ptr1 + 0x2D);
    ogui.ptrs.chat2  = ashita.memory.read_uint32(ptr1 + 0x37);
    ogui.ptrs.unk41  = ashita.memory.read_uint32(ptr1 + 0x41);
    ogui.ptrs.unk4B  = ashita.memory.read_uint32(ptr1 + 0x4B);
    ogui.ptrs.unk55  = ashita.memory.read_uint32(ptr1 + 0x55);
    ogui.ptrs.unk5F  = ashita.memory.read_uint32(ptr1 + 0x5F);
    ogui.ptrs.unk69  = ashita.memory.read_uint32(ptr1 + 0x69);
    ogui.ptrs.unk73  = ashita.memory.read_uint32(ptr1 + 0x73);
    ogui.ptrs.unk7D  = ashita.memory.read_uint32(ptr1 + 0x7D);
    ogui.ptrs.unk87  = ashita.memory.read_uint32(ptr1 + 0x87);
    ogui.ptrs.unk91  = ashita.memory.read_uint32(ptr1 + 0x91);
    ogui.ptrs.party1 = ashita.memory.read_uint32(ptr2 + 0x01);
    ogui.ptrs.party2 = ashita.memory.read_uint32(ptr2 + 0x07);

    show_all();
    ogui.cursor_sprite = cursor_init_sprite();
    print(chat.header(addon.name):append(chat.message('Loaded.  Type /ogui to open settings.')));
end);

ashita.events.register('unload', 'unload_cb', function ()
    show_all();
    settings.save();
end);

ashita.events.register('text_in', 'text_cb', function (e)
    if (e.injected) then return; end
    local msg = strip_codes(e.message);
    HOOK_MESSAGES:ieach(function (pattern)
        if (msg:find(pattern, 1, true)) then
            ogui.fishing_active = true;
        end
    end);
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/ogui')) then return; end
    e.blocked = true;

    -- No args: toggle window
    if (#args == 1) then
        ogui.show_window[1] = not ogui.show_window[1];
        return;
    end

    local sub = args[2];

    if (sub:any('on'))   then
        ogui.settings.active = true;  settings.save();
        print(chat.header(addon.name):append(chat.message('Hiding ON.')));
        return;
    end

    if (sub:any('off'))  then
        ogui.settings.active = false; settings.save();
        print(chat.header(addon.name):append(chat.message('Hiding OFF — all elements visible.')));
        return;
    end

    if (sub:any('info'))     then cmd_info();                              return; end
    if (sub:any('scan'))     then cmd_scan();                              return; end
    if (sub:any('testall', 'testreset')) then cmd_testall();               return; end
    if (sub:any('test') and args[3] ~= nil) then
        cmd_test(tonumber(args[3]) or 0);
        return;
    end
    if (sub:any('dumpptr') and args[3] ~= nil) then
        cmd_dumpptr(args[3]);
        return;
    end

    -- Unknown arg: just open the window
    ogui.show_window[1] = true;
end);

-- ─────────────────────────────────────────────────────────────────────────────
-- Render
-- ─────────────────────────────────────────────────────────────────────────────

local COL_HEADER  = { 0.40, 0.70, 1.00, 1.0 };
local COL_ON      = { 1.00, 0.35, 0.35, 1.0 };
local COL_OFF     = { 0.40, 0.85, 0.45, 1.0 };
local COL_FISHING = { 0.40, 0.80, 1.00, 1.0 };

local function section(label)
    imgui.Spacing();
    imgui.TextColored(COL_HEADER, label);
    imgui.Separator();
    imgui.Spacing();
end

local function toggle(label, key, tooltip)
    local val = T{ ogui.settings[key] };
    if (imgui.Checkbox(label, val)) then
        ogui.settings[key] = val[1];
        settings.save();
    end
    if (tooltip) then
        imgui.SameLine();
        imgui.TextDisabled('(?)');
        if (imgui.IsItemHovered()) then
            imgui.BeginTooltip();
            imgui.TextUnformatted(tooltip);
            imgui.EndTooltip();
        end
    end
end

ashita.events.register('d3d_present', 'present_cb', function ()
    -- Clear fishing flag once player returns to normal status
    if (ogui.fishing_active) then
        local mp = AshitaCore:GetMemoryManager():GetParty();
        local me = AshitaCore:GetMemoryManager():GetEntity();
        if (mp and me and me:GetStatus(mp:GetMemberTargetIndex(0)) == 0) then
            ogui.fishing_active = false;
        end
    end

    apply();

    -- Draw custom target cursors when the native target bar is hidden
    if (ogui.settings.active and ogui.settings.hide_target and ogui.settings.show_cursors
            and ogui.cursor_sprite ~= nil) then
        local tgt    = AshitaCore:GetMemoryManager():GetTarget();
        local is_sub = tgt:GetIsSubTargetActive();
        if (tgt:GetIsActive(is_sub) ~= 0) then
            ogui.cursor_tex     = ogui.cursor_tex     or cursor_load_tex('cursor.png');
            ogui.cursor_tex_sub = ogui.cursor_tex_sub or cursor_load_tex('subcursor.png');

            local tidx     = tgt:GetTargetIndex(is_sub);
            local tidx_sub = (is_sub == 1) and tgt:GetTargetIndex(0) or nil;

            local px, py, pz = cursor_get_pos(tidx);
            _cr_pos.x = px;
            _cr_pos.y = py;
            if (pz >= 0 and pz <= 1) then
                local flags = tgt:GetSubTargetFlags();
                if ((flags == 512 or flags == 18 or flags == 525) and tidx_sub == nil) then
                    ogui.cursor_sprite:Draw(ogui.cursor_tex_sub, _cr_rect, _cr_scale, nil, 0.0, _cr_pos, _cr_white);
                else
                    ogui.cursor_sprite:Draw(ogui.cursor_tex,     _cr_rect, _cr_scale, nil, 0.0, _cr_pos, _cr_white);
                end
            end

            if (tidx_sub ~= nil) then
                local sx, sy, sz = cursor_get_pos(tidx_sub);
                _cr_pos_s.x = sx;
                _cr_pos_s.y = sy - 10;
                if (sz >= 0 and sz <= 1) then
                    ogui.cursor_sprite:Draw(ogui.cursor_tex_sub, _cr_rect, _cr_scale, nil, 0.0, _cr_pos_s, _cr_white);
                end
            end
        end
    end

    if (not ogui.show_window[1]) then return; end

    imgui.SetNextWindowSize({ 290, 0 }, ImGuiCond_FirstUseEver);
    imgui.SetNextWindowPos({ 100, 100 }, ImGuiCond_FirstUseEver);

    imgui.PushStyleColor(ImGuiCol_TitleBg,        { 0.08, 0.12, 0.20, 1.0 });
    imgui.PushStyleColor(ImGuiCol_TitleBgActive,  { 0.12, 0.18, 0.30, 1.0 });
    imgui.PushStyleColor(ImGuiCol_WindowBg,        { 0.07, 0.09, 0.14, 0.96 });
    imgui.PushStyleColor(ImGuiCol_CheckMark,       { 0.40, 0.70, 1.00, 1.0 });
    imgui.PushStyleColor(ImGuiCol_FrameBgHovered,  { 0.20, 0.30, 0.50, 0.6 });
    imgui.PushStyleColor(ImGuiCol_FrameBgActive,   { 0.25, 0.40, 0.65, 0.8 });

    if (imgui.Begin('OGui##ogui_win', ogui.show_window)) then

        -- ── Status row ───────────────────────────────────────────────────────
        if (ogui.settings.active) then
            imgui.TextColored(COL_ON, '\xe2\x97\x8f  Hiding ON');
        else
            imgui.TextColored(COL_OFF, '\xe2\x97\x8f  All Visible');
        end

        if (ogui.fishing_active) then
            imgui.SameLine();
            imgui.TextColored(COL_FISHING, '   \xf0\x9f\x8e\xa3 Fishing');
        end

        imgui.SameLine();
        imgui.SetCursorPosX(imgui.GetWindowWidth() - 105);
        local btn_label = ogui.settings.active and 'Turn Off##st' or 'Turn On##st';
        if (imgui.Button(btn_label, { 95, 0 })) then
            ogui.settings.active = not ogui.settings.active;
            settings.save();
        end

        -- ── Game UI ──────────────────────────────────────────────────────────
        section('Game UI');

        toggle('Party Frames  (A / B / C)', 'hide_party',
            'Hides the native FFXI party list frames.\n\n' ..
            'The fishing HP bar lives in this same\n' ..
            'container. It auto-shows when a fish is\n' ..
            'hooked and re-hides when the session ends.');

        toggle('Target / Misc UI', 'hide_target',
            'Target bar, subtarget bar,\n' ..
            'selection cursors, conquest /\n' ..
            'imperial standing, and related\n' ..
            'misc elements.');

        if (ogui.settings.hide_target) then
            imgui.Indent(16);
            toggle('Custom target cursors', 'show_cursors',
                'Draws 3D sprite cursors over your\n' ..
                'target and subtarget when the\n' ..
                'native target bar is hidden.\n\n' ..
                'Uses cursor.png and subcursor.png\n' ..
                'in the ogui addon folder.\n' ..
                'Replace them to customise the look.');
            imgui.Unindent(16);
        end

        -- ── Chat ─────────────────────────────────────────────────────────────
        section('Chat');
        toggle('Chat Window 1', 'hide_chat1', nil);
        toggle('Chat Window 2', 'hide_chat2', nil);

        imgui.Spacing();
        imgui.TextDisabled('  /ogui on \xc2\xb7 /ogui off \xc2\xb7 /ogui info');
        imgui.Spacing();
    end
    imgui.End();

    imgui.PopStyleColor(6);
end);
